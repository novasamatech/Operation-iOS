import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryCleanerTests: HistoryTrackingTestCase {

    // MARK: - Tests

    func testCleanIsNoOpWhenNoTimestampsExist() {
        // given - two managers, neither has a timestamp yet
        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [
                InMemoryHistoryTimestampManager(),
                InMemoryHistoryTimestampManager()
            ]
        )

        // Produce real history via a second author so "did anything get deleted" is testable.
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        save(makeRandomFeeds(2), using: otherRepository)

        onDatabaseContext { context in
            let historyBefore = try self.fetchAllHistory(context: context)
            XCTAssertFalse(historyBefore.isEmpty, "Setup must have produced history to clean")

            // when
            try cleaner.clean(context: context)

            // then - nothing should have been deleted
            let historyAfter = try self.fetchAllHistory(context: context)
            XCTAssertEqual(
                historyAfter.count,
                historyBefore.count,
                "Cleaner must not delete anything when any target is missing a timestamp"
            )
        }
    }

    func testCleanIsNoOpWhenOnlyOneTargetHasTimestamp() {
        // given
        let mainAppManager = InMemoryHistoryTimestampManager(initial: Date())
        let extensionManager = InMemoryHistoryTimestampManager() // missing
        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [mainAppManager, extensionManager]
        )

        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        save(makeRandomFeeds(2), using: otherRepository)

        onDatabaseContext { context in
            let historyBefore = try self.fetchAllHistory(context: context)
            XCTAssertFalse(historyBefore.isEmpty)

            // when
            try cleaner.clean(context: context)

            // then
            let historyAfter = try self.fetchAllHistory(context: context)
            XCTAssertEqual(
                historyAfter.count,
                historyBefore.count,
                "Cleaner must skip when extension has no timestamp"
            )
            XCTAssertNotNil(
                mainAppManager.lastTimestamp,
                "Cleaner must never mutate timestamps"
            )
        }
    }

    func testCleanDeletesHistoryBeforeCommonTimestamp() throws {
        // given - produce two batches of history. Cutoff is derived from the actual
        // transaction timestamps rather than a wall-clock sleep: the second transaction's
        // own timestamp is used as the boundary, so we can assert "the first transaction
        // is strictly before cutoff, the second is at/after" without relying on timing.
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()

        save(makeRandomFeeds(2), using: otherRepository)
        save(makeRandomFeeds(2), using: otherRepository)

        let sortedHistory = try fetchSortedHistory()
        XCTAssertGreaterThanOrEqual(sortedHistory.count, 2, "Need at least two transactions to test a boundary")
        let cutoff = sortedHistory[1].timestamp

        let mainAppManager = InMemoryHistoryTimestampManager(initial: cutoff)
        let extensionManager = InMemoryHistoryTimestampManager(initial: cutoff)
        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [mainAppManager, extensionManager]
        )

        let expectedSurvivorCount = sortedHistory.filter { $0.timestamp >= cutoff }.count

        onDatabaseContext { context in
            // when
            try cleaner.clean(context: context)

            // then
            let historyAfter = try self.fetchAllHistory(context: context)
            XCTAssertTrue(
                historyAfter.allSatisfy { $0.timestamp >= cutoff },
                "All surviving transactions should be at/after the cutoff"
            )
            XCTAssertEqual(
                historyAfter.count,
                expectedSurvivorCount,
                "Only transactions strictly before the cutoff should be removed"
            )

            // Cleaner must NOT mutate timestamps — they represent "how far processed"
            XCTAssertEqual(
                mainAppManager.lastTimestamp?.timeIntervalSince1970 ?? -1,
                cutoff.timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(
                extensionManager.lastTimestamp?.timeIntervalSince1970 ?? -1,
                cutoff.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    /// The cleaner uses ``min(...)`` across targets so that a lagging target never loses
    /// history it hasn't merged yet. This test pins that invariant: with one target far
    /// ahead and one far behind, only history before the *behind* target is deleted.
    func testCleanUsesMinimumAcrossTargets() throws {
        // given - three separate transactions. Cutoffs are taken from the actual transaction
        // timestamps: lagging = txn[1], leading = txn[2]. Deterministic regardless of clock.
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()

        save(makeRandomFeeds(1), using: otherRepository)
        save(makeRandomFeeds(1), using: otherRepository)
        save(makeRandomFeeds(1), using: otherRepository)

        let sortedHistory = try fetchSortedHistory()
        XCTAssertGreaterThanOrEqual(sortedHistory.count, 3, "Need three transactions for a min-across-targets test")
        let laggingCutoff = sortedHistory[1].timestamp
        let leadingCutoff = sortedHistory[2].timestamp
        XCTAssertLessThan(laggingCutoff, leadingCutoff, "Lagging cutoff must precede leading cutoff")

        let laggingTarget = InMemoryHistoryTimestampManager(initial: laggingCutoff)
        let leadingTarget = InMemoryHistoryTimestampManager(initial: leadingCutoff)
        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [leadingTarget, laggingTarget]
        )

        onDatabaseContext { context in
            // when
            try cleaner.clean(context: context)

            // then - everything strictly before the LAGGING cutoff must be gone, everything
            // at or after it must survive (even transactions the leading target has already
            // processed, because the lagging target still needs them).
            let historyAfter = try self.fetchAllHistory(context: context)
            XCTAssertFalse(
                historyAfter.isEmpty,
                "Transactions after the lagging cutoff must survive"
            )
            XCTAssertTrue(
                historyAfter.allSatisfy { $0.timestamp >= laggingCutoff },
                "Cleaner must use the minimum timestamp, not the maximum"
            )
            XCTAssertTrue(
                historyAfter.contains { $0.timestamp < leadingCutoff },
                "Transactions between lagging and leading cutoffs must survive"
            )
        }
    }
}

// MARK: - Helpers

private extension CoreDataHistoryCleanerTests {

    /// Reads raw history ordered by ascending timestamp. Blocks the test thread until the
    /// read completes, which avoids the ``onDatabaseContext`` nesting gymnastics when the
    /// caller only needs the snapshot.
    func fetchSortedHistory() throws -> [NSPersistentHistoryTransaction] {
        var result: [NSPersistentHistoryTransaction] = []
        var capturedError: Error?
        onDatabaseContext { context in
            do {
                result = try self.fetchAllHistory(context: context)
                    .sorted { $0.timestamp < $1.timestamp }
            } catch {
                capturedError = error
            }
        }
        if let capturedError { throw capturedError }
        return result
    }
}
