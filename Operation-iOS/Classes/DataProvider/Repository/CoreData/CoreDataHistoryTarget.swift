import Foundation

/**
 *  Namespace providing well-known target identifiers for persistent history tracking.
 *
 *  Each target (app or extension) that shares a persistent store should use a unique
 *  identifier string. The main app identifier is provided here; other targets
 *  (notification extensions, widgets, app clips, etc.) should define their own
 *  identifiers upon configuration.
 */

public enum CoreDataHistoryTarget {
    /// Default identifier for the main application target.
    public static let mainApp: String = "main-app"
}
