import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  ```start``` binds to the writer after a hop onto the writer's own queue, so a transaction already
 *  enqueued there when ```start``` is called commits — and posts its did-save — before the binding
 *  exists. The change is then delivered to no one and never re-read.
 *
 *  Both ```performWrite``` and ```start``` enqueue their blocks on the writer synchronously, in
 *  program order, so the interleaving below is deterministic rather than raced for.
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

        wait(for: [writeExpectation], timeout: Constants.expectationDuration)

        // then

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        XCTAssertTrue(
            receivedIdentifiers.contains(item.identifier),
            "Transaction enqueued before start must be delivered"
        )
    }
}
