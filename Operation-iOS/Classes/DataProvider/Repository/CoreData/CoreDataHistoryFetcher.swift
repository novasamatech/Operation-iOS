import Foundation
import CoreData

/**
 *  Protocol for fetching persistent history transactions.
 */

public protocol CoreDataHistoryFetching {
    func fetch(context: NSManagedObjectContext, fromDate: Date) throws -> [NSPersistentHistoryTransaction]
}

/**
 *  Fetches persistent history transactions from Core Data store.
 *  Filters out transactions from the same author/context to avoid reprocessing own changes.
 */

public struct CoreDataHistoryFetcher: CoreDataHistoryFetching {
    
    public init() {}
    
    public func fetch(context: NSManagedObjectContext, fromDate: Date) throws -> [NSPersistentHistoryTransaction] {
        let request = createFetchRequest(context: context, fromDate: fromDate)
        
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else {
            return []
        }
        
        return transactions
    }
}

private extension CoreDataHistoryFetcher {
    func createFetchRequest(context: NSManagedObjectContext, fromDate: Date) -> NSPersistentHistoryChangeRequest {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: fromDate)
        
        if let fetchRequest = NSPersistentHistoryTransaction.fetchRequest {
            var predicates: [NSPredicate] = []
            
            if let author = context.transactionAuthor {
                predicates.append(NSPredicate(
                    format: "%K != %@",
                    #keyPath(NSPersistentHistoryTransaction.author),
                    author
                ))
            }
            
            if let contextName = context.name {
                predicates.append(NSPredicate(
                    format: "%K != %@",
                    #keyPath(NSPersistentHistoryTransaction.contextName),
                    contextName
                ))
            }
            
            if !predicates.isEmpty {
                fetchRequest.predicate = NSCompoundPredicate(type: .and, subpredicates: predicates)
                request.fetchRequest = fetchRequest
            }
        }
        
        return request
    }
}

