import Foundation

/// Canonical transaction-author / target identifiers used across history-tracking tests.
///
/// Centralising these prevents silent drift between test files (e.g. ``other_process`` vs
/// ``other-process``) and documents the roles each string plays.
public enum HistoryTestAuthors {
    /// Default author used by ``CoreDataServiceConfiguration/createConfigurationWithHistoryTracking``
    /// helpers when the caller does not specify one.
    public static let defaultTest = "test"

    /// Represents the foreground app target.
    public static let mainApp = "main-app"

    /// Represents the notification-service extension target.
    public static let notificationExtension = "notification-extension"

    /// Represents an arbitrary second process writing to the same store, used to simulate
    /// cross-process history that the main service must observe, merge or clean.
    public static let otherProcess = "other_process"
}
