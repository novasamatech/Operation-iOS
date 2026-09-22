import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  Cancelling a subscription finishes its snapshot operation, so that operation's completion can arrive
 *  after the same observer object has subscribed again. The late completion belongs to a subscription that
 *  no longer exists and must leave the current one — its pending entry, its buffer, its source
 *  subscription — untouched.
 */
class StreamableProviderStaleCompletionTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testLateCompletionOfCancelledSubscriptionLeavesItsSuccessorIntact() {
        // given

        let repository: CoreDataRepository<FeedData, CDFeed> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let anyRepository = AnyDataProviderRepository(repository)

        let existingItem = createRandomFeed(in: .default)
        saveSync([existingItem], to: anyRepository)

        // Occupies the provider's queue so no snapshot completes on its own: every completion in this test
        // is one the test itself drives.
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1

        let gate = DispatchSemaphore(value: 0)
        operationQueue.addOperation { gate.wait() }

        let observable = CoreDataContextObservable(service: repository.databaseService,
                                                   mapper: repository.dataMapper,
                                                   predicate: { _ in true })

        let startExpectation = XCTestExpectation()
        observable.start { _ in startExpectation.fulfill() }
        wait(for: [startExpectation], timeout: Constants.expectationDuration)

        let source: AnyStreamableSource<FeedData> = createStreamableSourceMock(
            repository: repository,
            returns: []
        )

        let dataProvider = StreamableProvider(
            source: source,
            repository: anyRepository,
            observable: AnyDataProviderRepositoryObservable(observable),
            operationManager: OperationManager(operationQueue: operationQueue)
        )

        let options = StreamableProviderObserverOptions(alwaysNotifyOnRefresh: false,
                                                        waitsInProgressSyncOnAdd: false,
                                                        initialSize: 0,
                                                        refreshWhenEmpty: false)

        var receivedIdentifiers: Set<String> = []

        // Kept apart: the cancelled subscription is entitled to its own ```dependencyCancelled```, which is
        // what ```testAddObserverAndImmedeatellyRemove``` pins. The claim here is about its successor.
        var failures: [Int: Error] = [:]

        let deliveryExpectation = XCTestExpectation()
        deliveryExpectation.assertForOverFulfill = false

        let subscribe: (Int) -> Void = { attempt in
            dataProvider.addObserver(
                self,
                deliverOn: .main,
                executing: { changes in
                    receivedIdentifiers.formUnion(changes.compactMap { $0.item?.identifier })

                    if !receivedIdentifiers.isEmpty {
                        deliveryExpectation.fulfill()
                    }
                },
                failing: { error in
                    failures[attempt] = error
                },
                options: options
            )
        }

        // when

        subscribe(1)
        waitUntil { dataProvider.pendingObservers.count == 1 }

        let firstOperation = dataProvider.pendingObservers.first?.operation

        // Holds the provider's serial queue so the removal and the re-subscription are both queued behind
        // it. Cancelling finishes the first snapshot operation during the removal, and its completion can
        // only be appended after the re-subscription that is already waiting — which is exactly the
        // ordering that makes a late completion land on its successor's state.
        let processingGate = DispatchSemaphore(value: 0)
        dataProvider.processingQueue.async { processingGate.wait() }

        dataProvider.removeObserver(self)
        subscribe(2)

        processingGate.signal()

        // By operation identity, not by count: the successor's entry is what must be in place before the
        // snapshots are allowed to run, and a count cannot tell it from the entry it replaced.
        waitUntil {
            let pendingOperation = dataProvider.pendingObservers.first?.operation

            return pendingOperation != nil && pendingOperation !== firstOperation
        }

        gate.signal()

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        // then

        XCTAssertTrue(
            receivedIdentifiers.contains(existingItem.identifier),
            "The subscription that replaced the cancelled one must still be delivered"
        )

        XCTAssertNil(
            failures[2],
            "The successor must not be failed by the cancelled subscription's completion: "
                + "\(String(describing: failures[2]))"
        )

        dataProvider.removeObserver(self)
    }
}

private extension StreamableProviderStaleCompletionTests {
    func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTestExpectation()

        DispatchQueue.global().async {
            while !condition() {
                usleep(1000)
            }

            expectation.fulfill()
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)
    }
}
