import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  The single-value counterpart of ```DataProviderSubscribeRaceTests```: a synchronization that commits
 *  while an observer is being added notifies only the observers registered at that moment, and the
 *  joining observer's snapshot was read before the save.
 */
class SingleValueProviderSubscribeRaceTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testSyncCommittedWhileAddingObserverIsDelivered() {
        // given

        let repository: CoreDataRepository<SingleValueProviderObject, CDSingleValue> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let hookedRepository = HookedRepository(wrapped: AnyDataProviderRepository(repository))

        let windowItem = createRandomFeed(in: .default)

        let dataProvider = SingleValueProvider<FeedData>(
            targetIdentifier: UUID().uuidString,
            source: createSingleValueSourceMock(returns: windowItem),
            repository: AnyDataProviderRepository(hookedRepository),
            updateTrigger: DataProviderEventTrigger.onNone
        )

        // An observer that is already registered tells us when the sync has notified: at that point the
        // observer still being added has been passed over.
        let witnessQueue = DispatchQueue(label: "io.novasama.test.witness.single")
        let witnessedSync = DispatchSemaphore(value: 0)

        let witnessReady = XCTestExpectation()

        dataProvider.addObserver(
            WitnessObserver.shared,
            deliverOn: witnessQueue,
            executing: { changes in
                if changes.contains(where: { $0.item == windowItem }) {
                    witnessedSync.signal()
                } else {
                    witnessReady.fulfill()
                }
            },
            failing: { error in
                XCTFail("Unexpected witness failure: \(error)")
            },
            options: DataProviderObserverOptions(alwaysNotifyOnRefresh: false,
                                                 waitsInProgressSyncOnAdd: false)
        )

        wait(for: [witnessReady], timeout: Constants.expectationDuration)

        var didTriggerSync = false

        hookedRepository.afterFetchById = {
            guard !didTriggerSync else {
                return
            }

            didTriggerSync = true

            dataProvider.refresh()

            witnessedSync.wait()
        }

        // when

        var receivedItems: [FeedData] = []

        let deliveryExpectation = XCTestExpectation()
        deliveryExpectation.assertForOverFulfill = false

        dataProvider.addObserver(
            self,
            deliverOn: .main,
            executing: { changes in
                receivedItems.append(contentsOf: changes.compactMap { $0.item })

                if !receivedItems.isEmpty {
                    deliveryExpectation.fulfill()
                }
            },
            failing: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            options: DataProviderObserverOptions(alwaysNotifyOnRefresh: false,
                                                 waitsInProgressSyncOnAdd: false)
        )

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        // then

        XCTAssertEqual(
            receivedItems.first,
            windowItem,
            "Value synchronized while the observer was being added must be delivered"
        )

        // The database is dropped in tearDown: let this provider's work finish against a store that is
        // still open, rather than leaving it to fail inside whichever test runs next.
        dataProvider.removeObserver(self)
        dataProvider.removeObserver(WitnessObserver.shared)
        dataProvider.executionQueue.waitUntilAllOperationsAreFinished()
    }
}

private final class WitnessObserver {
    static let shared = WitnessObserver()
}
