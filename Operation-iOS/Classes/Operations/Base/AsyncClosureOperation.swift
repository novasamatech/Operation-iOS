import Foundation

open class AsyncClosureOperation<ResultType>: BaseOperation<ResultType> {
    let operationClosure: (@escaping (Result<ResultType, Error>) -> Void) throws -> Void
    let cancelationClosure: (() -> Void)?

    public init(
        operationClosure: @escaping (@escaping (Result<ResultType, Error>) -> Void) throws -> Void,
        cancelationClosure: (() -> Void)? = nil
    ) {
        self.cancelationClosure = cancelationClosure
        self.operationClosure = operationClosure
    }
    
    open override func performAsync(_ callback: @escaping (Result<ResultType, Error>) -> Void) throws {
        try operationClosure(callback)
    }

    open override func cancel() {
        if isExecuting {
            cancelationClosure?()
        }
        
        super.cancel()
    }
}
