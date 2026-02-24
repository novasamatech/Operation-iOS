import Foundation
import CoreData

/**
 *  Enum defines targets (app and extensions) that share the persistent store
 *  and track history independently.
 *
 *  Each target maintains its own timestamp indicating the last processed transaction.
 *  History can only be cleaned when all targets have processed up to a common point.
 */

public enum CoreDataHistoryTarget: String, CaseIterable {
    /// Main application target.
    case mainApp = "main_app"
    /// Notification service extension target.
    case notificationExtension = "notification_extension"
}

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
 *  data loss when one target hasn't caught up yet. After successful cleanup, timestamps
 *  are reset to allow the next cleanup cycle.
 */

public struct CoreDataHistoryCleaner: CoreDataHistoryCleaning {
    private let targets: [CoreDataHistoryTarget]
    private let userDefaults: UserDefaults
    
    /**
     *  Creates a new history cleaner.
     *
     *  - parameters:
     *    - targets: Array of targets that must all have processed history before cleanup.
     *               Defaults to all targets defined in ```CoreDataHistoryTarget```.
     *    - userDefaults: UserDefaults instance for reading target timestamps.
     */
    public init(
        targets: [CoreDataHistoryTarget] = CoreDataHistoryTarget.allCases,
        userDefaults: UserDefaults = .standard
    ) {
        self.targets = targets
        self.userDefaults = userDefaults
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
        
        targets.forEach { userDefaults.removeObject(forKey: timestampKey(for: $0)) }
    }
}

private extension CoreDataHistoryCleaner {
    /// Returns the oldest timestamp that all targets have processed.
    /// Returns nil if any target hasn't processed history yet.
    func lastCommonTransactionTimestamp() -> Date? {
        let timestamps = targets.compactMap { lastHistoryTimestamp(for: $0) }
        
        guard timestamps.count == targets.count else {
            return nil
        }
        
        return timestamps.min()
    }
    
    func lastHistoryTimestamp(for target: CoreDataHistoryTarget) -> Date? {
        userDefaults.object(forKey: timestampKey(for: target)) as? Date
    }
    
    func timestampKey(for target: CoreDataHistoryTarget) -> String {
        "io.novasama.coredata.lastHistoryTimestamp.\(target.rawValue)"
    }
}

