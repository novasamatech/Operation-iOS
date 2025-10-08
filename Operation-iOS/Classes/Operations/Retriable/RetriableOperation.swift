import Foundation

public final class RetriableOperation<ResultType>: AsyncClosureOperation<ResultType>, @unchecked Sendable {
    public typealias OperationFactory = () -> CompoundOperationWrapper<ResultType>?
    public typealias RetryMatcher = (Error) -> Bool

    private let worker: Worker

    public init(
        factory: @escaping OperationFactory,
        retryMatcher: @escaping RetryMatcher,
        retryDelay: TimeInterval,
        retryCount: Int,
        operationQueue: OperationQueue,
        logger: LoggerProtocol?
    ) {
        let worker = Worker(
            factory: factory,
            retryMatcher: retryMatcher,
            retryDelay: retryDelay,
            retryCount: retryCount,
            operationQueue: operationQueue,
            logger: logger
        )
        self.worker = worker

        super.init(operationClosure: { [worker] completion in
            worker.completion = completion
            worker.execute()
        })
    }

    public override func cancel() {
        worker.cancel()
        super.cancel()
    }
}

private extension RetriableOperation {
    final class Worker {
        var completion: ((Result<ResultType, Error>) -> Void)?

        private let factory: OperationFactory
        private let retryMatcher: RetryMatcher
        private let retryDelay: TimeInterval
        private let retryCount: Int
        private let operationQueue: OperationQueue
        private let logger: LoggerProtocol?
        private let callStore = CancellableCallStore()

        private var currentRetryCount = 0
        private var scheduler: SchedulerProtocol?

        init(
            factory: @escaping OperationFactory,
            retryMatcher: @escaping RetryMatcher,
            retryDelay: TimeInterval,
            retryCount: Int,
            operationQueue: OperationQueue,
            logger: LoggerProtocol?
        ) {
            self.factory = factory
            self.retryMatcher = retryMatcher
            self.retryDelay = retryDelay
            self.retryCount = retryCount
            self.operationQueue = operationQueue
            self.logger = logger
        }

        deinit {
            cancelScheduler()
        }
    }
}

private extension RetriableOperation.Worker {
    enum OperationError: Error {
        case factoryReturnedNil
    }

    func execute() {
        guard completion != nil else {
            logger?.debug("Completion is nil")
            return
        }

        guard let wrapper = factory() else {
            logger?.debug("Factory returned nil")
            callCompletion(with: .failure(OperationError.factoryReturnedNil))
            return
        }

        logger?.debug("Executing")

        executeCancellable(
            wrapper: wrapper,
            inOperationQueue: operationQueue,
            backingCallIn: callStore,
            runningCallbackIn: .main
        ) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(value):
                logger?.debug("Calling completion with success")
                callCompletion(with: .success(value))
            case let .failure(error):
                logger?.error("Got error: \(error)")
                logger?.error("Error type: \(type(of: error))")
                logger?.debug("Current retry count: \(currentRetryCount)")

                if currentRetryCount < retryCount, retryMatcher(error) {
                    logger?.debug("Going to retry")
                    currentRetryCount += 1
                    scheduleRetry()
                } else {
                    logger?.debug("Calling completion with failure")
                    callCompletion(with: .failure(error))
                }
            }
        }
    }

    func scheduleRetry() {
        cancel()

        scheduler = Scheduler(with: self, callbackQueue: .main)
        scheduler?.notifyAfter(retryDelay)
    }

    func cancelScheduler() {
        scheduler?.cancel()
        scheduler = nil
    }

    func cancel() {
        callStore.cancel()
        cancelScheduler()
    }

    func callCompletion(with result: Result<ResultType, Error>) {
        completion?(result)
        completion = nil
    }
}

extension RetriableOperation.Worker: SchedulerDelegate {
    func didTrigger(scheduler _: SchedulerProtocol) {
        cancelScheduler()
        execute()
    }
}
