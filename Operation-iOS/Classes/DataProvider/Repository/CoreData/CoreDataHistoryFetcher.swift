import Foundation
import CoreData

/**
 *  Protocol for fetching persistent history transactions from Core Data store.
 */

public protocol CoreDataHistoryFetching {
    /**
     *  Fetches persistent history transactions after the specified date.
     *
     *  - parameters:
     *    - context: The managed object context to execute the fetch request.
     *    - fromDate: The date after which to fetch transactions.
     *  - returns: Array of history transactions, or empty array if none found.
     *  - throws: Core Data errors if the fetch request fails.
     */
    func fetch(context: NSManagedObjectContext, fromDate: Date) throws -> [NSPersistentHistoryTransaction]
}

/**
 *  Implementation of ```CoreDataHistoryFetching``` that fetches persistent history transactions
 *  from Core Data store.
 *
 *  Automatically filters out transactions from the same author and context name
 *  to avoid reprocessing own changes. This is essential for cross-process history tracking
 *  where only changes from other processes should be processed.
 */

public struct CoreDataHistoryFetcher: CoreDataHistoryFetching {
    
    /// Creates a new history fetcher instance.
    public init() {}
    
    /**
     *  Fetches persistent history transactions after the specified date,
     *  excluding transactions from the same author/context.
     *
     *  - parameters:
     *    - context: The managed object context to execute the fetch request.
     *    - fromDate: The date after which to fetch transactions.
     *  - returns: Array of history transactions from other authors/contexts.
     *  - throws: Core Data errors if the fetch request fails.
     */
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

        guard let fetchRequest = NSPersistentHistoryTransaction.fetchRequest else {
            return request
        }

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

        return request
    }
}

