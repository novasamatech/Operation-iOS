import Foundation
import XCTest

extension XCTestCase {
    /// Creates a ``UserDefaults`` suite scoped to the current test instance and schedules
    /// its teardown automatically. Produces an ephemeral, per-test store so tests cannot
    /// leak state through the global ``UserDefaults.standard`` domain or through a shared
    /// suite that would otherwise need manual removal in ``setUp``/``tearDown``.
    ///
    /// Use this instead of ``UserDefaults(suiteName:)`` directly in tests.
    public func makeTestUserDefaults(
        function: StaticString = #function,
        line: UInt = #line
    ) -> UserDefaults {
        let suiteName = "test.\(type(of: self)).\(function).\(line).\(UUID().uuidString)"

        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to create UserDefaults for suite \(suiteName)")
        }

        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        return defaults
    }
}
