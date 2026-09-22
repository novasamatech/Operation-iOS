import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  A synchronization that commits while an observer is being added notifies the observers registered at
 *  that moment — which does not include the one still waiting for its snapshot. Its snapshot was read
 *  before the save, so the change reaches it through neither path and nothing re-reads it.
 *
 *  The sync is driven from the joining observer's own snapshot fetch, and the test waits for an already
 *  registered observer to witness it, so the interleaving is deterministic rather than raced for.
 */
class DataProviderSubscribeRaceTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testSyncCommittedWhileAddingObserverIsDelivered() {
        // given

        let repository: CoreDataRepository<FeedData, CDFeed> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let anyRepository = AnyDataProviderRepository(repository)

        let existingItem = createRandomFeed(in: .default)
        let windowItem = createRandomFeed(in: .default)

        saveSync([existingItem], to: anyRepository)

        let hookedRepository = HookedRepository(wrapped: anyRepository)

        let dataProvider = DataProvider(
            source: createDataSourceMock(returns: [existingItem, windowItem]),
            repository: AnyDataProviderRepository(hookedRepository),
            updateTrigger: DataProviderEventTrigger.onNone
        )

        // An observer that is already registered tells us when the sync has notified: at that point the
        // observer still being added has been passed over.
        let witnessQueue = DispatchQueue(label: "io.novasama.test.witness")
        let witnessedSync = DispatchSemaphore(value: 0)

        let witnessReady = XCTestExpectation()

        dataProvider.addObserver(
            WitnessObserver.shared,
            deliverOn: witnessQueue,
            executing: { changes in
                if changes.contains(where: { $0.item?.identifier == windowItem.identifier }) {
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

        hookedRepository.afterFetchAll = {
            guard !didTriggerSync else {
                return
            }

            didTriggerSync = true

            dataProvider.refresh()

            witnessedSync.wait()
        }

        // when

        var receivedIdentifiers: Set<String> = []

        let deliveryExpectation = XCTestExpectation()
        deliveryExpectation.assertForOverFulfill = false

        dataProvider.addObserver(
            self,
            deliverOn: .main,
            executing: { changes in
                for change in changes {
                    switch change {
                    case .insert(let item), .update(let item):
                        receivedIdentifiers.insert(item.identifier)
                    case .delete(let identifier):
                        receivedIdentifiers.remove(identifier)
                    }
                }

                if receivedIdentifiers.count >= 2 {
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

        XCTAssertTrue(
            receivedIdentifiers.contains(existingItem.identifier),
            "Snapshot item must be delivered"
        )

        XCTAssertTrue(
            receivedIdentifiers.contains(windowItem.identifier),
            "Item synchronized while the observer was being added must be delivered"
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
