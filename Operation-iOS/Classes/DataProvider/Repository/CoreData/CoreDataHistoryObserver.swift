import Foundation
import CoreData
import UIKit
import SDKLogger

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
 *  Deleted rows are gone by the time a transaction is replayed, so their identifiers can only come from
 *  persistent-history tombstones. The re-posted notification carries them under ```tombstonesKey``` as
 *  ```CoreDataHistoryTombstone``` values; attributes are only preserved there when the model marks them
 *  with ```preserveAfterDeletion```.
 *
 *  It also observes app state to process any pending history when the app becomes active.
 */

/// The attributes persistent history preserved for a row another process deleted.
public struct CoreDataHistoryTombstone {
    public let objectID: NSManagedObjectID
    public let values: [AnyHashable: Any]
}

public final class CoreDataHistoryObserver {
    /// ```userInfo``` key of the re-posted did-save notification holding ```[CoreDataHistoryTombstone]```.
    public static let tombstonesKey = "io.novasama.coredata.history.tombstones"

    private let contexts: [NSManagedObjectContext]
    private let timestampManager: CoreDataHistoryTimestampManaging
    private let fetcher: CoreDataHistoryFetching
    private let merger: CoreDataHistoryMerging
    private let cleaner: CoreDataHistoryCleaning
    private let logger: SDKLoggerProtocol?

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
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger(),
        logger: SDKLoggerProtocol? = nil
    ) {
        precondition(!contexts.isEmpty, "history observer needs at least the writer context")

        self.contexts = contexts
        self.timestampManager = timestampManager
        self.cleaner = cleaner
        self.fetcher = fetcher
        self.merger = merger
        self.logger = logger
    }

    /// Single-context convenience: the 2.x shape.
    public convenience init(
        context: NSManagedObjectContext,
        timestampManager: CoreDataHistoryTimestampManaging,
        cleaner: CoreDataHistoryCleaning,
        fetcher: CoreDataHistoryFetching = CoreDataHistoryFetcher(),
        merger: CoreDataHistoryMerging = CoreDataHistoryMerger(),
        logger: SDKLoggerProtocol? = nil
    ) {
        self.init(
            contexts: [context],
            timestampManager: timestampManager,
            cleaner: cleaner,
            fetcher: fetcher,
            merger: merger,
            logger: logger
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
            transactions.forEach { transaction in
                var userInfo = transaction.objectIDNotification().userInfo ?? [:]

                let deletes = (transaction.changes ?? []).filter { $0.changeType == .delete }

                let tombstones = deletes.compactMap { change in
                    change.tombstone.map { CoreDataHistoryTombstone(objectID: change.changedObjectID, values: $0) }
                }

                if tombstones.count < deletes.count {
                    // The rows are already gone; without a tombstone nothing identifies them to observers.
                    self.logger?.warning(
                        "\(deletes.count - tombstones.count) remote delete(s) carried no persistent-history "
                        + "tombstone and cannot be delivered to observers. Mark the identifier attribute with "
                        + "Preserve After Deletion in the model."
                    )
                }

                if !tombstones.isEmpty {
                    userInfo[Self.tombstonesKey] = tombstones
                }

                NotificationCenter.default.post(
                    name: .NSManagedObjectContextDidSave,
                    object: self.context,
                    userInfo: userInfo
                )
            }

            try? self.cleaner.clean(context: self.context)
        }
    }
}
