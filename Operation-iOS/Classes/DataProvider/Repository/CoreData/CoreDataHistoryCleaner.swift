import Foundation
import CoreData

/**
 *  Defines targets that share the persistent store and track history independently.
 */

public enum CoreDataHistoryTarget: String, CaseIterable {
    case mainApp = "main_app"
    case notificationExtension = "notification_extension"
}

/**
 *  Protocol for cleaning persistent history transactions.
 */

public protocol CoreDataHistoryCleaning {
    func clean(context: NSManagedObjectContext) throws
}

/**
 *  Cleans up old persistent history transactions that have been processed by all targets.
 */

public struct CoreDataHistoryCleaner: CoreDataHistoryCleaning {
    private let targets: [CoreDataHistoryTarget]
    private let userDefaults: UserDefaults
    
    public init(
        targets: [CoreDataHistoryTarget] = CoreDataHistoryTarget.allCases,
        userDefaults: UserDefaults = .standard
    ) {
        self.targets = targets
        self.userDefaults = userDefaults
    }
    
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

