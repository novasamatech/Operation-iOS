import Foundation
import CoreData

public final class StreamableProvider<T: Identifiable> {

    let source: AnyStreamableSource<T>
    let repository: AnyDataProviderRepository<T>
    let observable: AnyDataProviderRepositoryObservable<T>
    let operationManager: OperationManagerProtocol
    let processingQueue: DispatchQueue

    var observers: [DataProviderObserver<T, StreamableProviderObserverOptions>] = []
    var pendingObservers: [DataProviderPendingObserver<[T]>] = []

    /// Source changes buffered per pending observer. The provider starts observing the source before the
    /// snapshot fetch is enqueued, so a change committed while an observer is being added is held here
    /// rather than falling between the snapshot and that observer's registration.
    private var pendingChanges: [DataProviderPendingChanges<T>] = []
    private var isObservingSource: Bool = false

    public init(source: AnyStreamableSource<T>,
                repository: AnyDataProviderRepository<T>,
                observable: AnyDataProviderRepositoryObservable<T>,
                operationManager: OperationManagerProtocol,
                serialQueue: DispatchQueue? = nil) {
        self.source = source
        self.repository = repository
        self.observable = observable
        self.operationManager = operationManager

        if let currentProcessingQueue = serialQueue {
            self.processingQueue = currentProcessingQueue
        } else {
            self.processingQueue = DispatchQueue(
                label: "io.novasama.streamableprovider.repository.queue.\(UUID().uuidString)",
                qos: .utility)
        }
    }

    private func startObservingSourceIfNeeded() {
        guard !isObservingSource else {
            return
        }

        isObservingSource = true

        observable.addObserver(self, deliverOn: processingQueue) { [weak self] (changes) in
            self?.handleSourceChanges(changes)
        }
    }

    private func stopObservingSource() {
        guard isObservingSource else {
            return
        }

        isObservingSource = false

        observable.removeObserver(self)
    }

    /// Runs on ```processingQueue```, the same queue ```addObserver``` and ```completeAdd``` run on, so an
    /// observer is either still buffering or already registered when a change arrives — never neither.
    private func handleSourceChanges(_ changes: [DataProviderChange<Model>]) {
        pendingChanges = pendingChanges.filter { $0.observer != nil }

        pendingChanges.forEach { $0.changes.append(contentsOf: changes) }

        notifyObservers(with: changes)
    }

    private func fetchHistory(completionBlock: ((Result<Int, Error>?) -> Void)?) {
        source.fetchHistory(runningIn: processingQueue,
                            commitNotificationBlock: completionBlock)
    }

    private func notifyObservers(with changes: [DataProviderChange<Model>]) {
        observers.forEach { (observerWrapper) in
            if observerWrapper.observer != nil {
                dispatchInQueueWhenPossible(observerWrapper.queue) {
                    observerWrapper.updateBlock(changes)
                }
            }
        }
    }

    private func notifyObservers(with error: Error) {
        observers.forEach { (observerWrapper) in
            if observerWrapper.observer != nil, observerWrapper.options.alwaysNotifyOnRefresh {
                dispatchInQueueWhenPossible(observerWrapper.queue) {
                    observerWrapper.failureBlock(error)
                }
            }
        }
    }

    private func notifyObservers(with fetchResult: Result<Int, Error>) {
        observers.forEach { (observerWrapper) in
            if observerWrapper.observer != nil, observerWrapper.options.alwaysNotifyOnRefresh {
                switch fetchResult {
                case .success(let count):
                    if count == 0 {
                        dispatchInQueueWhenPossible(observerWrapper.queue) {
                            observerWrapper.updateBlock([])
                        }
                    }
                case .failure(let error):
                    dispatchInQueueWhenPossible(observerWrapper.queue) {
                        observerWrapper.failureBlock(error)
                    }
                }
            }
        }
    }

    private func isAlreadyAdded(observer: AnyObject) -> Bool {
        pendingObservers.contains(where: { $0.observer === observer}) ||
        observers.contains(where: { $0.observer === observer })
    }

    private func completeAdd(observer: AnyObject,
                             deliverOn queue: DispatchQueue,
                             executing updateBlock: @escaping ([DataProviderChange<Model>]) -> Void,
                             failing failureBlock: @escaping (Error) -> Void,
                             options: StreamableProviderObserverOptions) {
        guard
            let pending = pendingObservers.first(where: { $0.observer === observer }),
            let result = pending.operation?.result else {
            dispatchInQueueWhenPossible(queue) {
                failureBlock(DataProviderError.dependencyCancelled)
            }

            return
        }

        pendingObservers = self.pendingObservers
            .filter { $0.observer != nil && $0.observer !== observer}

        let buffered = takePendingChanges(for: observer)

        switch result {
        case .success(let items):
            self.observers = self.observers.filter { $0.observer != nil }

            let repositoryObserver = DataProviderObserver(observer: observer,
                                                          queue: queue,
                                                          updateBlock: updateBlock,
                                                          failureBlock: failureBlock,
                                                          options: options)
            self.observers.append(repositoryObserver)

            let updates = DataProviderChange.reconcile(snapshot: items, with: buffered)

            dispatchInQueueWhenPossible(queue) {
                updateBlock(updates)
            }

            if updates.isEmpty, options.refreshWhenEmpty {
                self.refresh()
            }

        case .failure(let error):
            stopObservingSourceIfUnused()

            dispatchInQueueWhenPossible(queue) {
                failureBlock(error)
            }
        }
    }

    private func takePendingChanges(for observer: AnyObject) -> [DataProviderChange<T>] {
        guard let index = pendingChanges.firstIndex(where: { $0.observer === observer }) else {
            return []
        }

        return pendingChanges.remove(at: index).changes
    }

    private func stopObservingSourceIfUnused() {
        guard observers.isEmpty, pendingObservers.isEmpty else {
            return
        }

        stopObservingSource()
    }
}

extension StreamableProvider: StreamableProviderProtocol {
    public typealias Model = T

    public func refresh() {
        source.refresh(runningIn: processingQueue) { [weak self] result in
            if let result = result {
                self?.notifyObservers(with: result)
            }
        }
    }

    public func fetch(offset: Int,
                      count: Int,
                      synchronized: Bool,
                      with completionBlock: @escaping (Result<[Model], Error>?) -> Void)
        -> CompoundOperationWrapper<[Model]> {
        let sliceRequest = RepositorySliceRequest(offset: offset, count: count, reversed: false)
        let operation = repository.fetchOperation(by: sliceRequest)

        operation.completionBlock = { [weak self] in
            if let result = operation.result,
                case .success(let models) = result,
                models.count < count {

                let completionBlock: (Result<Int, Error>?) -> Void = { (optionalResult) in
                    if let result = optionalResult {
                        self?.notifyObservers(with: result)
                    }
                }

                self?.fetchHistory(completionBlock: completionBlock)
            }

            completionBlock(operation.result)
        }

        if synchronized {
            operationManager.enqueue(operations: [operation], in: .sync)
        } else {
            operationManager.enqueue(operations: [operation], in: .transient)
        }

        return CompoundOperationWrapper(targetOperation: operation)
    }

    public func addObserver(_ observer: AnyObject,
                            deliverOn queue: DispatchQueue,
                            executing updateBlock: @escaping ([DataProviderChange<Model>]) -> Void,
                            failing failureBlock: @escaping (Error) -> Void,
                            options: StreamableProviderObserverOptions) {
        processingQueue.async {
            self.observers = self.observers.filter { $0.observer != nil }

            if self.isAlreadyAdded(observer: observer) {
                dispatchInQueueWhenPossible(queue) {
                    failureBlock(DataProviderError.observerAlreadyAdded)
                }

                return
            }

            let operation: BaseOperation<[Model]>

            if options.initialSize > 0 {
                let sliceRequest = RepositorySliceRequest(offset: 0, count: options.initialSize,
                                                          reversed: false)

                operation = self.repository.fetchOperation(by: sliceRequest)
            } else {
                operation = self.repository.fetchAllOperation()
            }

            let pending = DataProviderPendingObserver(observer: observer,
                                                      operation: operation)
            self.pendingObservers.append(pending)

            // Before the fetch is enqueued: a change committed after the snapshot is read must land in
            // this observer's buffer instead of in the gap between the snapshot and its registration.
            self.pendingChanges.append(DataProviderPendingChanges<T>(observer: observer))
            self.startObservingSourceIfNeeded()

            operation.completionBlock = {
                self.processingQueue.async {
                    self.completeAdd(observer: observer,
                                     deliverOn: queue,
                                     executing: updateBlock,
                                     failing: failureBlock,
                                     options: options)
                }
            }

            if options.waitsInProgressSyncOnAdd {
                self.operationManager.enqueue(operations: [operation], in: .sync)
            } else {
                self.operationManager.enqueue(operations: [operation], in: .transient)
            }
        }
    }

    public func removeObserver(_ observer: AnyObject) {
        processingQueue.async {

            if let pending = self.pendingObservers.first(where: { $0.observer === observer }) {
                pending.operation?.cancel()
            }

            self.pendingObservers = self.pendingObservers
                .filter { $0.observer != nil && $0.observer !== observer }

            self.pendingChanges = self.pendingChanges
                .filter { $0.observer != nil && $0.observer !== observer }

            self.observers = self.observers.filter { $0.observer != nil && $0.observer !== observer }

            self.stopObservingSourceIfUnused()
        }
    }
}
