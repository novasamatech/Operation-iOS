import Foundation

/**
 *  Manages timestamp storage for persistent history tracking per target.
 *
 *  Each target (app or extension) maintains its own timestamp indicating the last
 *  processed transaction. This allows the cleaner to determine when history can be
 *  safely deleted (when all targets have processed up to a common point).
 */

public struct CoreDataHistoryTimestampManager {
    private let target: String
    private let userDefaults: UserDefaults

    /**
     *  Creates a new timestamp manager for the specified target.
     *
     *  - parameters:
     *    - target: The target identifier this manager tracks timestamps for.
     *    - userDefaults: UserDefaults instance for storing timestamps.
     */
    public init(
        target: String,
        userDefaults: UserDefaults = .standard
    ) {
        self.target = target
        self.userDefaults = userDefaults
    }

    /// The timestamp of the last processed transaction, or `nil` if no history has been processed yet.
    public var lastTimestamp: Date? {
        userDefaults.object(forKey: timestampKey) as? Date
    }

    /// Updates the last processed timestamp to the specified date.
    public func update(to date: Date) {
        userDefaults.set(date, forKey: timestampKey)
    }

    /// Removes the stored timestamp, indicating no history has been processed.
    public func reset() {
        userDefaults.removeObject(forKey: timestampKey)
    }

    private var timestampKey: String {
        "io.novasama.coredata.lastHistoryTimestamp.\(target)"
    }
}
