import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  ```start``` used to bind from a block hopped onto the writer's own queue, so a transaction already
 *  queued there when ```start``` was called always commited — and posted its did-save — first. The change
 *  was then delivered to no one and never re-read.
 *
 *  The writer is held busy below, so the transaction is provably still queued and uncommitted at the
 *  moment ```start``` is called: that is the ordering the fix owns, and it is pinned here rather than
 *  raced for. A transaction that commits while ```start``` is registering is a genuine race and is not
 *  what this test asserts.
 */
class CoreDataContextObservableStartRaceTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testTransactionEnqueuedBeforeStartIsDelivered() {
        // given

        let repository: CoreDataRepository<FeedData, CDFeed> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let service = repository.databaseService

        // Open the store up front so nothing but writer queue order decides the outcome.
        let openExpectation = XCTestExpectation()

        service.performAsync { _, error in
            XCTAssertNil(error)
            openExpectation.fulfill()
        }

        wait(for: [openExpectation], timeout: Constants.expectationDuration)

        let observable = CoreDataContextObservable(service: service,
                                                   mapper: repository.dataMapper,
                                                   predicate: { _ in true })

        var receivedIdentifiers: Set<String> = []

        let deliveryExpectation = XCTestExpectation()
        deliveryExpectation.assertForOverFulfill = false

        observable.addObserver(self, deliverOn: .main) { changes in
            for change in changes {
                if let item = change.item {
                    receivedIdentifiers.insert(item.identifier)
                }
            }

            if !receivedIdentifiers.isEmpty {
                deliveryExpectation.fulfill()
            }
        }

        let item = createRandomFeed(in: .default)

        // when

        // Occupies the writer, so the transaction below is queued behind it and cannot commit until the
        // gate is released — no matter how long registering takes.
        let gate = DispatchSemaphore(value: 0)

        service.performAsync { _, _ in
            gate.wait()
        }

        let writeExpectation = XCTestExpectation()

        service.performWrite({ context in
            try repository.save(models: [item], in: context)
        }, completion: { result in
            if case .failure(let error) = result {
                XCTFail("Unexpected write failure: \(error)")
            }

            writeExpectation.fulfill()
        })

        observable.start { error in
            XCTAssertNil(error)
        }

        gate.signal()

        wait(for: [writeExpectation], timeout: Constants.expectationDuration)

        // then

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        XCTAssertTrue(
            receivedIdentifiers.contains(item.identifier),
            "Transaction enqueued before start must be delivered"
        )
    }
}
