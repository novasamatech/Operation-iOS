import Foundation

/**
 *  Protocol that abstracts per-target timestamp storage for persistent history tracking.
 */

public protocol CoreDataHistoryTimestampManaging {
    /// The timestamp of the last processed transaction, or `nil` if no history has been processed yet.
    var lastTimestamp: Date? { get }

    /// Updates the last processed timestamp to the specified date.
    func update(to date: Date)

    /// Removes the stored timestamp, indicating no history has been processed.
    func reset()
}

/**
 *  Errors thrown by ``CoreDataHistoryTimestampManager`` during initialization.
 */

public enum CoreDataHistoryTimestampManagerError: Error {
    /// The shared app group container is unavailable for the provided identifier.
    case sharedContainerUnavailable(String)
}

/**
 *  Manages timestamp storage for persistent history tracking per target.
 *
 *  Each target (app or extension) maintains its own timestamp indicating the last
 *  processed transaction. This allows the cleaner to determine when history can be
 *  safely deleted (when all targets have processed up to a common point).
 *
 *  Timestamps are persisted in an app group ```UserDefaults``` suite shared across
 *  targets, created from the shared container identifier passed during initialization.
 */

public struct CoreDataHistoryTimestampManager: CoreDataHistoryTimestampManaging {
    private let target: String
    private let userDefaults: UserDefaults

    /**
     *  Creates a new timestamp manager backed by an app group ```UserDefaults``` suite.
     *
     *  - parameters:
     *    - target: The target identifier this manager tracks timestamps for.
     *    - sharedContainer: App group identifier used to construct the shared
     *      ```UserDefaults``` suite. Must be accessible by all participating targets.
     *
     *  - throws: ``CoreDataHistoryTimestampManagerError/sharedContainerUnavailable(_:)``
     *    when ```UserDefaults(suiteName:)``` returns ```nil``` for the provided identifier.
     */
    public init(
        target: String,
        sharedContainer: String
    ) throws {
        guard let userDefaults = UserDefaults(suiteName: sharedContainer) else {
            throw CoreDataHistoryTimestampManagerError.sharedContainerUnavailable(sharedContainer)
        }

        self.target = target
        self.userDefaults = userDefaults
    }

    init(target: String, userDefaults: UserDefaults) {
        self.target = target
        self.userDefaults = userDefaults
    }

    public var lastTimestamp: Date? {
        userDefaults.object(forKey: timestampKey) as? Date
    }

    public func update(to date: Date) {
        userDefaults.set(date, forKey: timestampKey)
    }

    public func reset() {
        userDefaults.removeObject(forKey: timestampKey)
    }

    private var timestampKey: String {
        "io.novasama.coredata.lastHistoryTimestamp.\(target)"
    }
}
