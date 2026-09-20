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

            for tombstone in tombstones where Self.isObserved(tombstone.objectID.entity, named: entityName) {
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
                .filter { Self.isObserved($0.entity, named: entityName) }
        }

        /// A sub-entity's rows belong to the observed entity as well: they inherit its attributes, a fetch
        /// of the parent returns them, and their instances are of the parent's class — but ```entity.name```
        /// is always their own, so comparing names drops them. The live-delete path casts the object instead,
        /// which follows class inheritance for free; an ```NSManagedObjectID``` carries no object to cast, so
        /// the entity hierarchy is walked here to reach the same answer.
        private static func isObserved(_ entity: NSEntityDescription, named entityName: String) -> Bool {
            var current: NSEntityDescription? = entity

            while let candidate = current {
                if candidate.name == entityName {
                    return true
                }

                current = candidate.superentity
            }

            return false
        }
    }

    /// Derives every change from the row's committed state at resolve time, not from the category the
    /// notification filed it under: in ```.concurrent``` mode the hop to the observer context is
    /// asynchronous, so later commits may already have changed the row.
    ///
    /// A row that matches the predicate is an insert or update. A row that does not is skipped: the payload
    /// is filtered by entity alone and the predicate only ever sees the post-change object, so there is no
    /// way to tell a row that left the subscriber's set from one that was never in it. Reporting a delete
    /// for both would fire at every observable that shares the entity on every save. A row that is gone is
    /// skipped too, because the save that removed it carries the identifier itself.
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
        guard predicate(entity), let model = try? mapper.transform(entity: entity) else {
            return nil
        }

        return inserted ? .insert(newItem: model) : .update(newItem: model)
    }

    /// Materialises the committed rows for ```objectIDs```; rows that are gone are absent from the result.
    ///
    /// When ```refreshing```, the context is not the one that saved, so every row is re-fetched with the
    /// coordinator's row cache bypassed and what the context last saw overwritten: values come from the
    /// store as it is now.
    ///
    /// Otherwise the context *is* the one that just saved, and this runs inside that save. Every row the
    /// notification carried is already registered there holding the committed values, so the registry
    /// answers without touching the store — the writer's registered objects are the source of truth and
    /// may hold changes a legacy block still intends to save. Persistent-history re-posts carry ids this
    /// context never registered; those fall through to the fetch, which also keeps the registry a pure
    /// optimisation rather than a second source of truth.
    func materialize(
        _ objectIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext,
        refreshing: Bool
    ) -> [NSManagedObjectID: U] {
        guard !objectIDs.isEmpty else {
            return [:]
        }

        var result: [NSManagedObjectID: U] = [:]
        var missing: [NSManagedObjectID] = []

        if refreshing {
            missing = objectIDs
        } else {
            for objectID in objectIDs {
                // A deleted row is left to the fetch, which will not return it: gone rows stay absent.
                if let object = context.registeredObject(for: objectID) as? U, !object.isDeleted {
                    result[objectID] = object
                } else {
                    missing.append(objectID)
                }
            }
        }

        guard !missing.isEmpty else {
            return result
        }

        let request = NSFetchRequest<U>(entityName: entityName)
        request.predicate = NSPredicate(format: "SELF IN %@", missing)
        request.returnsObjectsAsFaults = false
        request.shouldRefreshRefetchedObjects = refreshing

        let stalenessInterval = context.stalenessInterval

        if refreshing {
            context.stalenessInterval = 0
        }

        defer {
            context.stalenessInterval = stalenessInterval
        }

        for object in (try? context.fetch(request)) ?? [] where result[object.objectID] == nil {
            result[object.objectID] = object
        }

        return result
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

    /// Stops delivering to ```observer```.
    ///
    /// Removal is ordered against delivery only in ```.serial``` mode. There a change is queued for
    /// delivery inside the save that produced it, before any write completion runs, so a completion that
    /// unsubscribes still receives the change it is reacting to.
    ///
    /// In ```.concurrent``` mode resolution first hops to the observer context, so a change committed just
    /// before this call may be queued either side of it: the last delivery before an unsubscribe is not
    /// guaranteed. Re-subscribing recovers it — ```StreamableProvider``` refetches on ```addObserver``` and
    /// delivers current state as inserts. Closing the gap would mean capturing the observer list when the
    /// notification arrives instead of when the delivery runs, which would let an already-removed observer
    /// receive one final change; that is a worse contract than the one documented here.
    public func removeObserver(_ observer: AnyObject) {
        processingQueue.async {
            self.observers = self.observers.filter { $0.observer != nil && $0.observer !== observer }
        }
    }
}
