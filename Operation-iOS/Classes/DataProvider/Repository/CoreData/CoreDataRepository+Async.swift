import Foundation
import CoreData

extension CoreDataRepository {
    func fetch(by modelIdClosure: @escaping () throws -> String,
               options: RepositoryFetchOptions,
               runCompletionIn queue: DispatchQueue?,
               executing block: @escaping (Model?, Error?) -> Void) {
        databaseService.performRead({ [dataMapper, filter] context -> Model? in
            let entityName = String(describing: U.self)
            let fetchRequest = NSFetchRequest<U>(entityName: entityName)
            let modelId = try modelIdClosure()
            var predicate = NSPredicate(format: "%K == %@", dataMapper.entityIdentifierFieldName, modelId)

            if let filter {
                predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [filter, predicate])
            }

            fetchRequest.predicate = predicate
            fetchRequest.includesPropertyValues = options.includesProperties
            fetchRequest.includesSubentities = options.includesSubentities

            return try context.fetch(fetchRequest).first.map { try dataMapper.transform(entity: $0) }
        }, completion: { [weak self] result in
            self?.call(block: block, model: result.value ?? nil, error: result.failureError, queue: queue)
        })
    }

    func fetchAll(with options: RepositoryFetchOptions,
                  runCompletionIn queue: DispatchQueue?,
                  executing block: @escaping ([Model]?, Error?) -> Void) {
        databaseService.performRead({ [dataMapper, filter, sortDescriptors] context -> [Model] in
            let entityName = String(describing: U.self)
            let fetchRequest = NSFetchRequest<U>(entityName: entityName)
            fetchRequest.predicate = filter

            if !sortDescriptors.isEmpty {
                fetchRequest.sortDescriptors = sortDescriptors
            }

            fetchRequest.includesPropertyValues = options.includesProperties
            fetchRequest.includesSubentities = options.includesSubentities

            return try context.fetch(fetchRequest).map { try dataMapper.transform(entity: $0) }
        }, completion: { [weak self] result in
            self?.call(block: block, model: result.value, error: result.failureError, queue: queue)
        })
    }

    func fetch(request: RepositorySliceRequest,
               options: RepositoryFetchOptions,
               runCompletionIn queue: DispatchQueue?,
               executing block: @escaping ([Model]?, Error?) -> Void) {
        databaseService.performRead({ [dataMapper, filter, sortDescriptors] context -> [Model] in
            let entityName = String(describing: U.self)
            let fetchRequest = NSFetchRequest<U>(entityName: entityName)
            fetchRequest.predicate = filter
            fetchRequest.fetchOffset = request.offset
            fetchRequest.fetchLimit = request.count

            var effectiveSortDescriptors = sortDescriptors

            if request.reversed {
                effectiveSortDescriptors = effectiveSortDescriptors.compactMap {
                    $0.reversedSortDescriptor as? NSSortDescriptor
                }
            }

            if !effectiveSortDescriptors.isEmpty {
                fetchRequest.sortDescriptors = effectiveSortDescriptors
            }

            fetchRequest.includesPropertyValues = options.includesProperties
            fetchRequest.includesSubentities = options.includesSubentities

            return try context.fetch(fetchRequest).map { try dataMapper.transform(entity: $0) }
        }, completion: { [weak self] result in
            self?.call(block: block, model: result.value, error: result.failureError, queue: queue)
        })
    }

    func save(updating updatedModels: [Model], deleting deletedIds: [String],
              runCompletionIn queue: DispatchQueue?,
              executing block: @escaping (Error?) -> Void) {
        databaseService.performWrite({ context in
            try self.save(models: updatedModels, in: context)
            try self.delete(modelIds: deletedIds, in: context)
        }, completion: { result in
            self.call(block: block, error: result.failureError, queue: queue)
        })
    }

    func replace(with newModels: [Model],
                 runCompletionIn queue: DispatchQueue?,
                 executing block: @escaping (Error?) -> Void) {
        databaseService.performWrite({ context in
            try self.deleteAll(in: context)
            try self.create(models: newModels, in: context)
        }, completion: { result in
            self.call(block: block, error: result.failureError, queue: queue)
        })
    }

    func fetchCount(runCompletionIn queue: DispatchQueue?,
                    executing block: @escaping (Int?, Error?) -> Void) {
        databaseService.performRead({ [filter] context -> Int in
            let entityName = String(describing: U.self)
            let fetchRequest = NSFetchRequest<U>(entityName: entityName)
            fetchRequest.predicate = filter

            return try context.count(for: fetchRequest)
        }, completion: { [weak self] result in
            self?.call(block: block, model: result.value, error: result.failureError, queue: queue)
        })
    }

    func deleteAll(runCompletionIn queue: DispatchQueue?,
                   executing block: @escaping (Error?) -> Void) {
        databaseService.performWrite({ [weak self] context in
            try self?.deleteAll(in: context)
        }, completion: { [weak self] result in
            self?.call(block: block, error: result.failureError, queue: queue)
        })
    }
}

private extension Result {
    var value: Success? {
        if case .success(let value) = self {
            return value
        }

        return nil
    }

    var failureError: Error? {
        if case .failure(let error) = self {
            return error
        }

        return nil
    }
}
