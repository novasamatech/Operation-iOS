import Foundation
@testable import Operation_iOS

/// In-memory ``CoreDataHistoryTimestampManaging`` implementation used in tests to
/// avoid the fragility of ``UserDefaults``-backed storage (persistent plists survive
/// across runs, `removePersistentDomain(forName:)` does not always fully clear state,
/// and leftover keys can leak between cases).
public final class InMemoryHistoryTimestampManager: CoreDataHistoryTimestampManaging {
    private var storage: Date?

    public init(initial: Date? = nil) {
        storage = initial
    }

    public var lastTimestamp: Date? { storage }

    public func update(to date: Date) {
        storage = date
    }

    public func reset() {
        storage = nil
    }
}
