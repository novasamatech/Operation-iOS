import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

class DataProviderObserverTests: XCTestCase {
    func testAddObserverWaitInitAndRemove() {
        // given

        let dataProvider = prepareDataProvider()

        let operationQueue = OperationQueue()

        // when

        let addObserverWaitingOperation = ClosureOperation {
            while(dataProvider.observers.isEmpty) {
                usleep(10000)
            }
        }

        let addExpectation = XCTestExpectation()

        addObserverWaitingOperation.completionBlock = {
            addExpectation.fulfill()
        }

        dataProvider.addObserver(self,
                                 deliverOn: .main,
                                 executing: { _ in },
                                 failing: { _ in })

        operationQueue.addOperation(addObserverWaitingOperation)

        wait(for: [addExpectation], timeout: Constants.expectationDuration)

        XCTAssertTrue(!dataProvider.observers.isEmpty)
        XCTAssertTrue(dataProvider.pendingObservers.isEmpty)

        // then

        let removeObseverOperation = ClosureOperation {
            while(!dataProvider.observers.isEmpty) {
                usleep(10000)
            }
        }

        let removeExpectation = XCTestExpectation()

        removeObseverOperation.completionBlock = {
            removeExpectation.fulfill()
        }

        dataProvider.removeObserver(self)

        operationQueue.addOperation(removeObseverOperation)

        wait(for: [removeExpectation], timeout: Constants.expectationDuration)

        XCTAssertTrue(dataProvider.observers.isEmpty)
        XCTAssertTrue(dataProvider.pendingObservers.isEmpty)
    }

    func testAddObserverAndImmedeatellyRemove() {
        // given

        let dataProvider = prepareDataProvider()

        // when

        var resultError: Error?

        let expectation = XCTestExpectation()

        dataProvider.addObserver(self,
                                 deliverOn: .main,
                                 executing: { _ in },
                                 failing: { error in
                                    resultError = error
                                    expectation.fulfill()
        })

        dataProvider.removeObserver(self)

        // then

        wait(for: [expectation], timeout: Constants.expectationDuration)

        if let error = resultError as? DataProviderError {
            XCTAssertEqual(error, DataProviderError.dependencyCancelled)
        } else {
            XCTFail("Unexpected error \(String(describing: resultError))")
        }

        XCTAssertTrue(dataProvider.pendingObservers.isEmpty)
    }

    func testMultipleAddObserverAtOnce() {
        // given

        let dataProvider = prepareDataProvider()

        // when

        var resultError: Error?

        let expectation = XCTestExpectation()

        dataProvider.addObserver(self,
                                 deliverOn: .main,
                                 executing: { _ in },
                                 failing: { _ in })

        dataProvider.addObserver(self,
                                 deliverOn: .main,
                                 executing: { _ in },
                                 failing: { error in
                                    resultError = error
                                    expectation.fulfill()
        })

        // then

        wait(for: [expectation], timeout: Constants.expectationDuration)

        if let error = resultError as? DataProviderError {
            XCTAssertEqual(error, DataProviderError.observerAlreadyAdded)
        } else {
            XCTFail("Unexpected error \(String(describing: resultError))")
        }
    }

    // MARK: Private

    private func prepareDataProvider() -> DataProvider<FeedData> {
        let trigger = DataProviderEventTrigger.onNone
        let source: AnyDataProviderSource<FeedData> = createDataSourceMock(returns: [])
        let repository: CoreDataRepository<FeedData, CDFeed> = CoreDataRepositoryFacade.shared.createCoreDataRepository()

        let dataProvider = DataProvider<FeedData>(source: source,
                                                  repository: AnyDataProviderRepository(repository),
                                                  updateTrigger: trigger)

        return dataProvider
    }
}
