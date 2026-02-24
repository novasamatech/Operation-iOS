import Foundation
import CoreData
import UIKit

/**
 *  Protocol to receive notifications about persistent history changes from other processes.
 */

public protocol CoreDataHistoryObserverDelegate: AnyObject {
    /**
     *  Called when the observer has processed remote changes and merged them into the context.
     *
     *  - parameters:
     *    - observer: The observer that detected and processed the changes.
     *    - notifications: Notifications containing object ID changes for each merged transaction.
     */
    func persistentHistoryObserver(
        _ observer: CoreDataHistoryObserver,
        didReceiveNotifications notifications: [Notification]
    )
}

/**
 *  Class is designed to observe Core Data persistent history changes from other processes
 *  (e.g., app extensions) and merge them into the current context.
 *
 *  The observer listens for ```NSPersistentStoreRemoteChange``` notifications and processes
 *  pending history transactions by fetching, merging, updating timestamps, and cleaning up
 *  old history that all targets have processed.
 *
 *  It also observes app state to process any pending history when the app becomes active.
 */

public final class CoreDataHistoryObserver {
    private let service: CoreDataServiceProtocol
    private let target: CoreDataHistoryTarget
    private let userDefaults: UserDefaults

    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning
    
    private lazy var timestampManager = CoreDataHistoryTimestampManager(
        target: target,
        userDefaults: userDefaults
    )
    
    /// Delegate to receive notifications about processed history changes.
    public weak var delegate: CoreDataHistoryObserverDelegate?
    
    /**
     *  Creates a new persistent history observer.
     *
     *  - parameters:
     *    - service: Core Data service which manages persistent store and contexts.
     *    - target: The target (app or extension) for history tracking.
     *    - userDefaults: UserDefaults instance for storing history timestamps.
     *    - fetcher: Object responsible for fetching history transactions. Defaults to ```CoreDataHistoryFetcher```.
     *    - merger: Object responsible for merging transactions into context. Defaults to ```CoreDataHistoryMerger```.
     *    - cleaner: Object responsible for cleaning old history. Defaults to ```CoreDataHistoryCleaner```.
     */
    public init(
        service: CoreDataServiceProtocol,
        target: CoreDataHistoryTarget,
        userDefaults: UserDefaults = .standard,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger(),
        cleaner: CoreDataHistoryCleaning? = nil
    ) {
        self.service = service
        self.target = target
        self.userDefaults = userDefaults
        self.fetcher = fetcher
        self.merger = merger
        self.cleaner = cleaner ?? CoreDataHistoryCleaner(userDefaults: userDefaults)
    }
    
    /// Starts observing persistent store remote changes and app state notifications.
    public func startObserving() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }

            if let coordinator = context.persistentStoreCoordinator {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(self.didReceiveRemoteChange(notification:)),
                    name: .NSPersistentStoreRemoteChange,
                    object: coordinator
                )
            }

            self.processPendingHistory()
        }
        
        startObservingAppState()
    }

    /// Stops observing persistent store remote changes and app state notifications.
    public func stopObserving() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }
            
            if let coordinator = context.persistentStoreCoordinator {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .NSPersistentStoreRemoteChange,
                    object: coordinator
                )
            }
        }
        
        stopObservingAppState()
    }
}

private extension CoreDataHistoryObserver {
    @objc func didReceiveRemoteChange(notification: Notification) {
        processPendingHistory()
    }
    
    @objc func didBecomeActive() {
        processPendingHistory()
    }

    func startObservingAppState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func stopObservingAppState() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    func processPendingHistory() {
        service.performAsync { [weak self] context, _ in
            guard let self, let context else { return }
            
            let fromDate = self.timestampManager.lastTimestamp ?? .distantPast
            
            guard
                let transactions = try? self.fetcher.fetch(context: context, fromDate: fromDate),
                !transactions.isEmpty
            else { return }
            
            let notifications = self.merger.merge(context: context, transactions: transactions)
            
            if let lastTimestamp = transactions.last?.timestamp {
                self.timestampManager.update(to: lastTimestamp)
            }
            
            if !notifications.isEmpty {
                self.delegate?.persistentHistoryObserver(self, didReceiveNotifications: notifications)
            }
            
            try? self.cleaner.clean(context: context)
        }
    }
}
