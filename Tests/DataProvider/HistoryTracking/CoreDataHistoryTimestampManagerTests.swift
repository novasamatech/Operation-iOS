import XCTest
@testable import Operation_iOS

final class CoreDataHistoryTimestampManagerTests: XCTestCase {
    
    private var userDefaults: UserDefaults!
    private var sut: CoreDataHistoryTimestampManager!
    
    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "CoreDataHistoryTimestampManagerTests")!
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryTimestampManagerTests")
    }
    
    override func tearDown() {
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryTimestampManagerTests")
        userDefaults = nil
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func testUpdateTimestampStoresValue() {
        // given
        sut = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        let date = Date()
        
        // when
        sut.update(to: date)
        
        // then
        XCTAssertNotNil(sut.lastTimestamp)
        XCTAssertEqual(sut.lastTimestamp!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
    
    func testResetRemovesTimestamp() {
        // given
        sut = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        let date = Date()
        sut.update(to: date)
        
        // when
        sut.reset()
        
        // then
        XCTAssertNil(sut.lastTimestamp)
    }
    
    func testDifferentTargetsHaveIndependentTimestamps() {
        // given
        let mainAppManager = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        let extensionManager = CoreDataHistoryTimestampManager(target: .notificationExtension, userDefaults: userDefaults)
        
        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)
        
        // when
        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)
        
        // then
        XCTAssertNotNil(mainAppManager.lastTimestamp)
        XCTAssertNotNil(extensionManager.lastTimestamp)
        XCTAssertEqual(mainAppManager.lastTimestamp!.timeIntervalSince1970, mainAppDate.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(extensionManager.lastTimestamp!.timeIntervalSince1970, extensionDate.timeIntervalSince1970, accuracy: 0.001)
    }
    
    func testTimestampPersistsAcrossInstances() {
        // given
        let date = Date()
        let firstManager = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        firstManager.update(to: date)
        
        // when
        let secondManager = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        
        // then
        XCTAssertNotNil(secondManager.lastTimestamp)
        XCTAssertEqual(secondManager.lastTimestamp!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
    
    func testResetOnlyAffectsOwnTarget() {
        // given
        let mainAppManager = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        let extensionManager = CoreDataHistoryTimestampManager(target: .notificationExtension, userDefaults: userDefaults)
        
        let mainAppDate = Date()
        let extensionDate = Date().addingTimeInterval(100)
        
        mainAppManager.update(to: mainAppDate)
        extensionManager.update(to: extensionDate)
        
        // when
        mainAppManager.reset()
        
        // then
        XCTAssertNil(mainAppManager.lastTimestamp)
        XCTAssertNotNil(extensionManager.lastTimestamp)
        XCTAssertEqual(extensionManager.lastTimestamp!.timeIntervalSince1970, extensionDate.timeIntervalSince1970, accuracy: 0.001)
    }
    
    func testUpdateOverwritesPreviousTimestamp() {
        // given
        sut = CoreDataHistoryTimestampManager(target: .mainApp, userDefaults: userDefaults)
        let firstDate = Date()
        let secondDate = Date().addingTimeInterval(500)
        
        // when
        sut.update(to: firstDate)
        sut.update(to: secondDate)
        
        // then
        XCTAssertNotNil(sut.lastTimestamp)
        XCTAssertEqual(sut.lastTimestamp!.timeIntervalSince1970, secondDate.timeIntervalSince1970, accuracy: 0.001)
    }
}
