import Foundation

/**
 *  Manages timestamp storage for persistent history tracking per target.
 */

public struct CoreDataHistoryTimestampManager {
    private let target: CoreDataHistoryTarget
    private let userDefaults: UserDefaults
    
    public init(
        target: CoreDataHistoryTarget,
        userDefaults: UserDefaults = .standard
    ) {
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
        "io.novasama.coredata.lastHistoryTimestamp.\(target.rawValue)"
    }
}
