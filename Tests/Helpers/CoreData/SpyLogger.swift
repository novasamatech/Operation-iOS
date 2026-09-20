import Foundation
import SDKLogger

/// Records what the library logs so tests can assert on diagnostics that are deliberately not errors.
public final class SpyLogger: SDKLoggerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: String, message: String)] = []

    public init() {}

    public var warnings: [String] { messages(at: "warning") }

    public var allMessages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.message)
    }

    private func messages(at level: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.level == level }.map(\.message)
    }

    private func record(_ level: String, _ message: () -> String) {
        let text = message()

        lock.lock()
        entries.append((level: level, message: text))
        lock.unlock()
    }

    public func verbose(message: () -> String, file: String, function: String, line: Int) {
        record("verbose", message)
    }

    public func debug(message: () -> String, file: String, function: String, line: Int) {
        record("debug", message)
    }

    public func info(message: () -> String, file: String, function: String, line: Int) {
        record("info", message)
    }

    public func warning(message: () -> String, file: String, function: String, line: Int) {
        record("warning", message)
    }

    public func error(message: () -> String, file: String, function: String, line: Int) {
        record("error", message)
    }
}
