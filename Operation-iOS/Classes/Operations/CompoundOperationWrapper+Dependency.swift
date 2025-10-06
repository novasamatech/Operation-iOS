import Foundation

extension CompoundOperationWrapper {
    public func addDependency(operations: [Operation]) {
        for nextOperation in allOperations {
            for prevOperation in operations {
                nextOperation.addDependency(prevOperation)
            }
        }
    }

    public func addDependency(wrapper: CompoundOperationWrapper<some Any>) {
        addDependency(operations: wrapper.allOperations)
    }

    public func insertingHead(operations: [Operation]) -> CompoundOperationWrapper {
        .init(targetOperation: targetOperation, dependencies: operations + dependencies)
    }

    public func insertingTail<T>(operation: BaseOperation<T>) -> CompoundOperationWrapper<T> {
        .init(targetOperation: operation, dependencies: allOperations)
    }
}

 extension CompoundOperationWrapper {
    public static func createWithError(_ error: Error) -> CompoundOperationWrapper<ResultType> {
        let operation = BaseOperation<ResultType>()
        operation.result = .failure(error)
        return CompoundOperationWrapper(targetOperation: operation)
    }

    public static func createWithResult(_ result: ResultType) -> CompoundOperationWrapper<ResultType> {
        let operation = BaseOperation<ResultType>()
        operation.result = .success(result)
        return CompoundOperationWrapper(targetOperation: operation)
    }
 }
