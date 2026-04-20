import Foundation
import CoreData
import UIKit

/**
 *  Class is designed to observe Core Data persistent history changes from other processes
 *  (e.g., app extensions) and merge them into the current context.
 *
 *  The observer listens for ```NSPersistentStoreRemoteChange``` notifications and processes
 *  pending history transactions by fetching, merging, updating timestamps, and cleaning up
 *  old history that all targets have processed.
 *
 *  After merging, the observer re-posts the changes as ```NSManagedObjectContextDidSave```
 *  notifications so that any ```CoreDataContextObservable``` instances listening on the
 *  same context automatically pick up the remote changes.
 *
 *  It also observes app state to process any pending history when the app becomes active.
 */

public final class CoreDataHistoryObserver {
    private let context: NSManagedObjectContext
    private let timestampManager: CoreDataHistoryTimestampManaging
    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning

    /**
     *  Creates a new persistent history observer.
     *
     *  - parameters:
     *    - context: The managed object context to merge remote changes into.
     *    - timestampManager: Timestamp manager tracking history processed by the current target.
     *    - cleaner: Object responsible for cleaning old history across all targets.
     *    - fetcher: Object responsible for fetching history transactions. Defaults to ```CoreDataHistoryFetcher```.
     *    - merger: Object responsible for merging transactions into context. Defaults to ```CoreDataHistoryMerger```.
     */
    public init(
        context: NSManagedObjectContext,
        timestampManager: CoreDataHistoryTimestampManaging,
        cleaner: CoreDataHistoryCleaning,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger()
    ) {
        self.context = context
        self.timestampManager = timestampManager
        self.cleaner = cleaner
        self.fetcher = fetcher
        self.merger = merger
    }

    /// Starts observing persistent store remote changes and app state notifications.
    public func startObserving() {
        if let coordinator = context.persistentStoreCoordinator {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didReceiveRemoteChange(notification:)),
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }

        processPendingHistory()
        startObservingAppState()
    }

    /// Stops observing persistent store remote changes and app state notifications.
    public func stopObserving() {
        if let coordinator = context.persistentStoreCoordinator {
            NotificationCenter.default.removeObserver(
                self,
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
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
        context.perform { [weak self] in
            guard let self else { return }

            let fromDate = self.timestampManager.lastTimestamp ?? .distantPast

            guard
                let transactions = try? self.fetcher.fetch(context: self.context, fromDate: fromDate),
                !transactions.isEmpty
            else { return }

            _ = self.merger.merge(context: self.context, transactions: transactions)

            if let lastTimestamp = transactions.last?.timestamp {
                self.timestampManager.update(to: lastTimestamp)
            }

            // Post as didSave so CoreDataContextObservable picks up the changes
            transactions.forEach {
                NotificationCenter.default.post(
                    name: .NSManagedObjectContextDidSave,
                    object: self.context,
                    userInfo: $0.objectIDNotification().userInfo
                )
            }

            try? self.cleaner.clean(context: self.context)
        }
    }
}
