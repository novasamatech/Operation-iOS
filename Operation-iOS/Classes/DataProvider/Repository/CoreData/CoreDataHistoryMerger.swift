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
     *    - context: The managed object context to merge changes into.
     *    - transactions: Array of history transactions to merge.
     *  - returns: Array of notifications containing object ID changes for each merged transaction.
     */
    func merge(context: NSManagedObjectContext, transactions: [NSPersistentHistoryTransaction]) -> [Notification]
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
     *  - parameters:
     *    - context: The managed object context to merge changes into.
     *    - transactions: Array of history transactions to merge.
     *  - returns: Array of notifications containing object ID changes, one per merged transaction.
     */
    public func merge(context: NSManagedObjectContext, transactions: [NSPersistentHistoryTransaction]) -> [Notification] {
        var notifications: [Notification] = []
        
        for transaction in transactions {
            guard let userInfo = transaction.objectIDNotification().userInfo else { continue }
            
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: userInfo, into: [context])
            notifications.append(transaction.objectIDNotification())
        }
        
        return notifications
    }
}
