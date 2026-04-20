import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryCleanerTests: XCTestCase {

    private var databaseService: CoreDataServiceProtocol!

    override func setUp() {
        super.setUp()

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryCleanerTests"
        )
        databaseService = CoreDataService(configuration: configuration)
    }

    override func tearDown() {
        try? databaseService.close()
        try? databaseService.drop()
        databaseService = nil

        super.tearDown()
    }

    // MARK: - Tests

    func testCleanDoesNothingWhenNoTimestampsExist() {
        // given
        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [
                InMemoryHistoryTimestampManager(),
                InMemoryHistoryTimestampManager()
            ]
        )

        let expectation = XCTestExpectation()

        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }

            // when/then - should not throw
            do {
                try cleaner.clean(context: context)
                expectation.fulfill()
            } catch {
                XCTFail("Cleaner threw unexpected error: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)
    }

    func testCleanDoesNothingWhenOnlyOneTargetHasTimestamp() {
        // given
        let mainAppManager = InMemoryHistoryTimestampManager(initial: Date())
        let extensionManager = InMemoryHistoryTimestampManager()

        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [mainAppManager, extensionManager]
        )

        let expectation = XCTestExpectation()

        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }

            // when/then - should not throw and should not affect timestamps when only one target has a value
            do {
                try cleaner.clean(context: context)

                // Verify that the timestamp wasn't cleared (since not all targets have timestamps)
                XCTAssertNotNil(mainAppManager.lastTimestamp)
                expectation.fulfill()
            } catch {
                XCTFail("Cleaner threw unexpected error: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)
    }

    func testCleanSuccessfullyDeletesHistoryWhenAllTargetsHaveTimestamps() {
        // given - set timestamps for all targets
        let cleanupDate = Date()

        let mainAppManager = InMemoryHistoryTimestampManager(initial: cleanupDate)
        // Extension processed slightly later
        let extensionManager = InMemoryHistoryTimestampManager(initial: cleanupDate.addingTimeInterval(10))

        let cleaner = CoreDataHistoryCleaner(
            timestampManagers: [mainAppManager, extensionManager]
        )

        let expectation = XCTestExpectation()

        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }

            // when
            do {
                try cleaner.clean(context: context)

                // then - timestamps should be preserved after cleanup
                // (they represent "how far processed", not "how far cleaned")
                XCTAssertNotNil(mainAppManager.lastTimestamp, "Main app timestamp should be preserved after cleanup")
                XCTAssertNotNil(extensionManager.lastTimestamp, "Extension timestamp should be preserved after cleanup")
                expectation.fulfill()
            } catch {
                XCTFail("Cleaner threw unexpected error: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: Constants.expectationDuration)
    }
}
