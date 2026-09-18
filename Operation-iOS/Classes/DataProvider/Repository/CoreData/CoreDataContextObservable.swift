import Foundation
import CoreData

/**
 *  Class is designed to provide implementation for ```DataProviderRepositoryObservable``` and allows
 *  observation of Core Data based repositories through NSManagedObjectContext notifications.
 *
 *  Changes are delivered as a list of ```DataProviderChange``` values to every subscribed observer.
 *  Changes can be filtered by providing predicate closure during initialization.
 *
 *  The writer's ```NSManagedObjectContextDidSave``` payload is reduced to object identifiers on the
 *  writer's queue; resolving, filtering and mapping happen on the service's observer context, so the
 *  save never waits for mapping. Payloads carrying ```NSManagedObjectID``` values (persistent history
 *  re-posts from other processes) take the same path as live objects.
 */

final public class CoreDataContextObservable<T: Identifiable, U: NSManagedObject> {
    private(set) var service: CoreDataServiceProtocol
    private(set) var mapper: AnyCoreDataMapper<T, U>
    private(set) var processingQueue: DispatchQueue
    private(set) var predicate: (U) -> Bool

    private var observers: [RepositoryObserver<T>] = []

    /**
     *  Creates Core Data context observable object.
     *
     *  - parameters:
     *    - service: Core Data service which manages persistent store and contexts.
     *    - mapper: Mapper which maps swift model to NSManagedObjects.
     *    - predicate: Closure to filter changes that are deliviered to observers.
     *    - processingQueue: Serial queue for internal synchronization needs. By
     *    default parameter is ```nil``` which mean that new queue is created internally
     *    but the client can pass shared queue for optimization reasons.
     */

    public init(
        service: CoreDataServiceProtocol,
        mapper: AnyCoreDataMapper<T, U>,
        predicate: @escaping (U) -> Bool,
        processingQueue: DispatchQueue? = nil
    ) {
        self.service = service
        self.mapper = mapper
        self.predicate = predicate

        if let processingQueue = processingQueue {
            self.processingQueue = processingQueue
        } else {
            self.processingQueue = DispatchQueue(
                label: "io.novasama.streamableobservable.queue.\(UUID().uuidString)",
                qos: .utility)
        }
    }

    @objc private func didReceive(notification: Notification) {
        let pending = PendingChanges(userInfo: notification.userInfo, identifierKey: mapper.entityIdentifierFieldName) {
            ($0 as? U).map(predicate) ?? false
        }

        guard !pending.isEmpty else {
            return
        }

        service.performObserve { [weak self] context, _ in
            guard let self, let context else {
                return
            }

            let changes = self.resolve(pending, in: context)

            guard !changes.isEmpty else {
                return
            }

            self.deliver(changes)
        }
    }
}

// MARK: - Change resolution

private extension CoreDataContextObservable {
    /// What the writer's notification carried, reduced to values that are safe to hand to another queue.
    struct PendingChanges {
        var insertedIds: [NSManagedObjectID] = []
        var updatedIds: [NSManagedObjectID] = []
        var deletedIds: [NSManagedObjectID] = []
        var deletedIdentifiers: [String] = []

        var isEmpty: Bool {
            insertedIds.isEmpty && updatedIds.isEmpty && deletedIds.isEmpty && deletedIdentifiers.isEmpty
        }

        /// Live-object saves populate the ```...ObjectsKey``` entries; persistent-history re-posts
        /// (```NSPersistentHistoryTransaction.objectIDNotification()```) populate ```...ObjectIDsKey```.
        init(userInfo: [AnyHashable: Any]?, identifierKey: String, matches: (NSManagedObject) -> Bool) {
            insertedIds = Self.objectIDs(in: userInfo, keys: [NSInsertedObjectsKey, NSInsertedObjectIDsKey])
            updatedIds = Self.objectIDs(in: userInfo, keys: [NSUpdatedObjectsKey, NSUpdatedObjectIDsKey])

            for element in Self.elements(in: userInfo, keys: [NSDeletedObjectsKey, NSDeletedObjectIDsKey]) {
                if let object = element as? NSManagedObject {
                    // The row is gone once this notification returns; read the identifier now.
                    if matches(object), let identifier = object.value(forKey: identifierKey) as? String {
                        deletedIdentifiers.append(identifier)
                    }
                } else if let objectID = element as? NSManagedObjectID {
                    deletedIds.append(objectID)
                }
            }
        }

        private static func elements(in userInfo: [AnyHashable: Any]?, keys: [String]) -> [Any] {
            keys.flatMap { (userInfo?[$0] as? NSSet)?.allObjects ?? [] }
        }

        private static func objectIDs(in userInfo: [AnyHashable: Any]?, keys: [String]) -> [NSManagedObjectID] {
            elements(in: userInfo, keys: keys).compactMap { element in
                (element as? NSManagedObject)?.objectID ?? element as? NSManagedObjectID
            }
        }
    }

    func resolve(_ pending: PendingChanges, in context: NSManagedObjectContext) -> [DataProviderChange<T>] {
        var changes: [DataProviderChange<T>] = []

        changes += pending.updatedIds
            .compactMap { resolveEntity(for: $0, in: context) }
            .compactMap { try? mapper.transform(entity: $0) }
            .map { DataProviderChange.update(newItem: $0) }

        changes += pending.deletedIdentifiers
            .map { DataProviderChange.delete(deletedIdentifier: $0) }

        changes += pending.deletedIds
            .compactMap { context.registeredObject(for: $0) as? U }
            .filter(predicate)
            .compactMap { $0.value(forKey: mapper.entityIdentifierFieldName) as? String }
            .map { DataProviderChange.delete(deletedIdentifier: $0) }

        changes += pending.insertedIds
            .compactMap { resolveEntity(for: $0, in: context) }
            .compactMap { try? mapper.transform(entity: $0) }
            .map { DataProviderChange.insert(newItem: $0) }

        return changes
    }

    /// Materialises the committed row for ```objectID``` on the observer context. A stale registered
    /// object is re-faulted first, so mapping never reads values the merge has not reached yet.
    func resolveEntity(for objectID: NSManagedObjectID, in context: NSManagedObjectContext) -> U? {
        guard let entity = context.object(with: objectID) as? U else {
            return nil
        }

        context.refresh(entity, mergeChanges: false)

        guard predicate(entity) else {
            return nil
        }

        return entity
    }

    func deliver(_ changes: [DataProviderChange<T>]) {
        processingQueue.async {
            for observerWrapper in self.observers {
                guard observerWrapper.observer != nil else {
                    continue
                }

                if self.processingQueue == observerWrapper.queue {
                    observerWrapper.updateBlock(changes)
                } else {
                    observerWrapper.queue.async {
                        observerWrapper.updateBlock(changes)
                    }
                }
            }
        }
    }
}

// MARK: - DataProviderRepositoryObservable

extension CoreDataContextObservable: DataProviderRepositoryObservable {
    public typealias Model = T

    public func start(completionBlock: @escaping (Error?) -> Void) {
        service.performAsync { [weak self] (optionalContext, optionalError) in
            guard let self else {
                completionBlock(nil)
                return
            }

            if let context = optionalContext {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(didReceive(notification:)),
                    name: Notification.Name.NSManagedObjectContextDidSave,
                    object: context
                )
            }

            completionBlock(optionalError)
        }
    }

    public func stop(completionBlock: @escaping (Error?) -> Void) {
        service.performAsync { [weak self] (optionalContext, optionalError) in
            guard let self else {
                completionBlock(nil)
                return
            }

            if let context = optionalContext {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.NSManagedObjectContextDidSave,
                    object: context
                )
            }

            completionBlock(optionalError)
        }
    }

    public func addObserver(_ observer: AnyObject,
                            deliverOn queue: DispatchQueue,
                            executing updateBlock: @escaping ([DataProviderChange<Model>]) -> Void) {
        processingQueue.async {
            self.observers = self.observers.filter { $0.observer != nil }

            if !self.observers.contains(where: { $0.observer === observer }) {
                let newObserver = RepositoryObserver(observer: observer, queue: queue, updateBlock: updateBlock)
                self.observers.append(newObserver)
            }
        }
    }

    public func removeObserver(_ observer: AnyObject) {
        processingQueue.async {
            self.observers = self.observers.filter { $0.observer != nil && $0.observer !== observer }
        }
    }
}
