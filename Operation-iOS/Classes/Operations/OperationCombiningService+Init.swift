import Foundation

public extension OperationCombiningService {
    static func compoundNonOptionalWrapper(
        operationQueue: OperationQueue,
        wrapperClosure: @escaping () throws -> CompoundOperationWrapper<T>
    ) -> CompoundOperationWrapper<T> {
        compoundNonOptionalWrapper(
            operationManager: OperationManager(operationQueue: operationQueue),
            wrapperClosure: wrapperClosure
        )
    }
}
