import XCTest
@testable import Operation_iOS

final class OperationExecution: XCTestCase {

    func testFinishOperationWhenCancelled() {
        let operation = AsyncClosureOperation<Void> { completion in
            // operation never completes
        }
        
        let operationQueue = OperationQueue()
        
        let expectation = XCTestExpectation()
        
        operation.completionBlock = {
            expectation.fulfill()
        }
        
        operationQueue.addOperation(operation)
        
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
            operation.cancel()
        }
        
        wait(for: [expectation], timeout: 10)
    }
    
    func testExecutingCancelledOperation() {
        let operation1 = ClosureOperation<Void> {}
        
        let operation2 = ClosureOperation<Void> {
            operation1.cancel()
        }
        
        operation1.addDependency(operation2)
        
        let operationQueue = OperationQueue()
        
        let expectation = XCTestExpectation()
        
        operation1.completionBlock = {
            expectation.fulfill()
        }
        
        operationQueue.addOperations([operation2, operation1], waitUntilFinished: false)
        
        wait(for: [expectation], timeout: 10)
    }
}
