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
 *  writer's queue. In ```.concurrent``` mode resolving, filtering and mapping then happen on the service's
 *  separate observer context, so the save never waits for mapping; because that hop is asynchronous, each
 *  change is derived from the row's committed state at resolve time (see ```resolve```), not from the
 *  category the notification filed it under. In ```.serial``` mode the observer *is* the writer, so that
 *  hop would only defer the work past later mutations on the same context: resolution runs inline inside
 *  the save instead, where the committed state is exactly what the context holds.
 *
 *  Payloads carrying ```NSManagedObjectID``` values (persistent history re-posts from other processes)
 *  take the same path for inserts and updates; remote deletes are delivered from the tombstones
 *  ```CoreDataHistoryObserver``` forwards, which requires ```preserveAfterDeletion``` on the identifier
 *  attribute of the entity.
 */

final public class CoreDataContextObservable<T: Identifiable, U: NSManagedObject> {
    private(set) var service: CoreDataServiceProtocol
    private(set) var mapper: AnyCoreDataMapper<T, U>
    private(set) var processingQueue: DispatchQueue
    private(set) var predicate: (U) -> Bool

    private var observers: [RepositoryObserver<T>] = []

    /// Captured on ```start``` and only touched on the writer's queue, where did-save notifications arrive.
    /// Resolving directly on it keeps notification handling off the service lock, so a ```close()``` that is
    /// draining the writer can never be re-entered from the writer.
    private var observerContext: NSManagedObjectContext?

    private var entityName: String { String(describing: U.self) }

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
        let pending = PendingChanges(
            userInfo: notification.userInfo,
            entityName: entityName,
            identifierKey: mapper.entityIdentifierFieldName
        ) { ($0 as? U).map(predicate) ?? false }

        guard !pending.isEmpty else {
            return
        }

        guard let observerContext else {
            return
        }

        schedule(pending, from: notification.object as? NSManagedObjectContext, on: observerContext)
    }

    /// Runs on the writer's queue. Resolves ```pending``` against the observer context.
    private func schedule(_ pending: PendingChanges, from source: NSManagedObjectContext?, on observerContext: NSManagedObjectContext) {
        // The writer's registered objects are the source of truth; refreshing them would discard changes a
        // legacy block still intends to save. Any other observer context is re-faulted to the store.
        let refreshes = observerContext !== source

        guard refreshes else {
            // ```.serial```: the observer *is* the writer and this runs inside the save that posted the
            // notification, where the context holds exactly what was just committed. Resolving here keeps
            // the delivered state committed — hopping would defer it past mutations a legacy block makes
            // after its ```save()```. It also queues the delivery before the write's completion runs, so a
            // completion that unsubscribes cannot drop the change it is reacting to.
            resolveAndDeliver(pending, in: observerContext, refreshing: false)
            return
        }

        observerContext.perform { [weak self] in
            self?.resolveAndDeliver(pending, in: observerContext, refreshing: true)
        }
    }

    private func resolveAndDeliver(_ pending: PendingChanges, in context: NSManagedObjectContext, refreshing: Bool) {
        let changes = resolve(pending, in: context, refreshing: refreshing)

        guard !changes.isEmpty else {
            return
        }

        deliver(changes)
    }
}

// MARK: - Change resolution

private extension CoreDataContextObservable {
    /// What the writer's notification carried, reduced to values that are safe to hand to another queue.
    struct PendingChanges {
        var insertedIds: [NSManagedObjectID] = []
        var updatedIds: [NSManagedObjectID] = []
        var deletedIdentifiers: [String] = []

        var isEmpty: Bool {
            insertedIds.isEmpty && updatedIds.isEmpty && deletedIdentifiers.isEmpty
        }

        /// Live-object saves populate the ```...ObjectsKey``` entries; persistent-history re-posts
        /// (```NSPersistentHistoryTransaction.objectIDNotification()```) populate ```...ObjectIDsKey``` and,
        /// for deletes, the tombstones ```CoreDataHistoryObserver``` attaches. Only the observed entity is kept,
        /// so nothing else is carried to the observer context.
        init(
            userInfo: [AnyHashable: Any]?,
            entityName: String,
            identifierKey: String,
            matches: (NSManagedObject) -> Bool
        ) {
            insertedIds = Self.objectIDs(in: userInfo, entityName: entityName, keys: [NSInsertedObjectsKey, NSInsertedObjectIDsKey])
            updatedIds = Self.objectIDs(in: userInfo, entityName: entityName, keys: [NSUpdatedObjectsKey, NSUpdatedObjectIDsKey])

            for case let object as NSManagedObject in Self.elements(in: userInfo, keys: [NSDeletedObjectsKey]) {
                // The row is gone once this notification returns; read the identifier now.
                if matches(object), let identifier = object.value(forKey: identifierKey) as? String {
                    deletedIdentifiers.append(identifier)
                }
            }

            let tombstones = userInfo?[CoreDataHistoryObserver.tombstonesKey] as? [CoreDataHistoryTombstone] ?? []

            for tombstone in tombstones where tombstone.objectID.entity.name == entityName {
                // A remote row cannot be filtered by the predicate any more; the identifier is all that survives.
                if let identifier = tombstone.values[identifierKey] as? String {
                    deletedIdentifiers.append(identifier)
                }
            }
        }

        private static func elements(in userInfo: [AnyHashable: Any]?, keys: [String]) -> [Any] {
            keys.flatMap { (userInfo?[$0] as? NSSet)?.allObjects ?? [] }
        }

        private static func objectIDs(
            in userInfo: [AnyHashable: Any]?,
            entityName: String,
            keys: [String]
        ) -> [NSManagedObjectID] {
            elements(in: userInfo, keys: keys)
                .compactMap { element in
                    (element as? NSManagedObject)?.objectID ?? element as? NSManagedObjectID
                }
                .filter { $0.entity.name == entityName }
        }
    }

    /// Derives every change from the row's committed state at resolve time, not from the category the
    /// notification filed it under: the hop to the observer context is asynchronous, so later commits may
    /// already have changed the row. A row that matches is an insert or update. An updated row that no
    /// longer matches has left the subscriber's set and becomes a delete; an inserted one never entered it,
    /// so it is skipped. A row that is gone is skipped too, because the save that removed it carries the
    /// identifier itself.
    func resolve(
        _ pending: PendingChanges,
        in context: NSManagedObjectContext,
        refreshing: Bool
    ) -> [DataProviderChange<T>] {
        let entities = materialize(pending.updatedIds + pending.insertedIds, in: context, refreshing: refreshing)

        var changes: [DataProviderChange<T>] = []

        changes += pending.updatedIds
            .compactMap { entities[$0] }
            .compactMap { change(for: $0, inserted: false) }

        changes += pending.deletedIdentifiers
            .map { DataProviderChange.delete(deletedIdentifier: $0) }

        changes += pending.insertedIds
            .compactMap { entities[$0] }
            .compactMap { change(for: $0, inserted: true) }

        return changes
    }

    func change(for entity: U, inserted: Bool) -> DataProviderChange<T>? {
        if predicate(entity) {
            guard let model = try? mapper.transform(entity: entity) else {
                return nil
            }

            return inserted ? .insert(newItem: model) : .update(newItem: model)
        }

        guard !inserted, let identifier = entity.value(forKey: mapper.entityIdentifierFieldName) as? String else {
            return nil
        }

        return .delete(deletedIdentifier: identifier)
    }

    /// Materialises the committed rows for ```objectIDs``` with one fetch; rows that are gone are absent from
    /// the result. When ```refreshing```, the fetch bypasses the coordinator's row cache and overwrites what
    /// the context last saw, so values come from the store as it is now. The writer skips that: its registered
    /// objects are the source of truth and may hold changes a legacy block still intends to save.
    func materialize(
        _ objectIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        refreshing: Bool
    ) -> [NSManagedObjectID: U] {
        guard !objectIDs.isEmpty else {
            return [:]
        }

        let request = NSFetchRequest<U>(entityName: entityName)
        request.predicate = NSPredicate(format: "SELF IN %@", objectIDs)
        request.returnsObjectsAsFaults = false
        request.shouldRefreshRefetchedObjects = refreshing

        let stalenessInterval = context.stalenessInterval

        if refreshing {
            context.stalenessInterval = 0
        }

        defer {
            context.stalenessInterval = stalenessInterval
        }

        let fetched = (try? context.fetch(request)) ?? []

        return Dictionary(fetched.map { ($0.objectID, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// One hop on the writer's queue: registers for its saves and captures the observer context, so a save
    /// issued right after ```start``` is observed and no second service call can race a ```close()```.
    public func start(completionBlock: @escaping (Error?) -> Void) {
        service.performWithObserver { [weak self] writer, observer, error in
            guard let self else {
                completionBlock(nil)
                return
            }

            guard let writer, let observer else {
                completionBlock(error)
                return
            }

            self.observerContext = observer

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didReceive(notification:)),
                name: Notification.Name.NSManagedObjectContextDidSave,
                object: writer
            )

            completionBlock(nil)
        }
    }

    public func stop(completionBlock: @escaping (Error?) -> Void) {
        service.performAsync { [weak self] (optionalContext, optionalError) in
            guard let self else {
                completionBlock(nil)
                return
            }

            if let context = optionalContext {
                self.observerContext = nil

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
