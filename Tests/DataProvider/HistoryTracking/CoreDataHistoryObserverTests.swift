import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryObserverTests: XCTestCase {
    
    private var userDefaults: UserDefaults!
    private var databaseService: CoreDataServiceProtocol!
    
    override func setUp() {
        super.setUp()
        
        userDefaults = UserDefaults(suiteName: "CoreDataHistoryObserverTests")!
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryObserverTests")
        
        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryObserverTests"
        )
        databaseService = CoreDataService(configuration: configuration)
    }
    
    override func tearDown() {
        userDefaults.removePersistentDomain(forName: "CoreDataHistoryObserverTests")
        userDefaults = nil
        
        try? databaseService.close()
        try? databaseService.drop()
        databaseService = nil
        
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func testObserverCallsFetcherOnRemoteChange() {
        // given
        let mockFetcher = MockHistoryFetcher()
        let mockMerger = MockHistoryMerger()
        let mockCleaner = MockHistoryCleaner()
        
        let observer = CoreDataHistoryObserver(
            service: databaseService,
            target: .mainApp,
            userDefaults: userDefaults,
            fetcher: mockFetcher,
            merger: mockMerger,
            cleaner: mockCleaner
        )
        
        let startExpectation = XCTestExpectation(description: "Observer started")
        let fetchExpectation = XCTestExpectation(description: "Fetcher called")
        
        mockFetcher.onFetchCalled = {
            fetchExpectation.fulfill()
        }
        
        observer.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        
        wait(for: [startExpectation], timeout: Constants.expectationDuration)
        
        // when - trigger remote change
        databaseService.performAsync { context, _ in
            guard let coordinator = context?.persistentStoreCoordinator else { return }
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }
        
        // then
        wait(for: [fetchExpectation], timeout: Constants.expectationDuration)
        XCTAssertTrue(mockFetcher.fetchCalled, "Fetcher should be called on remote change")
        
        observer.stopObserving()
    }
    
    func testObserverCallsMergerWhenTransactionsExist() {
        // given
        let mockFetcher = MockHistoryFetcher()
        let mockMerger = MockHistoryMerger()
        let mockCleaner = MockHistoryCleaner()
        
        // Simulate fetcher returning transactions
        mockFetcher.transactionsToReturn = [MockPersistentHistoryTransaction()]
        
        let observer = CoreDataHistoryObserver(
            service: databaseService,
            target: .mainApp,
            userDefaults: userDefaults,
            fetcher: mockFetcher,
            merger: mockMerger,
            cleaner: mockCleaner
        )
        
        let startExpectation = XCTestExpectation(description: "Observer started")
        let mergeExpectation = XCTestExpectation(description: "Merger called")
        
        mockMerger.onMergeCalled = {
            mergeExpectation.fulfill()
        }
        
        observer.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        
        wait(for: [startExpectation], timeout: Constants.expectationDuration)
        
        // when
        databaseService.performAsync { context, _ in
            guard let coordinator = context?.persistentStoreCoordinator else { return }
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }
        
        // then
        wait(for: [mergeExpectation], timeout: Constants.expectationDuration)
        XCTAssertTrue(mockMerger.mergeCalled, "Merger should be called when transactions exist")
        
        observer.stopObserving()
    }
    
    func testObserverDoesNotCallMergerWhenNoTransactions() {
        // given
        let mockFetcher = MockHistoryFetcher()
        let mockMerger = MockHistoryMerger()
        let mockCleaner = MockHistoryCleaner()
        
        // Fetcher returns empty array
        mockFetcher.transactionsToReturn = []
        
        let observer = CoreDataHistoryObserver(
            service: databaseService,
            target: .mainApp,
            userDefaults: userDefaults,
            fetcher: mockFetcher,
            merger: mockMerger,
            cleaner: mockCleaner
        )
        
        let startExpectation = XCTestExpectation(description: "Observer started")
        let fetchExpectation = XCTestExpectation(description: "Fetcher called")
        
        mockFetcher.onFetchCalled = {
            fetchExpectation.fulfill()
        }
        
        observer.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        
        wait(for: [startExpectation], timeout: Constants.expectationDuration)
        
        // when
        databaseService.performAsync { context, _ in
            guard let coordinator = context?.persistentStoreCoordinator else { return }
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }
        
        wait(for: [fetchExpectation], timeout: Constants.expectationDuration)
        
        // Allow time for merger to be called (if it would be)
        let waitExpectation = XCTestExpectation(description: "Wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            waitExpectation.fulfill()
        }
        wait(for: [waitExpectation], timeout: Constants.expectationDuration)
        
        // then
        XCTAssertFalse(mockMerger.mergeCalled, "Merger should not be called when no transactions")
        
        observer.stopObserving()
    }
    
    func testObserverCallsCleanerAfterMerging() {
        // given
        let mockFetcher = MockHistoryFetcher()
        let mockMerger = MockHistoryMerger()
        let mockCleaner = MockHistoryCleaner()
        
        mockFetcher.transactionsToReturn = [MockPersistentHistoryTransaction()]
        
        let observer = CoreDataHistoryObserver(
            service: databaseService,
            target: .mainApp,
            userDefaults: userDefaults,
            fetcher: mockFetcher,
            merger: mockMerger,
            cleaner: mockCleaner
        )
        
        let startExpectation = XCTestExpectation(description: "Observer started")
        let cleanExpectation = XCTestExpectation(description: "Cleaner called")
        
        mockCleaner.onCleanCalled = {
            cleanExpectation.fulfill()
        }
        
        observer.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        
        wait(for: [startExpectation], timeout: Constants.expectationDuration)
        
        // when
        databaseService.performAsync { context, _ in
            guard let coordinator = context?.persistentStoreCoordinator else { return }
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }
        
        // then
        wait(for: [cleanExpectation], timeout: Constants.expectationDuration)
        XCTAssertTrue(mockCleaner.cleanCalled, "Cleaner should be called after merging")
        
        observer.stopObserving()
    }
    
    func testObserverNotifiesDelegateWithMergedNotifications() {
        // given
        let mockFetcher = MockHistoryFetcher()
        let mockMerger = MockHistoryMerger()
        let mockCleaner = MockHistoryCleaner()
        let mockDelegate = MockHistoryObserverDelegate()
        
        mockFetcher.transactionsToReturn = [MockPersistentHistoryTransaction()]
        
        let testNotification = Notification(name: .NSManagedObjectContextDidSave)
        mockMerger.notificationsToReturn = [testNotification]
        
        let observer = CoreDataHistoryObserver(
            service: databaseService,
            target: .mainApp,
            userDefaults: userDefaults,
            fetcher: mockFetcher,
            merger: mockMerger,
            cleaner: mockCleaner
        )
        observer.delegate = mockDelegate
        
        let startExpectation = XCTestExpectation(description: "Observer started")
        let delegateExpectation = XCTestExpectation(description: "Delegate called")
        
        mockDelegate.onNotificationsReceived = {
            delegateExpectation.fulfill()
        }
        
        observer.startObserving()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            startExpectation.fulfill()
        }
        
        wait(for: [startExpectation], timeout: Constants.expectationDuration)
        
        // when
        databaseService.performAsync { context, _ in
            guard let coordinator = context?.persistentStoreCoordinator else { return }
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: coordinator
            )
        }
        
        // then
        wait(for: [delegateExpectation], timeout: Constants.expectationDuration)
        XCTAssertEqual(mockDelegate.receivedNotifications.count, 1)
        XCTAssertEqual(mockDelegate.receivedNotifications.first?.count, 1)
        
        observer.stopObserving()
    }
}

// MARK: - Mocks

private final class MockHistoryFetcher: CoreDataHistoryFetching {
    var fetchCalled = false
    var transactionsToReturn: [NSPersistentHistoryTransaction] = []
    var onFetchCalled: (() -> Void)?
    
    func fetch(context: NSManagedObjectContext, fromDate: Date) throws -> [NSPersistentHistoryTransaction] {
        fetchCalled = true
        onFetchCalled?()
        return transactionsToReturn
    }
}

private final class MockHistoryMerger: CoreDataHistoryMerging {
    var mergeCalled = false
    var notificationsToReturn: [Notification] = []
    var onMergeCalled: (() -> Void)?
    
    func merge(context: NSManagedObjectContext, transactions: [NSPersistentHistoryTransaction]) -> [Notification] {
        mergeCalled = true
        onMergeCalled?()
        return notificationsToReturn
    }
}

private final class MockHistoryCleaner: CoreDataHistoryCleaning {
    var cleanCalled = false
    var onCleanCalled: (() -> Void)?
    
    func clean(context: NSManagedObjectContext) throws {
        cleanCalled = true
        onCleanCalled?()
    }
}

private final class MockHistoryObserverDelegate: CoreDataHistoryObserverDelegate {
    var receivedNotifications: [[Notification]] = []
    var onNotificationsReceived: (() -> Void)?
    
    func persistentHistoryObserver(
        _ observer: CoreDataHistoryObserver,
        didReceiveNotifications notifications: [Notification]
    ) {
        receivedNotifications.append(notifications)
        onNotificationsReceived?()
    }
}
private final class MockPersistentHistoryTransaction: NSPersistentHistoryTransaction {
    override var timestamp: Date {
        Date()
    }
}

