import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryCleanerTests: XCTestCase {
    
    private var userDefaults: UserDefaults!
    private var databaseService: CoreDataServiceProtocol!
    
    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "CoreDataHistoryCleanerTests")!
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryCleanerTests")
        
        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryCleanerTests"
        )
        databaseService = CoreDataService(configuration: configuration)
    }
    
    override func tearDown() {
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryCleanerTests")
        userDefaults = nil
        
        try? databaseService.close()
        try? databaseService.drop()
        databaseService = nil
        
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func testCleanDoesNothingWhenNoTimestampsExist() {
        // given
        let expectation = XCTestExpectation()
        
        databaseService.performAsync { [weak self] context, error in
            guard let self, let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }
            
            let cleaner = CoreDataHistoryCleaner(
                targets: [CoreDataHistoryTarget.mainApp, "notification-extension"],
                userDefaults: self.userDefaults
            )
            
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
        let mainAppManager = CoreDataHistoryTimestampManager(target: CoreDataHistoryTarget.mainApp, userDefaults: userDefaults)
        mainAppManager.update(to: Date())
        
        let expectation = XCTestExpectation()
        
        databaseService.performAsync { [weak self] context, error in
            guard let self, let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }
            
            let cleaner = CoreDataHistoryCleaner(
                targets: [CoreDataHistoryTarget.mainApp, "notification-extension"],
                userDefaults: self.userDefaults
            )
            
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
        
        let mainAppManager = CoreDataHistoryTimestampManager(target: CoreDataHistoryTarget.mainApp, userDefaults: userDefaults)
        let extensionManager = CoreDataHistoryTimestampManager(target: "notification-extension", userDefaults: userDefaults)
        
        mainAppManager.update(to: cleanupDate)
        extensionManager.update(to: cleanupDate.addingTimeInterval(10)) // Extension processed slightly later
        
        let expectation = XCTestExpectation()
        
        databaseService.performAsync { [weak self] context, error in
            guard let self, let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }
            
            let cleaner = CoreDataHistoryCleaner(
                targets: [CoreDataHistoryTarget.mainApp, "notification-extension"],
                userDefaults: self.userDefaults
            )
            
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
