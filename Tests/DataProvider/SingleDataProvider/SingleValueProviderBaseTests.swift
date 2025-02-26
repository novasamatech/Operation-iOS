import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

class SingleValueProviderBaseTests: XCTestCase {
    func fetch<T>(from dataProvider: SingleValueProvider<T>) -> Result<T?, Error>? {
        let expectation = XCTestExpectation()

        let fetchWrapper = dataProvider.fetch { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)

        return fetchWrapper.targetOperation.result
    }
}
