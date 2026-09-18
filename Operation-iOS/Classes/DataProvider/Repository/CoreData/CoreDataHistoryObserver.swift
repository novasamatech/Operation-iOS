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
    private let contexts: [NSManagedObjectContext]
    private let timestampManager: CoreDataHistoryTimestampManaging
    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning

    /// The context history is fetched on, cleaned from and re-posted for: the writer.
    private var context: NSManagedObjectContext { contexts[0] }

    /**
     *  Creates a new persistent history observer.
     *
     *  - parameters:
     *    - contexts: The managed object contexts to merge remote changes into. The first one is
     *      the writer: history is fetched and cleaned there and re-posted with it as the notification
     *      object. Every remaining context (an observer context, typically) receives the same merge.
     *    - timestampManager: Timestamp manager tracking history processed by the current target.
     *    - cleaner: Object responsible for cleaning old history across all targets.
     *    - fetcher: Object responsible for fetching history transactions. Defaults to ```CoreDataHistoryFetcher```.
     *    - merger: Object responsible for merging transactions into context. Defaults to ```CoreDataHistoryMerger```.
     */
    public init(
        contexts: [NSManagedObjectContext],
        timestampManager: CoreDataHistoryTimestampManaging,
        cleaner: CoreDataHistoryCleaning,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger()
    ) {
        precondition(!contexts.isEmpty, "history observer needs at least the writer context")

        self.contexts = contexts
        self.timestampManager = timestampManager
        self.cleaner = cleaner
        self.fetcher = fetcher
        self.merger = merger
    }

    /// Single-context convenience: the 2.x shape.
    public convenience init(
        context: NSManagedObjectContext,
        timestampManager: CoreDataHistoryTimestampManaging,
        cleaner: CoreDataHistoryCleaning,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger()
    ) {
        self.init(
            contexts: [context],
            timestampManager: timestampManager,
            cleaner: cleaner,
            fetcher: fetcher,
            merger: merger
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

            for sibling in self.contexts.dropFirst() {
                sibling.perform { [merger = self.merger] in
                    _ = merger.merge(context: sibling, transactions: transactions)
                }
            }

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
