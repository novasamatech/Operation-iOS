import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataConcurrencyModeTests: XCTestCase {
    private struct TestError: Error {}

    private var services: [CoreDataService] = []

    override func tearDown() {
        services.forEach { service in
            try? service.close()
            try? service.drop()
        }
        services.removeAll()

        super.tearDown()
    }

    func testWriteSavesWhenBlockLeavesChanges() {
        forEachMode { service, mode in
            let written = expectation(description: "write in \(mode)")
            var writtenIdentifier: String?

            service.performWrite({ context -> String in
                Self.insertFeed(identifier: "feed-1", name: "one", in: context)
                return "feed-1"
            }, completion: { result in
                writtenIdentifier = try? result.get()
                written.fulfill()
            })

            wait(for: [written], timeout: Constants.expectationDuration)
            XCTAssertEqual(writtenIdentifier, "feed-1", mode)

            XCTAssertEqual(feedCount(in: service), 1, mode)
        }
    }

    func testWriteRollsBackWhenBlockThrows() {
        forEachMode { service, mode in
            let failed = expectation(description: "write fails in \(mode)")
            var failure: Error?

            service.performWrite({ context -> Void in
                Self.insertFeed(identifier: "feed-1", name: "one", in: context)
                throw TestError()
            }, completion: { result in
                if case .failure(let error) = result {
                    failure = error
                }
                failed.fulfill()
            })

            wait(for: [failed], timeout: Constants.expectationDuration)
            XCTAssertTrue(failure is TestError, mode)
            XCTAssertEqual(feedCount(in: service), 0, mode)

            let cleanWrite = expectation(description: "next write starts clean in \(mode)")
            service.performWrite({ _ in }, completion: { result in
                if case .failure(let error) = result {
                    XCTFail("\(mode): clean write failed with \(error)")
                }
                cleanWrite.fulfill()
            })
            wait(for: [cleanWrite], timeout: Constants.expectationDuration)
        }
    }

    func testReadSeesPrecedingWrite() {
        forEachMode { service, mode in
            let iterations = 200
            let allVisible = expectation(description: "read after write in \(mode)")
            allVisible.expectedFulfillmentCount = iterations

            for index in 0 ..< iterations {
                let identifier = "ryw-\(index)"

                service.performWrite({ context in
                    Self.insertFeed(identifier: identifier, name: "row", in: context)
                }, completion: { _ in
                    service.performRead({ context -> Int in
                        let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
                        request.predicate = NSPredicate(format: "identifier == %@", identifier)
                        return try context.count(for: request)
                    }, completion: { result in
                        XCTAssertEqual(try? result.get(), 1, "\(mode): write \(index) invisible to the next read")
                        allVisible.fulfill()
                    })
                })
            }

            wait(for: [allVisible], timeout: Constants.expectationDuration)
        }
    }

    func testObserverMergesWriterSaves() {
        forEachMode { service, mode in
            write(in: service) { Self.insertFeed(identifier: "merge-1", name: "old", in: $0) }

            let registered = expectation(description: "register on observer in \(mode)")
            var observedFeed: CDFeed?

            service.performObserve { context, _ in
                let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
                request.predicate = NSPredicate(format: "identifier == %@", "merge-1")
                observedFeed = try? context?.fetch(request).first
                XCTAssertEqual(observedFeed?.name, "old", mode)
                registered.fulfill()
            }
            wait(for: [registered], timeout: Constants.expectationDuration)

            write(in: service) { context in
                let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
                request.predicate = NSPredicate(format: "identifier == %@", "merge-1")
                try context.fetch(request).first?.name = "new"
            }

            let mergedName = pollObserver(service, until: { $0 == "new" }) { _ in
                observedFeed?.name
            }

            XCTAssertEqual(mergedName, "new", mode)
        }
    }

    func testReadsOverlapWritesOnlyInConcurrentMode() {
        forEachMode { service, mode in
            let order = CompletionOrder()
            let both = expectation(description: "write and read in \(mode)")
            both.expectedFulfillmentCount = 2

            service.performWrite({ _ in
                Thread.sleep(forTimeInterval: 0.3)
            }, completion: { _ in
                order.append("write")
                both.fulfill()
            })

            Thread.sleep(forTimeInterval: 0.05)

            service.performRead({ _ in }, completion: { _ in
                order.append("read")
                both.fulfill()
            })

            wait(for: [both], timeout: Constants.expectationDuration)

            let expected = mode == "concurrent" ? ["read", "write"] : ["write", "read"]
            XCTAssertEqual(order.values, expected, mode)
        }
    }

    /// ``close()`` waits for reads to release the store, which is what makes tearing the coordinator down
    /// safe. It deliberately does not wait for their completions: those run after the reading context is
    /// done with and are allowed to re-enter the service, so waiting for them would wait for a completion
    /// that closes the service.
    func testCloseWaitsForQueuedReadsToReleaseTheStore() throws {
        forEachMode { service, mode in
            let order = CompletionOrder()

            for index in 0 ..< 5 {
                service.performRead({ _ in
                    Thread.sleep(forTimeInterval: 0.05)
                    order.append("read-\(index)")
                }, completion: { _ in })
            }

            do {
                try service.close()
            } catch {
                XCTFail("\(mode): close threw \(error)")
            }

            XCTAssertEqual(order.values.count, 5, "\(mode): close returned while a queued read still held the store")
            XCTAssertNil(service.context, mode)
        }
    }

    func testRolesMatchMode() {
        forEachMode { service, mode in
            let opened = expectation(description: "open in \(mode)")
            service.performAsync { _, _ in opened.fulfill() }
            wait(for: [opened], timeout: Constants.expectationDuration)

            guard let roles = service.roles else {
                return XCTFail("\(mode): store did not open")
            }

            if mode == "concurrent" {
                XCTAssertTrue(roles.writer !== roles.observer, mode)
                XCTAssertTrue(roles.observer.automaticallyMergesChangesFromParent, mode)
                XCTAssertEqual(roles.readerQueue?.maxConcurrentOperationCount, 2, mode)
            } else {
                XCTAssertTrue(roles.writer === roles.observer, mode)
                XCTAssertNil(roles.readerQueue, mode)
            }
        }
    }

    func testRepositoryFetchWaitsForWriterOnlyInSerialMode() {
        forEachMode { service, mode in
            let repository: CoreDataRepository<FeedData, CDFeed> = CoreDataRepository(
                databaseService: service,
                mapper: AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>()),
                filter: nil,
                sortDescriptors: []
            )

            let order = CompletionOrder()
            let both = expectation(description: "writer block and fetch in \(mode)")
            both.expectedFulfillmentCount = 2

            service.performAsync { _, _ in
                Thread.sleep(forTimeInterval: 0.3)
                order.append("writer")
                both.fulfill()
            }

            Thread.sleep(forTimeInterval: 0.05)

            let fetch = repository.fetchAllOperation(with: RepositoryFetchOptions())
            fetch.completionBlock = {
                order.append("fetch")
                both.fulfill()
            }
            OperationQueue().addOperation(fetch)

            wait(for: [both], timeout: Constants.expectationDuration)

            let expected = mode == "concurrent" ? ["fetch", "writer"] : ["writer", "fetch"]
            XCTAssertEqual(order.values, expected, mode)
        }
    }
}

extension CoreDataConcurrencyModeTests {
    func testCloseCompletesWhileObservedSaveIsInFlight() {
        forEachMode(tracked: false) { service, mode in
            let repository = Self.makeRepository(for: service)
            let observable = CoreDataContextObservable(
                service: service,
                mapper: repository.dataMapper,
                predicate: { _ in true }
            )

            let started = expectation(description: "observable started in \(mode)")
            observable.start { _ in started.fulfill() }
            wait(for: [started], timeout: Constants.expectationDuration)

            service.performWrite({ context in
                Thread.sleep(forTimeInterval: 0.3)
                Self.insertFeed(identifier: UUID().uuidString, name: "in-flight", in: context)
            }, completion: { _ in })

            Thread.sleep(forTimeInterval: 0.05)

            let closed = expectation(description: "close returned in \(mode)")
            let didClose = Flag()
            DispatchQueue.global().async {
                do {
                    try service.close()
                    didClose.set()
                } catch {
                    XCTFail("\(mode): close threw \(error)")
                }
                closed.fulfill()
            }

            wait(for: [closed], timeout: 5)
            XCTAssertNil(service.context, "\(mode): store was reopened or never closed")

            // A close that never returned still holds the lock; touching the service again would hang the suite.
            if didClose.isSet {
                try? service.drop()
            }
        }
    }

    func testCloseCompletesWhenReadCompletionReentersService() {
        forEachMode(tracked: false) { service, mode in
            let nested = expectation(description: "nested read completed in \(mode)")

            service.performRead({ _ in
                Thread.sleep(forTimeInterval: 0.3)
            }, completion: { _ in
                service.performRead({ _ in }, completion: { _ in nested.fulfill() })
            })

            Thread.sleep(forTimeInterval: 0.05)

            let closed = expectation(description: "close returned in \(mode)")
            let didClose = Flag()
            DispatchQueue.global().async {
                do {
                    try service.close()
                    didClose.set()
                } catch {
                    XCTFail("\(mode): close threw \(error)")
                }
                closed.fulfill()
            }

            wait(for: [closed, nested], timeout: 5)

            // A close that never returned still holds the lock; touching the service again would hang the suite.
            if didClose.isSet {
                try? service.close()
                try? service.drop()
            }
        }
    }

    /// A completion is done with the reading context, so tearing the service down from one must work.
    func testCloseFromReadCompletionReturns() {
        forEachMode(tracked: false) { service, mode in
            let closed = expectation(description: "close returned from read completion in \(mode)")
            let didClose = Flag()

            service.performRead({ _ in }, completion: { _ in
                do {
                    try service.close()
                    didClose.set()
                } catch {
                    XCTFail("\(mode): close threw \(error)")
                }

                closed.fulfill()
            })

            wait(for: [closed], timeout: 5)
            XCTAssertNil(service.context, "\(mode): store was not closed")

            // A close that never returned still owns the reader; touching the service again would hang the suite.
            if didClose.isSet {
                try? service.drop()
            }
        }
    }

    /// A read block still holds the store, so it cannot wait for itself. Report it instead of hanging.
    func testCloseFromReadBlockIsRejected() {
        forEachMode(tracked: false) { service, mode in
            guard mode == "concurrent" else {
                // Serial reads run on the writer, where ``performAndWait`` is reentrant and close still works.
                return
            }

            let done = expectation(description: "read block ran in \(mode)")
            let thrown = ErrorBox()

            service.performRead({ _ in
                do {
                    try service.close()
                } catch {
                    thrown.set(error)
                }
            }, completion: { _ in done.fulfill() })

            wait(for: [done], timeout: 5)

            guard case CoreDataServiceError.closeFromReadBlock? = thrown.value else {
                return XCTFail("\(mode): expected closeFromReadBlock, got \(String(describing: thrown.value))")
            }

            do {
                try service.close()
            } catch {
                XCTFail("\(mode): close threw \(error)")
            }

            try? service.drop()
        }
    }

    func testWorkArrivingDuringCloseIsRejected() {
        forEachMode(tracked: false) { service, mode in
            let closed = beginCloseWhileWriterIsBusy(service, mode)

            let rejected = expectation(description: "read rejected in \(mode)")
            service.performRead({ _ in }, completion: { result in
                guard case .failure(let error) = result,
                      case CoreDataServiceError.closeInProgress = error else {
                    return XCTFail("\(mode): expected closeInProgress, got \(result)")
                }
                rejected.fulfill()
            })

            wait(for: [rejected, closed], timeout: 5)

            XCTAssertNil(service.context, "\(mode): store was reopened while closing")
            try? service.drop()
        }
    }

    /// ``drop()`` gates on the store being closed; a close that is still draining is not closed yet.
    func testDropDuringCloseIsRejected() {
        forEachMode(tracked: false) { service, mode in
            let closed = beginCloseWhileWriterIsBusy(service, mode)

            do {
                try service.drop()
                XCTFail("\(mode): drop succeeded while the store was still draining")
            } catch CoreDataServiceError.closeInProgress {
                // expected
            } catch {
                XCTFail("\(mode): expected closeInProgress, got \(error)")
            }

            wait(for: [closed], timeout: 5)
            try? service.drop()
        }
    }

    /// A second ``close()`` must not report success while the first is still draining.
    func testSecondCloseDuringDrainIsRejected() {
        forEachMode(tracked: false) { service, mode in
            let closed = beginCloseWhileWriterIsBusy(service, mode)

            do {
                try service.close()
                XCTFail("\(mode): second close reported success while the first was still draining")
            } catch CoreDataServiceError.closeInProgress {
                // expected
            } catch {
                XCTFail("\(mode): expected closeInProgress, got \(error)")
            }

            wait(for: [closed], timeout: 5)
            try? service.drop()
        }
    }

    /// Only ```.serial``` can be asserted here. Its reads run on the writer, where a change left behind
    /// would join the next transaction, so the rollback is load-bearing and observable. A ```.concurrent```
    /// read runs on a throwaway context that is never saved, so there is nothing to roll back; leaving a
    /// change there trips an ```assert``` in ```performRead``` instead, which a test cannot catch.
    func testSerialReadRollsBackChangesLeftOnWriter() {
        forEachMode { service, mode in
            guard mode == "serial" else {
                return
            }

            let identifier = UUID().uuidString
            write(in: service) { Self.insertFeed(identifier: identifier, name: "original", in: $0) }

            read(in: service) { context in
                try Self.fetchFeed(identifier, in: context).name = "mutated"
            }

            let name = read(in: service) { try Self.fetchFeed(identifier, in: $0).name }
            XCTAssertEqual(name, "original", mode)
        }
    }

    func testInvalidReaderConcurrencyFailsBeforeOpeningStore() throws {
        let configuration = CoreDataServiceConfiguration.createDefaultConfigutation(
            with: Constants.defaultCoreDataModelName,
            databaseName: "ConcurrencyMode-invalid-\(UUID().uuidString)",
            incompatibleModelStrategy: .removeStore,
            concurrencyMode: .concurrent(readerConcurrency: 0)
        )
        let service = CoreDataService(configuration: configuration)
        services.append(service)

        let failed = expectation(description: "read fails")
        service.performRead({ _ in }, completion: { result in
            guard case .failure(let error) = result,
                  case CoreDataServiceError.invalidReaderConcurrency(0) = error else {
                return XCTFail("expected invalidReaderConcurrency, got \(result)")
            }
            failed.fulfill()
        })
        wait(for: [failed], timeout: Constants.expectationDuration)

        let url = try XCTUnwrap(service.databaseURL(with: .default))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "store was opened for an invalid configuration")
    }

    func testFailedSetupCompletionCanReenterService() {
        // Setup fails on every call; the completion retries from inside the failure callback.
        let configuration = CoreDataServiceConfiguration.createDefaultConfigutation(
            with: Constants.defaultCoreDataModelName,
            databaseName: "ConcurrencyMode-reenter-\(UUID().uuidString)",
            incompatibleModelStrategy: .removeStore,
            concurrencyMode: .concurrent(readerConcurrency: 0)
        )
        let service = CoreDataService(configuration: configuration)

        let retried = expectation(description: "retry completed")

        DispatchQueue.global().async {
            service.performRead({ _ in }, completion: { _ in
                service.performRead({ _ in }, completion: { _ in retried.fulfill() })
            })
        }

        wait(for: [retried], timeout: 5)
    }

    func testObserverResolutionKeepsWriterPendingChanges() {
        forEachMode { service, mode in
            let repository = Self.makeRepository(for: service)
            let observable = CoreDataContextObservable(
                service: service,
                mapper: repository.dataMapper,
                predicate: { _ in true }
            )

            let started = expectation(description: "observable started in \(mode)")
            observable.start { _ in started.fulfill() }
            wait(for: [started], timeout: Constants.expectationDuration)

            let identifier = UUID().uuidString
            write(in: service) { Self.insertFeed(identifier: identifier, name: "original", in: $0) }

            // Legacy block: saves, then leaves a change for a later save.
            let saved = expectation(description: "legacy block ran in \(mode)")
            service.performAsync { context, _ in
                defer { saved.fulfill() }
                guard let context, let feed = try? Self.fetchFeed(identifier, in: context) else {
                    return XCTFail("\(mode): no context or feed")
                }
                feed.name = "saved"
                try? context.save()
                feed.name = "pending"
            }
            wait(for: [saved], timeout: Constants.expectationDuration)

            let flushed = expectation(description: "pending change saved in \(mode)")
            service.performAsync { context, _ in
                try? context?.save()
                flushed.fulfill()
            }
            wait(for: [flushed], timeout: Constants.expectationDuration)

            let name = read(in: service) { try Self.fetchFeed(identifier, in: $0).name }
            XCTAssertEqual(name, "pending", "\(mode): observer resolution discarded the writer's pending change")
        }
    }
}

private extension CoreDataConcurrencyModeTests {
    final class Flag {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    final class ErrorBox {
        private let lock = NSLock()
        private var storage: Error?

        var value: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ error: Error) {
            lock.lock()
            storage = error
            lock.unlock()
        }
    }

    final class CompletionOrder {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    var modes: [(name: String, mode: CoreDataConcurrencyMode)] {
        [
            (name: "serial", mode: .serial),
            (name: "concurrent", mode: .concurrent(readerConcurrency: 2))
        ]
    }

    /// Runs ```body``` once per mode. Untracked services are not closed by ```tearDown```, for cases that
    /// exercise ```close()``` themselves and must not hang the suite if it never returns.
    func forEachMode(tracked: Bool = true, _ body: (CoreDataService, String) -> Void) {
        for (name, mode) in modes {
            let configuration = CoreDataServiceConfiguration.createDefaultConfigutation(
                with: Constants.defaultCoreDataModelName,
                databaseName: tracked ? "ConcurrencyMode-\(name)" : "ConcurrencyMode-\(name)-\(UUID().uuidString)",
                incompatibleModelStrategy: .removeStore,
                concurrencyMode: mode
            )

            let service = CoreDataService(configuration: configuration)

            if tracked {
                services.append(service)
            }

            body(service, name)
        }
    }

    /// Occupies the writer, then starts a ``close()`` on another thread and returns once it is draining.
    /// The returned expectation is fulfilled when that close returns.
    func beginCloseWhileWriterIsBusy(_ service: CoreDataService, _ mode: String) -> XCTestExpectation {
        service.performWrite({ context in
            Thread.sleep(forTimeInterval: 0.3)
            Self.insertFeed(identifier: UUID().uuidString, name: "in-flight", in: context)
        }, completion: { _ in })

        Thread.sleep(forTimeInterval: 0.05)

        let closed = expectation(description: "close returned in \(mode)")

        DispatchQueue.global().async {
            try? service.close()
            closed.fulfill()
        }

        // Let close() detach the store and start draining the busy writer.
        Thread.sleep(forTimeInterval: 0.05)

        return closed
    }

    static func makeRepository(for service: CoreDataService) -> CoreDataRepository<FeedData, CDFeed> {
        CoreDataRepository(
            databaseService: service,
            mapper: AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>()),
            filter: nil,
            sortDescriptors: []
        )
    }

    static func fetchFeed(_ identifier: String, in context: NSManagedObjectContext) throws -> CDFeed {
        let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
        request.predicate = NSPredicate(format: "identifier == %@", identifier)
        guard let feed = try context.fetch(request).first else {
            throw TestError()
        }
        return feed
    }

    @discardableResult
    func read<T>(in service: CoreDataService, _ block: @escaping (NSManagedObjectContext) throws -> T) -> T? {
        let done = expectation(description: "read")
        var value: T?
        service.performRead(block, completion: { result in
            switch result {
            case .success(let result):
                value = result
            case .failure(let error):
                XCTFail("read failed with \(error)")
            }
            done.fulfill()
        })
        wait(for: [done], timeout: Constants.expectationDuration)
        return value
    }

    static func insertFeed(identifier: String, name: String, in context: NSManagedObjectContext) {
        let feed = CDFeed(context: context)
        feed.identifier = identifier
        feed.name = name
        feed.status = "new"
    }

    func write(in service: CoreDataService, _ block: @escaping (NSManagedObjectContext) throws -> Void) {
        let done = expectation(description: "write")
        service.performWrite(block, completion: { result in
            if case .failure(let error) = result {
                XCTFail("write failed with \(error)")
            }
            done.fulfill()
        })
        wait(for: [done], timeout: Constants.expectationDuration)
    }

    func feedCount(in service: CoreDataService) -> Int? {
        let read = expectation(description: "count feeds")
        var count: Int?

        service.performRead({ context -> Int in
            try context.count(for: NSFetchRequest<CDFeed>(entityName: "CDFeed"))
        }, completion: { result in
            count = try? result.get()
            read.fulfill()
        })

        wait(for: [read], timeout: Constants.expectationDuration)

        return count
    }

    /// Polls the observer context every 20 ms for up to 2 s.
    func pollObserver<T>(
        _ service: CoreDataService,
        until isSatisfied: @escaping (T?) -> Bool,
        _ read: @escaping (NSManagedObjectContext) -> T?
    ) -> T? {
        let deadline = Date().addingTimeInterval(2)
        var value: T?

        repeat {
            let observed = expectation(description: "observe")
            service.performObserve { context, _ in
                value = context.flatMap(read)
                observed.fulfill()
            }
            wait(for: [observed], timeout: Constants.expectationDuration)

            if isSatisfied(value) {
                return value
            }

            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline

        return value
    }
}
