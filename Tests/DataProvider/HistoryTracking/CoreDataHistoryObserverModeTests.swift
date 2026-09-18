import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/// Cross-process history must reach every role: the observer context's registered objects and
/// ``CoreDataContextObservable`` subscribers. Runs in `.serial` here and in `.concurrent` through the
/// subclass.
class CoreDataHistoryObserverModeTests: HistoryTrackingTestCase {
    func testRemoteUpdateRefreshesRegisteredObserverObject() throws {
        // given - a row this service wrote, registered (and materialised) on the observer context
        let feed = try XCTUnwrap(save(makeRandomFeeds(1)).first)
        var observedFeed: CDFeed?

        onObserverContext { context in
            let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
            request.predicate = NSPredicate(format: "identifier == %@", feed.identifier)
            observedFeed = try context.fetch(request).first
            XCTAssertEqual(observedFeed?.name, feed.name)
        }

        // when - another author renames it
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        var renamed = feed
        renamed.name = "remote-\(UUID().uuidString)"
        save([renamed], using: otherRepository)

        // then - the observer's registered object reflects the remote change
        let mergedName = pollObserver(until: { $0 == renamed.name }) { observedFeed?.name }
        XCTAssertEqual(mergedName, renamed.name)
    }

    func testRemoteInsertIsDeliveredByContextObservable() {
        // given
        let observable = CoreDataContextObservable(
            service: databaseService,
            mapper: repository.dataMapper,
            predicate: { _ in true }
        )

        let started = expectation(description: "observable started")
        observable.start { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: Self.coreDataTimeout)

        let delivered = expectation(description: "remote insert delivered")
        delivered.assertForOverFulfill = false
        var inserted: [FeedData] = []

        observable.addObserver(self, deliverOn: .main) { changes in
            for case .insert(let item) in changes {
                inserted.append(item)
            }
            delivered.fulfill()
        }

        // when - another author inserts rows
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        let feeds = save(makeRandomFeeds(2), using: otherRepository)

        // then
        wait(for: [delivered], timeout: Self.coreDataTimeout)
        XCTAssertEqual(Set(inserted.map(\.identifier)), Set(feeds.map(\.identifier)))
    }
}

final class CoreDataHistoryObserverConcurrentTests: CoreDataHistoryObserverModeTests {
    override class var concurrencyMode: CoreDataConcurrencyMode { .concurrent(readerConcurrency: 2) }
}

private extension CoreDataHistoryObserverModeTests {
    func onObserverContext(_ body: @escaping (NSManagedObjectContext) throws -> Void) {
        let ready = expectation(description: "observer context ready")

        databaseService.performObserve { context, error in
            defer { ready.fulfill() }

            guard let context else {
                return XCTFail("no observer context: \(String(describing: error))")
            }

            do {
                try body(context)
            } catch {
                XCTFail("observer block threw: \(error)")
            }
        }

        wait(for: [ready], timeout: Self.coreDataTimeout)
    }

    /// Polls the observer context every 20 ms for up to 2 s.
    func pollObserver<T>(until isSatisfied: @escaping (T?) -> Bool, _ read: @escaping () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(2)
        var value: T?

        repeat {
            onObserverContext { _ in value = read() }

            if isSatisfied(value) {
                return value
            }

            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline

        return value
    }
}
