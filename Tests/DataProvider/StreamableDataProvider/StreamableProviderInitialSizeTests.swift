import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/**
 *  ```initialSize``` caps the snapshot the repository is asked for, and must equally cap what changes
 *  buffered during registration add to it: an observer that asked for a window of N must not be handed
 *  more than N on its first delivery.
 */
class StreamableProviderInitialSizeTests: XCTestCase {
    override func setUp() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    override func tearDown() {
        try! CoreDataRepositoryFacade.shared.clearDatabase()
    }

    func testFirstDeliveryStaysWithinInitialSizeWhenChangesArriveDuringAdd() {
        // given

        let repository: CoreDataRepository<FeedData, CDFeed> =
            CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let anyRepository = AnyDataProviderRepository(repository)

        saveSync([createRandomFeed(in: .default)], to: anyRepository)

        let observable = CoreDataContextObservable(service: repository.databaseService,
                                                   mapper: repository.dataMapper,
                                                   predicate: { _ in true })

        let startExpectation = XCTestExpectation()
        observable.start { _ in startExpectation.fulfill() }
        wait(for: [startExpectation], timeout: Constants.expectationDuration)

        let hookedRepository = HookedRepository(wrapped: anyRepository)
        hookedRepository.afterFetchSlice = {
            saveSync([createRandomFeed(in: .default)], to: anyRepository)
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

        var firstDelivery: [DataProviderChange<FeedData>]?

        let deliveryExpectation = XCTestExpectation()
        deliveryExpectation.assertForOverFulfill = false

        dataProvider.addObserver(
            self,
            deliverOn: .main,
            executing: { changes in
                if firstDelivery == nil {
                    firstDelivery = changes
                    deliveryExpectation.fulfill()
                }
            },
            failing: { error in
                XCTFail("Unexpected failure: \(error)")
            },
            options: StreamableProviderObserverOptions(alwaysNotifyOnRefresh: false,
                                                       waitsInProgressSyncOnAdd: false,
                                                       initialSize: 1,
                                                       refreshWhenEmpty: false)
        )

        wait(for: [deliveryExpectation], timeout: Constants.expectationDuration)

        // then

        XCTAssertEqual(
            firstDelivery?.count,
            1,
            "first delivery must respect initialSize, got \(String(describing: firstDelivery?.count))"
        )

        dataProvider.removeObserver(self)
    }
}
