import Foundation
import CoreData

/**
 *  Protocol for merging persistent history transactions into a managed object context.
 */

public protocol CoreDataHistoryMerging {
    /**
     *  Merges transactions into the context and returns notifications for processed changes.
     *
     *  - parameters:
     *    - contexts: The managed object contexts to merge changes into.
     *    - transactions: Array of history transactions to merge. Must be called on the queue of the context
     *      that fetched them: the transactions are bound to it.
     *  - returns: Array of notifications containing object ID changes for each merged transaction.
     */
    func merge(contexts: [NSManagedObjectContext], transactions: [NSPersistentHistoryTransaction]) -> [Notification]
}

/**
 *  Implementation of ```CoreDataHistoryMerging``` that merges persistent history transactions
 *  into a managed object context.
 *
 *  Uses ```NSManagedObjectContext.mergeChanges(fromRemoteContextSave:into:)``` to properly
 *  integrate changes from other processes into the current context, ensuring proper
 *  change tracking and notification delivery.
 */

public struct CoreDataHistoryMerger: CoreDataHistoryMerging {
    
    /// Creates a new history merger instance.
    public init() {}
    
    /**
     *  Merges all transactions into the context and returns notifications for each transaction.
     *
     *  Every transaction is reduced to its notification here, on the caller's queue, because the transaction
     *  objects belong to the context that fetched them and must not be touched from another. What crosses to
     *  the other contexts is the resulting ```userInfo``` — plain object identifiers — and
     *  ```mergeChanges(fromRemoteContextSave:into:)``` hops onto each target context's own queue itself.
     *
     *  - parameters:
     *    - contexts: The managed object contexts to merge changes into.
     *    - transactions: Array of history transactions to merge.
     *  - returns: Array of notifications containing object ID changes, one per merged transaction.
     */
    public func merge(
        contexts: [NSManagedObjectContext],
        transactions: [NSPersistentHistoryTransaction]
    ) -> [Notification] {
        let notifications = transactions.map { $0.objectIDNotification() }

        for notification in notifications {
            guard let userInfo = notification.userInfo else {
                continue
            }

            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: userInfo, into: contexts)
        }

        return notifications
    }
}
