import Foundation

extension CoreDataRepository: DataProviderRepositoryProtocol {
    public func fetchOperation(by modelIdClosure: @escaping () throws -> String,
                               options: RepositoryFetchOptions) -> BaseOperation<Model?> {
        AsyncClosureOperation { completionClosure in
            self.fetch(
                by: modelIdClosure,
                options: options,
                runCompletionIn: nil
            ) { (optionalModel, optionalError) in
                if let model = optionalModel {
                    completionClosure(.success(model))
                } else if let error = optionalError {
                    completionClosure(.failure(error))
                } else {
                    completionClosure(.success(nil))
                }
            }
        }
    }

    public func fetchAllOperation(with options: RepositoryFetchOptions) -> BaseOperation<[Model]> {
        AsyncClosureOperation { completionClosure in
            self.fetchAll(
                with: options,
                runCompletionIn: nil
            ) { (optionalModels, optionalError) in
                if let models = optionalModels {
                    completionClosure(.success(models))
                } else {
                    let error = optionalError ?? CoreDataRepositoryError.undefined
                    completionClosure(.failure(error))
                }
            }
        }
    }

    public func fetchOperation(
        by request: RepositorySliceRequest,
        options: RepositoryFetchOptions
    ) -> BaseOperation<[Model]> {
        AsyncClosureOperation { completionClosure in
            self.fetch(
                request: request,
                options: options,
                runCompletionIn: nil
            ) { (optionalModels, optionalError) in
                if let models = optionalModels {
                    completionClosure(.success(models))
                } else {
                    let error = optionalError ?? CoreDataRepositoryError.undefined
                    completionClosure(.failure(error))
                }
            }
        }
    }

    public func saveOperation(
        _ updateModelsBlock: @escaping () throws -> [Model],
        _ deleteIdsBlock: @escaping () throws -> [String]
    ) -> BaseOperation<Void> {
        AsyncClosureOperation { completionClosure in
            let updatedModels = try updateModelsBlock()
            let deletedIds = try deleteIdsBlock()

            if updatedModels.count == 0, deletedIds.count == 0 {
                completionClosure(.success(()))
                return
            }
            
            self.save(
                updating: updatedModels,
                deleting: deletedIds,
                runCompletionIn: nil
            ) { (optionalError) in
                if let error = optionalError {
                    completionClosure(.failure(error))
                } else {
                    completionClosure(.success(()))
                }
            }
        }
    }

    public func replaceOperation(_ newModelsBlock: @escaping () throws -> [Model]) -> BaseOperation<Void> {
        AsyncClosureOperation { completionClosure in
            let models = try newModelsBlock()
            
            self.replace(with: models, runCompletionIn: nil) { optionalError in
                if let error = optionalError {
                    completionClosure(.failure(error))
                } else {
                    completionClosure(.success(()))
                }
            }
        }
    }

    public func fetchCountOperation() -> BaseOperation<Int> {
        AsyncClosureOperation { completionClosure in
            self.fetchCount(runCompletionIn: nil) { (optionalCount, optionalError) in
                if let count = optionalCount {
                    completionClosure(.success(count))
                } else {
                    let error = optionalError ?? CoreDataRepositoryError.undefined
                    completionClosure(.failure(error))
                }
            }
        }
    }

    public func deleteAllOperation() -> BaseOperation<Void> {
        AsyncClosureOperation { completionClosure in
            self.deleteAll(runCompletionIn: nil) { (optionalError) in
                if let error = optionalError {
                    completionClosure(.failure(error))
                } else {
                    completionClosure(.success(()))
                }
            }
        }
    }
}
