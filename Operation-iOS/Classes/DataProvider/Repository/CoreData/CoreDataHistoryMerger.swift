import Foundation
import CoreData

/**
 *  Protocol for merging persistent history transactions.
 */

public protocol CoreDataHistoryMerging {
    func merge(context: NSManagedObjectContext, transactions: [NSPersistentHistoryTransaction]) -> [Notification]
}

/**
 *  Merges persistent history transactions into a managed object context.
 */

public struct CoreDataHistoryMerger: CoreDataHistoryMerging {
    
    public init() {}
    
    /// Merges all transactions into the context and returns notifications for each transaction.
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
