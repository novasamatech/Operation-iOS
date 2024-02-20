import XCTest
@testable import Operation_iOS

class DataProviderBaseTests: XCTestCase {

    func fetchById<T>(_ identifier: String, from dataProvider: DataProvider<T>) -> Result<T?, Error>? {
        let expectation = XCTestExpectation()

        let fetchByIdWrapper = dataProvider.fetch(by: identifier) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)

        return fetchByIdWrapper.targetOperation.result
    }

    func fetch<T>(page: UInt, from dataProvider: DataProvider<T>) -> Result<[T], Error>? {
        let expectation = XCTestExpectation()

        let fetchByPageWrapper = dataProvider.fetch(page: page) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)

        return fetchByPageWrapper.targetOperation.result
    }
}
