import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  A change committed between an observer's snapshot fetch and the moment the provider starts
 *  observing its source belongs to that observer: it is in neither the snapshot nor any later
 *  callback, and a repository backed by a source that cannot replay history never re-reads it.
 *
 *  ```HookedRepository``` commits the change inside that window rather than racing for it, so the
 *  test is deterministic.
 */
class StreamableProviderSubscribeRaceTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testChangeCommittedWhileAddingObserverIsDelivered() throws {
        // given

        let repository: CoreDataRepository<FeedData, CDFeed> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let anyRepository = AnyDataProviderRepository(repository)

        let existingItem = createRandomFeed(in: .default)
        saveSync([existingItem], to: anyRepository)

        let observable = CoreDataContextObservable(service: repository.databaseService,
                                                   mapper: repository.dataMapper,
                                                   predicate: { _ in true })

        let startExpectation = XCTestExpectation()

        observable.start { error in
            XCTAssertNil(error)
            startExpectation.fulfill()
        }

        wait(for: [startExpectation], timeout: Constants.expectationDuration)

        let windowItem = createRandomFeed(in: .default)

        let hookedRepository = HookedRepository(wrapped: anyRepository)
        hookedRepository.afterFetchAll = {
            saveSync([windowItem], to: anyRepository)
        }

        let source: AnyStreamableSource<FeedData> = createStreamableSourceMock(
            repository: repository,
            returns: []
        )

        let dataProvider = StreamableProvider(
            source: source,
            repository: AnyDataProviderRepository(hookedRepository),
            observable: AnyDataProviderRepositoryObservable(observable),
            operationManager: OperationManager()
        )

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
            options: StreamableProviderObserverOptions(
                alwaysNotifyOnRefresh: false,
                waitsInProgressSyncOnAdd: false,
                initialSize: 0,
                refreshWhenEmpty: false
            )
        )

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        // then

        XCTAssertTrue(
            receivedIdentifiers.contains(existingItem.identifier),
            "Snapshot item must be delivered"
        )

        XCTAssertTrue(
            receivedIdentifiers.contains(windowItem.identifier),
            "Item committed while the observer was being added must be delivered"
        )

        dataProvider.removeObserver(self)
    }
}
