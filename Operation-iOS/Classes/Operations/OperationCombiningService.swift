import Foundation

public enum OperationCombiningServiceError: Error {
    case alreadyRunningOrFinished
    case noResult
}

public final class OperationCombiningService<T>: Longrunable, @unchecked Sendable {
    enum State {
        case waiting
        case running
        case finished
    }

    public typealias ResultType = [T]

    let operationsClosure: () throws -> [CompoundOperationWrapper<T>]
    let operationManager: OperationManagerProtocol
    let operationsPerBatch: Int

    private(set) var state: State = .waiting

    private var wrappers: [CompoundOperationWrapper<T>]?

    public init(
        operationManager: OperationManagerProtocol,
        operationsPerBatch: Int = 0,
        operationsClosure: @escaping () throws -> [CompoundOperationWrapper<T>]
    ) {
        self.operationManager = operationManager
        self.operationsClosure = operationsClosure
        self.operationsPerBatch = operationsPerBatch
    }

    public func start(with completionClosure: @escaping (Result<ResultType, Error>) -> Void) {
        guard state == .waiting else {
            completionClosure(.failure(OperationCombiningServiceError.alreadyRunningOrFinished))
            return
        }

        state = .waiting

        do {
            let wrappers = try operationsClosure()

            if operationsPerBatch > 0, wrappers.count > operationsPerBatch {
                for index in operationsPerBatch ..< wrappers.count {
                    let prevBatchIndex = index / operationsPerBatch - 1

                    let prevStart = prevBatchIndex * operationsPerBatch
                    let prevEnd = (prevBatchIndex + 1) * operationsPerBatch

                    for prevIndex in prevStart ..< prevEnd {
                        wrappers[index].addDependency(wrapper: wrappers[prevIndex])
                    }
                }
            }

            let mapOperation = ClosureOperation<ResultType> {
                try wrappers.map { try $0.targetOperation.extractNoCancellableResultData() }
            }

            // TODO: Need to fix Sendable, temporary solution
            nonisolated(unsafe) let completionClosure = completionClosure

            mapOperation.completionBlock = { [weak self] in
                self?.state = .finished
                self?.wrappers = nil

                let result = Result { try mapOperation.extractNoCancellableResultData() }
                completionClosure(result)
            }

            let dependencies = wrappers.flatMap(\.allOperations)
            dependencies.forEach { mapOperation.addDependency($0) }

            operationManager.enqueue(operations: dependencies + [mapOperation], in: .transient)

        } catch {
            completionClosure(.failure(error))
        }
    }

    public func cancel() {
        if state == .running {
            wrappers?.forEach { $0.cancel() }
            wrappers = nil
        }

        state = .finished
    }
}

extension OperationCombiningService {
    public func longrunOperation() -> LongrunOperation<[T]> {
        LongrunOperation(longrun: AnyLongrun(longrun: self))
    }

    public static func compoundWrapper(
        operationManager: OperationManagerProtocol,
        wrapperClosure: @escaping () throws -> CompoundOperationWrapper<T>?
    ) -> CompoundOperationWrapper<T?> {
        let loadingOperation: BaseOperation<[T]> = OperationCombiningService(operationManager: operationManager) {
            if let wrapper = try wrapperClosure() {
                [wrapper]
            } else {
                []
            }
        }.longrunOperation()

        let mappingOperation = ClosureOperation<T?> {
            try loadingOperation.extractNoCancellableResultData().first
        }

        mappingOperation.addDependency(loadingOperation)

        return .init(targetOperation: mappingOperation, dependencies: [loadingOperation])
    }

    public static func compoundOptionalWrapper(
        operationManager: OperationManagerProtocol,
        wrapperClosure: @escaping () throws -> CompoundOperationWrapper<T?>?
    ) -> CompoundOperationWrapper<T?> {
        let loadingOperation: BaseOperation<[T?]> = OperationCombiningService<T?>(operationManager: operationManager) {
            if let wrapper = try wrapperClosure() {
                [wrapper]
            } else {
                []
            }
        }.longrunOperation()

        let mappingOperation = ClosureOperation<T?> {
            let results = try loadingOperation.extractNoCancellableResultData()
            return results.first
        }

        mappingOperation.addDependency(loadingOperation)

        return .init(targetOperation: mappingOperation, dependencies: [loadingOperation])
    }

    public static func compoundNonOptionalWrapper(
        operationManager: OperationManagerProtocol,
        wrapperClosure: @escaping () throws -> CompoundOperationWrapper<T>
    ) -> CompoundOperationWrapper<T> {
        let loadingOperation: BaseOperation<[T]> = OperationCombiningService<T>(operationManager: operationManager) {
            let wrapper = try wrapperClosure()
            return [wrapper]
        }.longrunOperation()

        let mappingOperation = ClosureOperation<T> {
            guard let result = try loadingOperation.extractNoCancellableResultData().first else {
                throw OperationCombiningServiceError.noResult
            }

            return result
        }

        mappingOperation.addDependency(loadingOperation)

        return .init(targetOperation: mappingOperation, dependencies: [loadingOperation])
    }
}
