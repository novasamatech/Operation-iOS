import Foundation
@testable import Operation_iOS

/**
 *  Forwards every call to the wrapped repository and runs a hook once a fetch has read its result but
 *  before the operation reports completion — which is where a provider registers the observer that fetch
 *  belongs to. Committing a change from the hook lands it in that window deterministically, instead of
 *  racing for it.
 */
public final class HookedRepository<T: Identifiable>: DataProviderRepositoryProtocol {
    public typealias Model = T

    /// Runs after ```fetchAllOperation``` has read the snapshot, before it reports completion.
    public var afterFetchAll: (() -> Void)?

    /// Runs after ```fetchOperation(by:options:)``` has read the value, before it reports completion.
    public var afterFetchById: (() -> Void)?

    private let wrapped: AnyDataProviderRepository<T>
    private let innerQueue = OperationQueue()

    public init(wrapped: AnyDataProviderRepository<T>) {
        self.wrapped = wrapped
    }

    public func fetchOperation(by modelIdClosure: @escaping () throws -> String,
                               options: RepositoryFetchOptions) -> BaseOperation<Model?> {
        hooking(wrapped.fetchOperation(by: modelIdClosure, options: options)) { [weak self] in
            self?.afterFetchById?()
        }
    }

    public func fetchAllOperation(with options: RepositoryFetchOptions) -> BaseOperation<[Model]> {
        hooking(wrapped.fetchAllOperation(with: options)) { [weak self] in
            self?.afterFetchAll?()
        }
    }

    public func fetchOperation(by request: RepositorySliceRequest,
                               options: RepositoryFetchOptions) -> BaseOperation<[Model]> {
        wrapped.fetchOperation(by: request, options: options)
    }

    public func saveOperation(_ updateModelsBlock: @escaping () throws -> [Model],
                              _ deleteIdsBlock: @escaping () throws -> [String]) -> BaseOperation<Void> {
        wrapped.saveOperation(updateModelsBlock, deleteIdsBlock)
    }

    public func replaceOperation(_ newModelsBlock: @escaping () throws -> [Model]) -> BaseOperation<Void> {
        wrapped.replaceOperation(newModelsBlock)
    }

    public func fetchCountOperation() -> BaseOperation<Int> {
        wrapped.fetchCountOperation()
    }

    public func deleteAllOperation() -> BaseOperation<Void> {
        wrapped.deleteAllOperation()
    }
}

private extension HookedRepository {
    func hooking<R>(_ inner: BaseOperation<R>, with hook: @escaping () -> Void) -> BaseOperation<R> {
        AsyncClosureOperation { [innerQueue] completionClosure in
            inner.completionBlock = {
                let result = inner.result ?? .failure(BaseOperationError.parentOperationCancelled)

                hook()

                completionClosure(result)
            }

            innerQueue.addOperation(inner)
        }
    }
}
