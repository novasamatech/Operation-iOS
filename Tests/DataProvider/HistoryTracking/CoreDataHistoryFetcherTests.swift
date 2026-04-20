import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryFetcherTests: HistoryTrackingTestCase {

    // MARK: - Tests

    func testFetchReturnsEmptyArrayWhenNoChanges() {
        // given/when/then
        onDatabaseContext { context in
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: Date())
            XCTAssertTrue(transactions.isEmpty)
        }
    }

    func testFetchFiltersOutOwnTransactions() {
        // given - save under the *same* author as the fetching context
        let fetchDate = Date()
        save(makeRandomFeeds(3))

        // Positive control: confirm the save actually produced history, so that a `[]`
        // result below means "filtered out", not "nothing ever written".
        onDatabaseContext { context in
            let allHistory = try self.fetchAllHistory(context: context)
            XCTAssertFalse(
                allHistory.isEmpty,
                "Sanity check: saves should have produced raw history transactions"
            )

            // when - use the public author-filtered fetcher
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: fetchDate)

            // then
            XCTAssertTrue(transactions.isEmpty, "Fetcher must filter out own-author transactions")
        }
    }

    func testFetchWithFutureDateReturnsNoTransactions() {
        // given
        save(makeRandomFeeds(3))

        // when - fetch strictly after the saves by skipping ahead an hour
        let futureDate = Date().addingTimeInterval(3600)

        onDatabaseContext { context in
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: futureDate)

            // then
            XCTAssertTrue(transactions.isEmpty)
        }
    }

    func testFetchReturnsTransactionsFromDifferentAuthor() {
        // given
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        let fetchDate = Date()
        save(makeRandomFeeds(3), using: otherRepository)

        // when
        onDatabaseContext { context in
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: fetchDate)

            // then
            XCTAssertFalse(transactions.isEmpty, "Should return transactions written by another author")
        }
    }

    /// Covers the `fromDate` boundary: a transaction written *before* the fetch cursor must
    /// not appear, while one written *after* must.
    func testFetchRespectsFromDateBoundary() {
        // given - two batches of saves, then derive the cursor from the first transaction's
        // real timestamp. `NSPersistentHistoryChangeRequest.fetchHistory(after:)` uses a
        // strict `>` comparison, so passing the first transaction's timestamp as the cursor
        // excludes exactly that one transaction and returns everything newer. No wall-clock
        // sleeps required — the cursor is tied to the data itself.
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()

        save(makeRandomFeeds(2), using: otherRepository)
        save(makeRandomFeeds(2), using: otherRepository)

        // when/then
        onDatabaseContext { context in
            let allTransactions = try CoreDataHistoryFetcher()
                .fetch(context: context, fromDate: .distantPast)
                .sorted { $0.timestamp < $1.timestamp }
            XCTAssertGreaterThanOrEqual(
                allTransactions.count,
                2,
                "Both save batches should have produced history"
            )

            let cursor = allTransactions.first!.timestamp

            let afterCursor = try CoreDataHistoryFetcher().fetch(context: context, fromDate: cursor)
            XCTAssertLessThan(
                afterCursor.count,
                allTransactions.count,
                "Fetching from the cursor must exclude the earlier batch"
            )
            for transaction in afterCursor {
                XCTAssertGreaterThan(
                    transaction.timestamp,
                    cursor,
                    "Every returned transaction must be strictly after the cursor"
                )
            }
        }
    }
}
