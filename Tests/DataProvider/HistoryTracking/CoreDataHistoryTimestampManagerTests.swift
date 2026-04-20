import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryTimestampManagerTests: XCTestCase {

    // MARK: - Tests

    func testUpdateTimestampStoresValue() {
        // given
        let sut = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: makeTestUserDefaults())
        let date = Date()

        // when
        sut.update(to: date)

        // then
        XCTAssertEqual(
            sut.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testResetRemovesTimestamp() {
        // given
        let sut = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: makeTestUserDefaults())
        sut.update(to: Date())

        // when
        sut.reset()

        // then
        XCTAssertNil(sut.lastTimestamp)
    }

    func testDifferentTargetsHaveIndependentTimestamps() {
        // given - share one backing store to prove namespacing by target key
        let defaults = makeTestUserDefaults()
        let mainAppManager = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: defaults)
        let extensionManager = CoreDataHistoryTimestampManager(target: "notification-extension", userDefaults: defaults)

        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)

        // when
        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)

        // then
        XCTAssertEqual(
            mainAppManager.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            mainAppDate.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            extensionManager.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            extensionDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testTimestampPersistsAcrossInstances() {
        // given - share one backing store to simulate separate instances of the same target
        let defaults = makeTestUserDefaults()
        let date = Date()
        let firstManager = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: defaults)
        firstManager.update(to: date)

        // when
        let secondManager = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: defaults)

        // then
        XCTAssertEqual(
            secondManager.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testResetOnlyAffectsOwnTarget() {
        // given
        let defaults = makeTestUserDefaults()
        let mainAppManager = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: defaults)
        let extensionManager = CoreDataHistoryTimestampManager(target: "notification-extension", userDefaults: defaults)

        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)

        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)

        // when
        mainAppManager.reset()

        // then
        XCTAssertNil(mainAppManager.lastTimestamp)
        XCTAssertEqual(
            extensionManager.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            extensionDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testUpdateOverwritesPreviousTimestamp() {
        // given
        let sut = CoreDataHistoryTimestampManager(target: "main-app", userDefaults: makeTestUserDefaults())
        let firstDate = Date()
        let secondDate = Date().addingTimeInterval(500)

        // when
        sut.update(to: firstDate)
        sut.update(to: secondDate)

        // then
        XCTAssertEqual(
            sut.lastTimestamp?.timeIntervalSince1970 ?? .nan,
            secondDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
