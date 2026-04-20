import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryObserverTests: HistoryTrackingTestCase {

    // MARK: - Tests

    /// When the internal observer processes remote changes from another author, it must
    /// re-post them as `NSManagedObjectContextDidSave` so `CoreDataContextObservable`
    /// downstream picks them up.
    func testObserverRepostsRemoteChangesAsDidSave() {
        // given
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()

        let didSaveExpectation = expectation(description: "didSave reposted by observer")

        // Wire up the listener on the main service's context.
        onDatabaseContext { [weak self] context in
            // Capture the token so we can unregister — otherwise the closure keeps firing
            // for the rest of the process, potentially across later tests.
            let token = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: context,
                queue: nil
            ) { _ in
                didSaveExpectation.fulfill()
            }
            self?.addTeardownBlock {
                NotificationCenter.default.removeObserver(token)
            }
        }

        // when - write from another author so the observer has something to merge
        save(makeRandomFeeds(3), using: otherRepository)

        // then
        wait(for: [didSaveExpectation], timeout: Self.coreDataTimeout)
    }

    /// The internal observer must persist its progress via the shared ``UserDefaults``
    /// suite so other targets can see where it left off.
    func testObserverUpdatesTimestampInSharedSuiteAfterProcessing() {
        // given - own shared suite so we can read exactly what the observer writes. This test
        // bypasses the base class's auto-created service so both services agree on
        // `sharedContainerName`; `databaseName` is still reused so `tearDown()` drops the file.
        let sharedSuiteName = "ObserverTimestampTests.\(UUID().uuidString)"
        let sharedDefaults = UserDefaults(suiteName: sharedSuiteName)!
        addTeardownBlock {
            sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        }

        let transactionAuthor = HistoryTestAuthors.mainApp

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: databaseName,
            transactionAuthor: transactionAuthor,
            sharedContainerName: sharedSuiteName
        )
        let service = CoreDataService(configuration: configuration)
        addTeardownBlock { try? service.close() }

        let (_, otherRepository) = makeOtherAuthorServiceAndRepository(
            author: HistoryTestAuthors.otherProcess,
            sharedContainerName: sharedSuiteName
        )

        let timestampManager = CoreDataHistoryTimestampManager(
            target: transactionAuthor,
            userDefaults: sharedDefaults
        )
        XCTAssertNil(timestampManager.lastTimestamp, "Precondition: no timestamp persisted yet")

        let processExpectation = expectation(description: "History processed by observer")

        // Trigger lazy context creation, which starts the internal observer, and listen for
        // the reposted didSave to know when processing is done.
        let contextReady = expectation(description: "Main service context ready")
        service.performAsync { context, error in
            defer { contextReady.fulfill() }
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                return
            }
            let token = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: context,
                queue: nil
            ) { _ in
                processExpectation.fulfill()
            }
            self.addTeardownBlock {
                NotificationCenter.default.removeObserver(token)
            }
        }
        wait(for: [contextReady], timeout: Self.coreDataTimeout)

        // when
        save(makeRandomFeeds(2), using: otherRepository)
        wait(for: [processExpectation], timeout: Self.coreDataTimeout)

        // then - observer should have persisted the progress timestamp
        XCTAssertNotNil(
            timestampManager.lastTimestamp,
            "Observer must update the shared-suite timestamp after merging remote history"
        )
    }

    /// The observer must not persist a timestamp when there are no new transactions —
    /// otherwise a spurious remote-change notification could move the cursor forward
    /// past history that another target still needs.
    func testObserverDoesNotUpdateTimestampWithoutTransactions() {
        // given - a direct observer instance with spy collaborators, so we can drive its
        // `processPendingHistory` path without any real history on disk.
        let timestampManager = InMemoryHistoryTimestampManager()
        let fetcher = StubHistoryFetcher(transactions: [])
        let merger = SpyHistoryMerger()
        let cleaner = SpyHistoryCleaner()

        // Capture the context and coordinator on the context queue. `onDatabaseContext`
        // waits on the main thread until the block completes, so it is safe to do setup
        // there — but never to `wait(for:...)` inside that block (it would pump the main
        // run loop from the context's private queue and deadlock).
        var capturedContext: NSManagedObjectContext?
        var capturedCoordinator: NSPersistentStoreCoordinator?
        onDatabaseContext { context in
            capturedContext = context
            capturedCoordinator = context.persistentStoreCoordinator
        }
        let context = try! XCTUnwrap(capturedContext)
        let coordinator = try! XCTUnwrap(capturedCoordinator)

        let observer = CoreDataHistoryObserver(
            context: context,
            timestampManager: timestampManager,
            cleaner: cleaner,
            fetcher: fetcher,
            merger: merger
        )
        observer.startObserving()
        addTeardownBlock { observer.stopObserving() }

        // when - post the remote-change notification the observer subscribes to.
        NotificationCenter.default.post(
            name: .NSPersistentStoreRemoteChange,
            object: coordinator
        )

        // `processPendingHistory` hops onto the context's private queue via
        // `context.perform`. Enqueue a trailing `perform` block from the test thread so
        // we only return after the observer's work has executed — FIFO ordering on the
        // private queue guarantees ours runs second.
        let drained = expectation(description: "context queue drained")
        context.perform { drained.fulfill() }
        wait(for: [drained], timeout: Self.coreDataTimeout)

        // then
        XCTAssertNil(
            timestampManager.lastTimestamp,
            "Empty-transaction runs must not advance the cursor"
        )
        XCTAssertFalse(merger.mergeCalled, "Nothing to merge")
        XCTAssertFalse(cleaner.cleanCalled, "Nothing to clean")
    }
}

// MARK: - Test doubles

private struct StubHistoryFetcher: CoreDataHistoryFetching {
    let transactions: [NSPersistentHistoryTransaction]

    func fetch(context: NSManagedObjectContext, fromDate: Date) throws -> [NSPersistentHistoryTransaction] {
        transactions
    }
}

private final class SpyHistoryMerger: CoreDataHistoryMerging {
    private(set) var mergeCalled = false

    func merge(
        context: NSManagedObjectContext,
        transactions: [NSPersistentHistoryTransaction]
    ) -> [Notification] {
        mergeCalled = true
        return []
    }
}

private final class SpyHistoryCleaner: CoreDataHistoryCleaning {
    private(set) var cleanCalled = false

    func clean(context: NSManagedObjectContext) throws {
        cleanCalled = true
    }
}
