import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

class CoreDataContextObserverTests: XCTestCase {
    /// The store the cases run against; the concurrent subclass swaps it.
    class var facade: CoreDataRepositoryFacade { .shared }

    lazy var repository: CoreDataRepository<FeedData, CDFeed> = {
        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        return Self.facade.createCoreDataRepository(sortDescriptors: [sortDescriptor])
    }()

    let operationQueue: OperationQueue = OperationQueue()

    override func setUp() {
        try! Self.facade.clearDatabase()
    }

    override func tearDown() {
        try! Self.facade.clearDatabase()
    }

    func testInsertionWhenListEmpty() {
        let sourceObjects = (0..<10).map { _ in createRandomFeed(in: .default) }

        let validationBlock: ([DataProviderChange<FeedData>]) -> Bool = { (changes) in
            for change in changes {
                switch change {
                case .insert(let item):
                    if !sourceObjects.contains(item) {
                        return false
                    }
                default:
                    return false
                }
            }

            return sourceObjects.count == changes.count
        }

        performTest(updateObjects: sourceObjects, deletedIds: [], changesValidationBlock: validationBlock)
    }

    func testInsertionWhenListNotEmpty() {
        let initialObjects = (0..<15).map { _ in createRandomFeed(in: .default) }
        performSaveOperation(with: initialObjects, deletedIds: [])

        let sourceObjects = (0..<10).map { _ in createRandomFeed(in: .default) }

        let validationBlock: ([DataProviderChange<FeedData>]) -> Bool = { (changes) in
            for change in changes {
                switch change {
                case .insert(let item):
                    if !sourceObjects.contains(item) {
                        return false
                    }
                default:
                    return false
                }
            }

            return sourceObjects.count == changes.count
        }

        performTest(updateObjects: sourceObjects, deletedIds: [], changesValidationBlock: validationBlock)
    }

    func testUpdateObjects() {
        let initialObjects = (0..<15).map { _ in createRandomFeed(in: .default) }
        performSaveOperation(with: initialObjects, deletedIds: [])

        let updateObjects: [FeedData] = initialObjects.suffix(5).map { (object) in
            var updatedObject = object
            updatedObject.name = UUID().uuidString

            return updatedObject
        }

        let validationBlock: ([DataProviderChange<FeedData>]) -> Bool = { (changes) in
            for change in changes {
                switch change {
                case .update(let item):
                    if !updateObjects.contains(item) {
                        return false
                    }
                default:
                    return false
                }
            }

            return updateObjects.count == changes.count
        }

        performTest(updateObjects: updateObjects, deletedIds: [], changesValidationBlock: validationBlock)
    }

    func testDeleteObjects() {
        let initialObjects = (0..<15).map { _ in createRandomFeed(in: .default) }
        performSaveOperation(with: initialObjects, deletedIds: [])

        let deletingIds: [String] = initialObjects.suffix(5).map { $0.identifier }

        let validationBlock: ([DataProviderChange<FeedData>]) -> Bool = { (changes) in
            for change in changes {
                switch change {
                case .delete(let deletedIdentifier):
                    if !deletingIds.contains(deletedIdentifier) {
                        return false
                    }
                default:
                    return false
                }
            }

            return deletingIds.count == changes.count
        }

        performTest(updateObjects: [], deletedIds: deletingIds, changesValidationBlock: validationBlock)
    }

    func testInsertUpdateDeleteAtOnce() {
        let initialObjects = (0..<15).map { _ in createRandomFeed(in: .default) }
        performSaveOperation(with: initialObjects, deletedIds: [])

        let updatingObjects: [FeedData] = initialObjects.suffix(5).map { (object) in
            var updated = object
            updated.name = UUID().uuidString
            return updated
        }

        let deletingIds: [String] = initialObjects.prefix(5).map { $0.identifier }

        let insertingObjects = (0..<10).map { _ in createRandomFeed(in: .default) }

        let validationBlock: ([DataProviderChange<FeedData>]) -> Bool = { (changes) in
            var insertedCount = 0
            var updatedCount = 0
            var deletedCount = 0

            for change in changes {
                switch change {
                case .insert(let newItem):
                    if !insertingObjects.contains(newItem) {
                        return false
                    }

                    insertedCount += 1
                case .update(let item):
                    if !updatingObjects.contains(item) {
                        return false
                    }

                    updatedCount += 1
                case .delete(let deletedIdentifier):
                    if !deletingIds.contains(deletedIdentifier) {
                        return false
                    }

                    deletedCount += 1
                }
            }

            return insertingObjects.count == insertedCount &&
                updatingObjects.count == updatedCount &&
                deletingIds.count == deletedCount
        }

        performTest(updateObjects: insertingObjects + updatingObjects, deletedIds: deletingIds, changesValidationBlock: validationBlock)
    }

    /// An observable cannot tell "this row left my set" from "this row was never in my set": the payload is
    /// filtered by entity only, and the predicate sees just the post-change object. It therefore reports
    /// neither, as 2.x did, rather than guessing a delete for every row another predicate owns.
    func testUpdateOfRowOutsidePredicateIsNotDelivered() {
        var feed = createRandomFeed(in: .default)
        feed.favorite = false
        _ = performSaveOperation(with: [feed], deletedIds: [])

        let outside = CoreDataContextObservable<FeedData, CDFeed>(
            service: Self.facade.databaseService,
            mapper: repository.dataMapper,
            predicate: { $0.favorite }
        )

        let inside = CoreDataContextObservable<FeedData, CDFeed>(
            service: Self.facade.databaseService,
            mapper: repository.dataMapper,
            predicate: { !$0.favorite }
        )

        for observable in [outside, inside] {
            let started = XCTestExpectation()
            observable.start { error in
                XCTAssertNil(error)
                started.fulfill()
            }
            wait(for: [started], timeout: Constants.expectationDuration)
        }

        let outsideToken = NSObject()
        var outsideChanges: [DataProviderChange<FeedData>] = []
        let outsideDelivered = XCTestExpectation()
        outsideDelivered.isInverted = true

        outside.addObserver(outsideToken, deliverOn: .main) { changes in
            outsideChanges.append(contentsOf: changes)
            outsideDelivered.fulfill()
        }

        let insideToken = NSObject()
        let insideDelivered = XCTestExpectation()
        insideDelivered.assertForOverFulfill = false

        inside.addObserver(insideToken, deliverOn: .main) { _ in
            insideDelivered.fulfill()
        }

        var updated = feed
        updated.name = "renamed"
        _ = performSaveOperation(with: [updated], deletedIds: [])

        // The matching observable proves the save landed and was resolved.
        wait(for: [insideDelivered], timeout: Constants.expectationDuration)
        wait(for: [outsideDelivered], timeout: 1)

        XCTAssertTrue(
            outsideChanges.isEmpty,
            "delivered \(outsideChanges) for a row that never matched this predicate"
        )
    }

    /// A legacy ``performAsync`` block can leave changes the writer has not committed. What an observable
    /// delivers must be the state the save actually committed, never those pending values — a later
    /// rollback would discard them and leave the subscriber holding something that never existed.
    func testDeliveredStateIsCommittedWhenWriterLeavesPendingChanges() {
        let feed = createRandomFeed(in: .default)
        _ = performSaveOperation(with: [feed], deletedIds: [])

        let observable = CoreDataContextObservable(
            service: Self.facade.databaseService,
            mapper: repository.dataMapper,
            predicate: { _ in true }
        )

        let started = XCTestExpectation()
        observable.start { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: Constants.expectationDuration)

        let token = NSObject()
        let delivered = XCTestExpectation()
        delivered.assertForOverFulfill = false
        var names: [String] = []

        observable.addObserver(token, deliverOn: .main) { changes in
            for case .update(let item) in changes {
                names.append(item.name)
            }

            delivered.fulfill()
        }

        let mutated = XCTestExpectation()

        Self.facade.databaseService.performAsync { optionalContext, _ in
            defer { mutated.fulfill() }

            guard let context = optionalContext else {
                return XCTFail("no context")
            }

            let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
            request.predicate = NSPredicate(format: "identifier == %@", feed.identifier)

            guard let entity = try? context.fetch(request).first else {
                return XCTFail("feed not found")
            }

            entity.name = "saved"
            try? context.save()

            // Left uncommitted on purpose: this value must never be delivered.
            entity.name = "pending"
        }

        wait(for: [mutated, delivered], timeout: Constants.expectationDuration)

        XCTAssertEqual(names, ["saved"], "observable delivered an uncommitted value")
    }

    /// The delivery must be queued before the write's completion runs, so a completion that unsubscribes
    /// does not drop the very change it is reacting to.
    func testChangeDeliveredWhenObserverRemovedInWriteCompletion() {
        guard case .serial = Self.facade.databaseService.configuration.concurrencyMode else {
            // Concurrent resolves on its own context, so this ordering is a race there, not a guarantee.
            return
        }

        let observable = CoreDataContextObservable(
            service: Self.facade.databaseService,
            mapper: repository.dataMapper,
            predicate: { _ in true }
        )

        let started = XCTestExpectation()
        observable.start { _ in started.fulfill() }
        wait(for: [started], timeout: Constants.expectationDuration)

        let token = NSObject()
        let delivered = XCTestExpectation()
        delivered.assertForOverFulfill = false
        var received: [DataProviderChange<FeedData>] = []

        observable.addObserver(token, deliverOn: .main) { changes in
            received.append(contentsOf: changes)
            delivered.fulfill()
        }

        let feed = createRandomFeed(in: .default)

        // A nil queue runs the completion inline on the writer, right after the save that notified us.
        repository.save(updating: [feed], deleting: [], runCompletionIn: nil) { _ in
            observable.removeObserver(token)
        }

        wait(for: [delivered], timeout: Constants.expectationDuration)

        XCTAssertEqual(received.count, 1, "the change was dropped by the removal in the completion")
    }

    /// A row of a sub-entity is still a row of the observed entity. ``CDVideoFeed`` inherits ``CDFeed``, so
    /// its instances are ``CDFeed`` objects, but its ``entity.name`` is its own — selecting the payload by
    /// exact entity name drops it, while the class check the live-delete path uses does not.
    func testSubEntityInsertIsDelivered() {
        let observable = CoreDataContextObservable<FeedData, CDFeed>(
            service: Self.facade.databaseService,
            mapper: repository.dataMapper,
            predicate: { _ in true }
        )

        let started = XCTestExpectation()
        observable.start { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        wait(for: [started], timeout: Constants.expectationDuration)

        let token = NSObject()
        let delivered = XCTestExpectation(description: "sub-entity change delivered")
        delivered.assertForOverFulfill = false
        var received: [DataProviderChange<FeedData>] = []

        observable.addObserver(token, deliverOn: .main) { changes in
            received.append(contentsOf: changes)
            delivered.fulfill()
        }

        let model = createRandomFeed(in: .default)
        let written = XCTestExpectation(description: "sub-entity row written")

        Self.facade.databaseService.performWrite({ [mapper = repository.dataMapper] context in
            let object = NSEntityDescription.insertNewObject(forEntityName: "CDVideoFeed", into: context)

            guard let feed = object as? CDFeed else {
                return XCTFail("CDVideoFeed did not instantiate as CDFeed")
            }

            // Populated through the mapper so the row carries values ``transform`` can read back; only the
            // entity differs from what the repository would write.
            try mapper.populate(entity: feed, from: model, using: context)
        }, completion: { result in
            if case .failure(let error) = result {
                XCTFail("write failed with \(error)")
            }

            written.fulfill()
        })

        wait(for: [written, delivered], timeout: Constants.expectationDuration)

        guard case .insert(let item)? = received.first else {
            return XCTFail("expected an insert for the sub-entity row, got \(received)")
        }

        XCTAssertEqual(item.identifier, model.identifier)
    }

    // MARK: Private

    private func performTest(updateObjects: [FeedData],
                             deletedIds: [String],
                             changesValidationBlock: @escaping ([DataProviderChange<FeedData>]) -> Bool) {
        performTest(updateObjects: updateObjects,
                    deletedIds: deletedIds,
                    changesValidationBlock: changesValidationBlock) { $0 is CDFeed }
    }

    private func performTest(updateObjects: [FeedData],
                             deletedIds: [String],
                             changesValidationBlock: @escaping ([DataProviderChange<FeedData>]) -> Bool,
                             predicateBlock: @escaping (NSManagedObject) -> Bool) {
        let observable = CoreDataContextObservable(service: Self.facade.databaseService,
                                                   mapper: repository.dataMapper,
                                                   predicate: predicateBlock)

        observable.start { (optionalError) in
            if let error = optionalError {
                XCTFail("Did receive error \(error)")
            }
        }

        let expectation = XCTestExpectation()

        observable.addObserver(self, deliverOn: .main) { (changes) in
            defer {
                expectation.fulfill()
            }

            if !changesValidationBlock(changes) {
                XCTFail()
            }
        }

        let operation = repository.saveOperation({ updateObjects }, { deletedIds })
        operationQueue.addOperation(operation)

        wait(for: [expectation], timeout: Constants.expectationDuration)
    }

    @discardableResult
    private func performSaveOperation(with updatedObjects: [FeedData], deletedIds: [String]) -> Result<Void, Error>? {
        let expectation = XCTestExpectation()

        let operation = repository.saveOperation({ updatedObjects }, { deletedIds })

        var result: Result<Void, Error>?

        operation.completionBlock = {
            result = operation.result

            expectation.fulfill()
        }

        operationQueue.addOperation(operation)

        wait(for: [expectation], timeout: Constants.expectationDuration)

        return result
    }

    /// Starts an observable, enqueues ```saves``` back to back and returns the change batches delivered up to
    /// and including the first one ```until``` accepts.
    private func collectDeliveries(
        saves: [[FeedData]],
        predicateBlock: @escaping (NSManagedObject) -> Bool,
        until: @escaping ([DataProviderChange<FeedData>]) -> Bool
    ) -> [[DataProviderChange<FeedData>]] {
        let observable = CoreDataContextObservable(service: Self.facade.databaseService,
                                                   mapper: repository.dataMapper,
                                                   predicate: predicateBlock)

        let startExpectation = XCTestExpectation()

        observable.start { optionalError in
            if let error = optionalError {
                XCTFail("Did receive error \(error)")
            }

            startExpectation.fulfill()
        }

        wait(for: [startExpectation], timeout: Constants.expectationDuration)

        let expectation = XCTestExpectation()

        var deliveries: [[DataProviderChange<FeedData>]] = []

        observable.addObserver(self, deliverOn: .main) { changes in
            deliveries.append(changes)

            if until(changes) {
                expectation.fulfill()
            }
        }

        // The queue is concurrent; chain the saves so they commit in the given order while the observer
        // still resolves them asynchronously.
        var previous: Operation?

        for save in saves {
            let operation = repository.saveOperation({ save }, { [] })

            if let previous {
                operation.addDependency(previous)
            }

            operationQueue.addOperation(operation)
            previous = operation
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)

        return deliveries
    }
}
