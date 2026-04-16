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
    private let target: String

    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning
    private let userDefaults: UserDefaults

    private lazy var timestampManager = CoreDataHistoryTimestampManager(
        target: target,
        userDefaults: userDefaults
    )

    /**
     *  Creates a new persistent history observer.
     *
     *  - parameters:
     *    - context: The managed object context to merge remote changes into.
     *    - target: Identifier of the current target (e.g., ```CoreDataHistoryTarget.mainApp```).
     *    - targets: All target identifiers sharing the persistent store. Used by the cleaner
     *              to wait for all targets before deleting history. Defaults to ```[target]```.
     *    - userDefaults: UserDefaults instance for storing history timestamps.
     *              Should be a shared app group suite when multiple targets share the store.
     *    - fetcher: Object responsible for fetching history transactions. Defaults to ```CoreDataHistoryFetcher```.
     *    - merger: Object responsible for merging transactions into context. Defaults to ```CoreDataHistoryMerger```.
     *    - cleaner: Object responsible for cleaning old history. Defaults to ```CoreDataHistoryCleaner```
     *              with the provided targets and userDefaults.
     */
    public init(
        context: NSManagedObjectContext,
        target: String,
        targets: [String]? = nil,
        userDefaults: UserDefaults = .standard,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger(),
        cleaner: CoreDataHistoryCleaning? = nil
    ) {
        self.context = context
        self.target = target
        self.userDefaults = userDefaults
        self.fetcher = fetcher
        self.merger = merger
        self.cleaner = cleaner ?? CoreDataHistoryCleaner(
            targets: targets ?? [target],
            userDefaults: userDefaults
        )
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
