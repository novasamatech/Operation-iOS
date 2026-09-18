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

    func testCloseWaitsForQueuedReads() throws {
        forEachMode { service, mode in
            let order = CompletionOrder()

            for index in 0 ..< 5 {
                service.performRead({ _ in
                    Thread.sleep(forTimeInterval: 0.05)
                }, completion: { _ in
                    order.append("read-\(index)")
                })
            }

            do {
                try service.close()
            } catch {
                XCTFail("\(mode): close threw \(error)")
            }

            XCTAssertEqual(order.values.count, 5, "\(mode): close returned before every queued read completed")
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

private extension CoreDataConcurrencyModeTests {
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

    func forEachMode(_ body: (CoreDataService, String) -> Void) {
        for (name, mode) in modes {
            let configuration = CoreDataServiceConfiguration.createDefaultConfigutation(
                with: Constants.defaultCoreDataModelName,
                databaseName: "ConcurrencyMode-\(name)",
                incompatibleModelStrategy: .removeStore,
                concurrencyMode: mode
            )

            let service = CoreDataService(configuration: configuration)
            services.append(service)

            body(service, name)
        }
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
