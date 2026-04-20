import Foundation
import CoreData

/**
 *  Protocol for cleaning persistent history transactions from the store.
 */

public protocol CoreDataHistoryCleaning {
    /**
     *  Cleans up old persistent history transactions.
     *
     *  - parameters:
     *    - context: The managed object context to execute the delete request.
     *  - throws: Core Data errors if the delete request fails.
     */
    func clean(context: NSManagedObjectContext) throws
}

/**
 *  Implementation of ```CoreDataHistoryCleaning``` that cleans up old persistent history
 *  transactions that have been processed by all targets.
 *
 *  The cleaner only deletes history that all configured targets have processed to prevent
 *  data loss when one target hasn't caught up yet. Timestamps are preserved after cleanup
 *  so that each target's observer continues fetching from where it left off.
 */

public struct CoreDataHistoryCleaner: CoreDataHistoryCleaning {
    private let timestampManagers: [CoreDataHistoryTimestampManaging]

    /**
     *  Creates a new history cleaner.
     *
     *  - parameters:
     *    - timestampManagers: Timestamp managers, one per target, that must all have
     *      processed history before cleanup is performed.
     */
    public init(timestampManagers: [CoreDataHistoryTimestampManaging]) {
        self.timestampManagers = timestampManagers
    }

    /**
     *  Cleans up persistent history transactions that all targets have processed.
     *
     *  Only deletes history before the oldest timestamp among all targets.
     *  If any target hasn't processed history yet (no timestamp), cleanup is skipped.
     *
     *  - parameters:
     *    - context: The managed object context to execute the delete request.
     *  - throws: Core Data errors if the delete request fails.
     */
    public func clean(context: NSManagedObjectContext) throws {
        guard let timestamp = lastCommonTransactionTimestamp() else {
            return
        }

        let deleteRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: timestamp)
        try context.execute(deleteRequest)
    }
}

private extension CoreDataHistoryCleaner {
    /// Returns the oldest timestamp that all targets have processed.
    /// Returns nil if any target hasn't processed history yet.
    func lastCommonTransactionTimestamp() -> Date? {
        let timestamps = timestampManagers.compactMap { $0.lastTimestamp }

        guard timestamps.count == timestampManagers.count else {
            return nil
        }

        return timestamps.min()
    }
}
