import Foundation
import Operation_iOS
import XCTest

public typealias OperationEnqueuClosure = ([Operation]) -> Void

public func modifyRepository<T: Identifiable>(_ repository: AnyDataProviderRepository<T>,
                                       handler: XCTestCase,
                                       saving: @escaping () throws -> [T],
                                       deleting: @escaping () throws -> [String],
                                       enqueueClosure: OperationEnqueuClosure? = nil) throws {
    let operation = repository.saveOperation(saving, deleting)
    try handleOperation(operation, handler: handler, enqueueClosure: enqueueClosure)
}

public func deleteAllFromRepository<T: Identifiable>(_ repository: AnyDataProviderRepository<T>,
                                              handler: XCTestCase,
                                              enqueueClosure: OperationEnqueuClosure? = nil) throws {
    let operation = repository.deleteAllOperation()
    try handleOperation(operation, handler: handler, enqueueClosure: enqueueClosure)
}

// MARK: Private

private func handleOperation<T>(_ operation: BaseOperation<T>,
                                handler: XCTestCase,
                                enqueueClosure: OperationEnqueuClosure?) throws {
    let expectation = XCTestExpectation()

    operation.completionBlock = {
        expectation.fulfill()
    }

    if let enqueueClosure = enqueueClosure {
        enqueueClosure([operation])
    } else {
        OperationQueue().addOperation(operation)
    }

    handler.wait(for: [expectation], timeout: Constants.expectationDuration)

    _ = try operation.extractResultData(throwing: BaseOperationError.unexpectedDependentResult)
}
