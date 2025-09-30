import Foundation

public final class CancellableCallStore {
    private var cancellableCall: CancellableCall?
    
    public init() {}

    public var hasCall: Bool {
        cancellableCall != nil
    }

    public func cancel() {
        let copy = cancellableCall
        cancellableCall = nil
        copy?.cancel()
    }

    func store(call: CancellableCall) {
        cancellableCall = call
    }

    func clear() {
        cancellableCall = nil
    }
    
    func clearIfMatches(call: CancellableCall) -> Bool {
        guard matches(call: call) else {
            return false
        }

        cancellableCall = nil

        return true
    }

    func matches(call: CancellableCall) -> Bool {
        cancellableCall === call
    }
}

public func execute<T>(
    wrapper: CompoundOperationWrapper<T>,
    inOperationQueue operationQueue: OperationQueue,
    runningCallbackIn callbackQueue: DispatchQueue?,
    callbackClosure: @escaping (Result<T, Error>) -> Void
) {
    wrapper.targetOperation.completionBlock = {
        dispatchInQueueWhenPossible(callbackQueue) {
            do {
                let value = try wrapper.targetOperation.extractNoCancellableResultData()
                callbackClosure(.success(value))
            } catch {
                callbackClosure(.failure(error))
            }
        }
    }

    operationQueue.addOperations(wrapper.allOperations, waitUntilFinished: false)
}

public func executeCancellable<T>(
    wrapper: CompoundOperationWrapper<T>,
    inOperationQueue operationQueue: OperationQueue,
    backingCallIn callStore: CancellableCallStore,
    runningCallbackIn callbackQueue: DispatchQueue?,
    mutex: NSLock? = nil,
    callbackClosure: @escaping (Result<T, Error>) -> Void
) {
    wrapper.targetOperation.completionBlock = {
        dispatchInQueueWhenPossible(callbackQueue, locking: mutex) {
            guard callStore.clearIfMatches(call: wrapper) else {
                return
            }

            do {
                let value = try wrapper.targetOperation.extractNoCancellableResultData()
                callbackClosure(.success(value))
            } catch {
                callbackClosure(.failure(error))
            }
        }
    }

    callStore.store(call: wrapper)

    operationQueue.addOperations(wrapper.allOperations, waitUntilFinished: false)
}

public func execute<T>(
    operation: BaseOperation<T>,
    inOperationQueue operationQueue: OperationQueue,
    runningCallbackIn callbackQueue: DispatchQueue?,
    callbackClosure: @escaping (Result<T, Error>) -> Void
) {
    operation.completionBlock = {
        dispatchInQueueWhenPossible(callbackQueue) {
            do {
                let value = try operation.extractNoCancellableResultData()
                callbackClosure(.success(value))
            } catch {
                callbackClosure(.failure(error))
            }
        }
    }

    operationQueue.addOperations([operation], waitUntilFinished: false)
}

public func execute<T>(
    operation: BaseOperation<T>,
    inOperationQueue operationQueue: OperationQueue,
    backingCallIn callStore: CancellableCallStore,
    runningCallbackIn callbackQueue: DispatchQueue?,
    callbackClosure: @escaping (Result<T, Error>) -> Void
) {
    operation.completionBlock = {
        dispatchInQueueWhenPossible(callbackQueue) {
            guard callStore.clearIfMatches(call: operation) else {
                return
            }

            do {
                let value = try operation.extractNoCancellableResultData()
                callbackClosure(.success(value))
            } catch {
                callbackClosure(.failure(error))
            }
        }
    }

    callStore.store(call: operation)

    operationQueue.addOperations([operation], waitUntilFinished: false)
}
