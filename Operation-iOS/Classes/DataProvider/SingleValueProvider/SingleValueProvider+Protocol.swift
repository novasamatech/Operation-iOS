import Foundation

extension SingleValueProvider {
    func isAlreadyAdded(observer: AnyObject) -> Bool {
        pendingObservers.contains(where: { $0.observer === observer}) ||
        observers.contains(where: { $0.observer === observer })
    }

    func takePendingChanges(for observer: AnyObject) -> [DataProviderChange<T>] {
        guard let index = pendingChanges.firstIndex(where: { $0.observer === observer }) else {
            return []
        }

        return pendingChanges.remove(at: index).changes
    }

    private func completeAdd(observer: AnyObject,
                             operation: BaseOperation<SingleValueProviderObject?>,
                             deliverOn queue: DispatchQueue?,
                             executing updateBlock: @escaping ([DataProviderChange<Model>]) -> Void,
                             failing failureBlock: @escaping (Error) -> Void,
                             options: DataProviderObserverOptions) {
        // Keyed on the operation, not on the observer: cancelling a subscription finishes its snapshot
        // operation, so this can run for a subscription that has already been replaced by a newer one for
        // the same observer object. Releasing that newer subscription's entry and buffer here would leave
        // it unable to ever complete.
        guard
            let pending = pendingObservers.first(where: { $0.observer === observer }),
            pending.operation === operation
        else {
            dispatchInQueueWhenPossible(queue) {
                failureBlock(DataProviderError.dependencyCancelled)
            }

            return
        }

        // Released before the snapshot is inspected: a buffer left behind by a cancelled snapshot would
        // never be drained and would keep growing with every later synchronization.
        pendingObservers = pendingObservers.filter { $0.observer != nil && $0.observer !== observer }

        let buffered = takePendingChanges(for: observer)

        guard let result = operation.result else {
            dispatchInQueueWhenPossible(queue) {
                failureBlock(DataProviderError.dependencyCancelled)
            }

            return
        }

        switch result {
        case .success(let optionalEntity):
            let repositoryObserver = DataProviderObserver(observer: observer,
                                                          queue: queue,
                                                          updateBlock: updateBlock,
                                                          failureBlock: failureBlock,
                                                          options: options)
            self.observers.append(repositoryObserver)

            self.updateTrigger.receive(event: .addObserver(observer))

            let snapshot = optionalEntity.flatMap {
                try? self.decoder.decode(T.self, from: $0.payload)
            }

            let updates = DataProviderChange.reconcile(snapshot: snapshot, with: buffered)

            dispatchInQueueWhenPossible(queue) {
                updateBlock(updates)
            }
        case .failure(let error):
            dispatchInQueueWhenPossible(queue) {
                failureBlock(error)
            }
        }
    }
}

extension SingleValueProvider: SingleValueProviderProtocol {
    public func fetch(with completionBlock: ((Result<T?, Error>?) -> Void)?) -> CompoundOperationWrapper<T?> {
        let repositoryOperation = repository.fetchOperation(by: targetIdentifier)

        let sourceWrapper = source.fetchOperation()

        let sourceCancellationOperation = ClosureOperation<T?> {
            if
                let optionalEntity = try repositoryOperation.extractResultData(),
                let entity = optionalEntity,
                let model = try? self.decoder.decode(T.self, from: entity.payload) {
                sourceWrapper.cancel()
                return model
            } else {
                return nil
            }
        }

        sourceCancellationOperation.addDependency(repositoryOperation)

        sourceWrapper.allOperations.forEach {
            $0.addDependency(sourceCancellationOperation)
        }

        let reduceOperation = ClosureOperation<T?> {
            if let optionalModel = try sourceCancellationOperation.extractResultData(), let result = optionalModel {
                return result
            }

            if let optionalModel = try sourceWrapper.targetOperation.extractResultData(), let result = optionalModel {
                return result
            }

            throw BaseOperationError.parentOperationCancelled
        }

        reduceOperation.addDependency(sourceWrapper.targetOperation)

        reduceOperation.completionBlock = {
            completionBlock?(reduceOperation.result)
        }

        let dependencies = [repositoryOperation, sourceCancellationOperation] + sourceWrapper.allOperations

        let wrapper = CompoundOperationWrapper(targetOperation: reduceOperation,
                                               dependencies: dependencies)

        executionQueue.addOperations(wrapper.allOperations, waitUntilFinished: false)

        updateTrigger.receive(event: .fetchById(targetIdentifier))

        return wrapper
    }

    public func addObserver(_ observer: AnyObject,
                            deliverOn queue: DispatchQueue?,
                            executing updateBlock: @escaping ([DataProviderChange<Model>]) -> Void,
                            failing failureBlock: @escaping (Error) -> Void,
                            options: DataProviderObserverOptions) {
        syncQueue.async {
            self.observers = self.observers.filter { $0.observer != nil }

            if self.isAlreadyAdded(observer: observer) {
                dispatchInQueueWhenPossible(queue) {
                    failureBlock(DataProviderError.observerAlreadyAdded)
                }
                return
            }

            let repositoryOperation = self.repository.fetchOperation(by: self.targetIdentifier)

            let pending = DataProviderPendingObserver(observer: observer,
                                                      operation: repositoryOperation)
            self.pendingObservers.append(pending)

            // Before the snapshot is enqueued: a sync that commits after it is read must land in this
            // observer's buffer instead of in the gap between the snapshot and its registration.
            self.pendingChanges.append(DataProviderPendingChanges<T>(observer: observer))

            repositoryOperation.completionBlock = {
                self.syncQueue.async {
                    self.completeAdd(observer: observer,
                                     operation: repositoryOperation,
                                     deliverOn: queue,
                                     executing: updateBlock,
                                     failing: failureBlock,
                                     options: options)
                }
            }

            if options.waitsInProgressSyncOnAdd {
                if let syncOperation = self.lastSyncOperation, !syncOperation.isFinished {
                    repositoryOperation.addDependency(syncOperation)
                }

                self.lastSyncOperation = repositoryOperation
            }

            self.executionQueue.addOperations([repositoryOperation], waitUntilFinished: false)
        }
    }

    public func removeObserver(_ observer: AnyObject) {
        syncQueue.async {
            if let pending = self.pendingObservers.first(where: { $0.observer === observer }) {
                pending.operation?.cancel()
            }

            self.pendingObservers = self.pendingObservers
                .filter { $0.observer != nil && $0.observer !== observer }

            self.pendingChanges = self.pendingChanges
                .filter { $0.observer != nil && $0.observer !== observer }

            self.observers = self.observers.filter { $0.observer !== observer && $0.observer != nil}

            self.updateTrigger.receive(event: .removeObserver(observer))
        }
    }

    public func refresh() {
        dispatchUpdateRepository()
    }
}
