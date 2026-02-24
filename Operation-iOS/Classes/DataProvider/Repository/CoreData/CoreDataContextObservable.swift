import Foundation
import CoreData

/**
 *  Class is designed to provide implementation for ```DataProviderRepositoryObservable``` and allows
 *  observation of Core Data based repositories through NSManagedObjectContext notifications.
 *
 *  Changes are delivered as a list of ```DataProviderChange``` values to every subscribed observer.
 *  Changes can be filtered by providing predicate closure during initialization.
 */

final public class CoreDataContextObservable<T: Identifiable, U: NSManagedObject> {
    private(set) var service: CoreDataServiceProtocol
    private(set) var mapper: AnyCoreDataMapper<T, U>
    private(set) var processingQueue: DispatchQueue
    private(set) var predicate: (U) -> Bool

    private var observers: [RepositoryObserver<T>] = []
    
    // Persistent History Tracking

    private var historyObserver: CoreDataHistoryObserver?
    private let target: CoreDataHistoryTarget
    private let userDefaults: UserDefaults

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
     *    - target: The target (app or extension) for history tracking.
     *    - userDefaults: UserDefaults instance for storing history timestamp.
     */

    public init(
        service: CoreDataServiceProtocol,
        mapper: AnyCoreDataMapper<T, U>,
        predicate: @escaping (U) -> Bool,
        processingQueue: DispatchQueue? = nil,
        target: CoreDataHistoryTarget = .mainApp,
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.mapper = mapper
        self.predicate = predicate
        self.target = target
        self.userDefaults = userDefaults

        if let processingQueue = processingQueue {
            self.processingQueue = processingQueue
        } else {
            self.processingQueue = DispatchQueue(
                label: "io.novasama.streamableobservable.queue.\(UUID().uuidString)",
                qos: .utility)
        }
    }

    @objc private func didReceive(notification: Notification) {
        var changes: [DataProviderChange<T>] = []

        let translationClosure: (Any) -> U? = { object in
            if let object = object as? U {
                return object
            } else {
                return nil
            }
        }

        if let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? NSSet {

            let matchingChanges: [DataProviderChange<T>] = updatedObjects.allObjects
                .compactMap(translationClosure)
                .filter(predicate)
                .compactMap({ try? mapper.transform(entity: $0) })
                .map({ DataProviderChange.update(newItem: $0) })

            changes.append(contentsOf: matchingChanges)
        }

        if let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? NSSet {
            let matchingChanges: [DataProviderChange<T>] = deletedObjects.allObjects
                .compactMap(translationClosure)
                .filter(predicate)
                .compactMap({ $0.value(forKey: mapper.entityIdentifierFieldName) as? String })
                .map({ DataProviderChange.delete(deletedIdentifier: $0) })

            changes.append(contentsOf: matchingChanges)
        }

        if let insertedObjects = notification.userInfo?[NSInsertedObjectsKey] as? NSSet {
            let matchingChanges: [DataProviderChange<T>] = insertedObjects.allObjects
                .compactMap(translationClosure)
                .filter(predicate)
                .compactMap({ try? mapper.transform(entity: $0) })
                .map({ DataProviderChange.insert(newItem: $0) })

            changes.append(contentsOf: matchingChanges)
        }

        guard changes.count > 0 else {
            return
        }

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
    
    func startHistoryTracking() {
        processingQueue.async {
            guard case let .persistent(settings) = self.service.configuration.storageType,
                  settings.enableHistoryTracking
            else { return }

            let historyObserver = CoreDataHistoryObserver(
                service: self.service,
                target: self.target,
                userDefaults: self.userDefaults
            )
            historyObserver.delegate = self
            historyObserver.startObserving()
            self.historyObserver = historyObserver
        }
    }
    
    func stopHistoryTracking() {
        processingQueue.async {
            self.historyObserver?.stopObserving()
            self.historyObserver = nil
        }
    }
}

// MARK: - CoreDataHistoryObserverDelegate

extension CoreDataContextObservable: CoreDataHistoryObserverDelegate {
    public func persistentHistoryObserver(
        _ observer: CoreDataHistoryObserver,
        didReceiveNotifications notifications: [Notification]
    ) {
        for notification in notifications {
            didReceive(notification: notification)
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
        
        startHistoryTracking()
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
        
        stopHistoryTracking()
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
