import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryTimestampManagerTests: XCTestCase {

    // MARK: - Tests

    func testUpdateTimestampStoresValue() throws {
        // given
        let sut = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: makeTestUserDefaults()
        )
        let date = Date()

        // when
        sut.update(to: date)

        // then
        let stored = try XCTUnwrap(sut.lastTimestamp)
        XCTAssertEqual(stored.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetRemovesTimestamp() {
        // given
        let sut = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: makeTestUserDefaults()
        )
        sut.update(to: Date())

        // when
        sut.reset()

        // then
        XCTAssertNil(sut.lastTimestamp)
    }

    func testDifferentTargetsHaveIndependentTimestamps() throws {
        // given - share one backing store to prove namespacing by target key
        let defaults = makeTestUserDefaults()
        let mainAppManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: defaults
        )
        let extensionManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.notificationExtension,
            userDefaults: defaults
        )

        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)

        // when
        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)

        // then
        let mainAppStored = try XCTUnwrap(mainAppManager.lastTimestamp)
        let extensionStored = try XCTUnwrap(extensionManager.lastTimestamp)
        XCTAssertEqual(mainAppStored.timeIntervalSince1970, mainAppDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(extensionStored.timeIntervalSince1970, extensionDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testTimestampPersistsAcrossInstances() throws {
        // given - share one backing store to simulate separate instances of the same target
        let defaults = makeTestUserDefaults()
        let date = Date()
        let firstManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: defaults
        )
        firstManager.update(to: date)

        // when
        let secondManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: defaults
        )

        // then
        let stored = try XCTUnwrap(secondManager.lastTimestamp)
        XCTAssertEqual(stored.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetOnlyAffectsOwnTarget() throws {
        // given
        let defaults = makeTestUserDefaults()
        let mainAppManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: defaults
        )
        let extensionManager = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.notificationExtension,
            userDefaults: defaults
        )

        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)

        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)

        // when
        mainAppManager.reset()

        // then
        XCTAssertNil(mainAppManager.lastTimestamp)
        let extensionStored = try XCTUnwrap(extensionManager.lastTimestamp)
        XCTAssertEqual(extensionStored.timeIntervalSince1970, extensionDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUpdateOverwritesPreviousTimestamp() throws {
        // given
        let sut = CoreDataHistoryTimestampManager(
            target: HistoryTestAuthors.mainApp,
            userDefaults: makeTestUserDefaults()
        )
        let firstDate = Date()
        let secondDate = Date().addingTimeInterval(500)

        // when
        sut.update(to: firstDate)
        sut.update(to: secondDate)

        // then
        let stored = try XCTUnwrap(sut.lastTimestamp)
        XCTAssertEqual(stored.timeIntervalSince1970, secondDate.timeIntervalSince1970, accuracy: 0.001)
    }
}
