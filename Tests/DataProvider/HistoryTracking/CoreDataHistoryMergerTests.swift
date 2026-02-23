import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryMergerTests: XCTestCase {
    
    private var databaseService: CoreDataServiceProtocol!
    private var repository: CoreDataRepository<FeedData, CDFeed>!
    private let operationQueue = OperationQueue()
    
    override func setUp() {
        super.setUp()
        
        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryMergerTests"
        )
        databaseService = CoreDataService(configuration: configuration)
        
        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        let mapper = AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>())
        repository = CoreDataRepository(
            databaseService: databaseService,
            mapper: mapper,
            filter: nil,
            sortDescriptors: [sortDescriptor]
        )
    }
    
    override func tearDown() {
        try? databaseService.close()
        try? databaseService.drop()
        databaseService = nil
        repository = nil
        
        super.tearDown()
    }
    
    // MARK: - Tests
    
    func testMergeReturnsEmptyArrayWhenNoTransactions() {
        // given
        let expectation = XCTestExpectation()
        
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }
            
            let merger = CoreDataHistoryMerger()
            
            // when
            let notifications = merger.merge(context: context, transactions: [])
            
            // then
            XCTAssertTrue(notifications.isEmpty)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: Constants.expectationDuration)
    }
    
    func testMergeReturnsNotificationsForEachTransaction() {
        // given - create a second service with a different author but same database
        let otherAuthorConfig = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryMergerTests",
            transactionAuthor: "other_process"
        )
        let otherAuthorService = CoreDataService(configuration: otherAuthorConfig)
        
        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        let mapper = AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>())
        let otherRepository = CoreDataRepository<FeedData, CDFeed>(
            databaseService: otherAuthorService,
            mapper: mapper,
            filter: nil,
            sortDescriptors: [sortDescriptor]
        )
        
        let saveExpectation = XCTestExpectation(description: "Save data")
        let mergeExpectation = XCTestExpectation(description: "Merge transactions")
        let fetchDate = Date()
        
        // Insert data using the other author's service
        let feeds = (0..<3).map { _ in createRandomFeed(in: .default) }
        let operation = otherRepository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)
        
        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        
        // when - fetch transactions from the main service and merge them
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                mergeExpectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: fetchDate)
                XCTAssertFalse(transactions.isEmpty, "Should have transactions from other author")
                
                let merger = CoreDataHistoryMerger()
                
                // when
                let notifications = merger.merge(context: context, transactions: transactions)
                
                // then - should have one notification per transaction
                XCTAssertEqual(notifications.count, transactions.count)
                mergeExpectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                mergeExpectation.fulfill()
            }
        }
        
        wait(for: [mergeExpectation], timeout: Constants.expectationDuration)
        
        // Cleanup
        try? otherAuthorService.close()
    }
    
    func testMergeNotificationsContainUserInfo() {
        // given - create a second service with a different author but same database
        let otherAuthorConfig = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryMergerTests",
            transactionAuthor: "other_process"
        )
        let otherAuthorService = CoreDataService(configuration: otherAuthorConfig)
        
        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        let mapper = AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>())
        let otherRepository = CoreDataRepository<FeedData, CDFeed>(
            databaseService: otherAuthorService,
            mapper: mapper,
            filter: nil,
            sortDescriptors: [sortDescriptor]
        )
        
        let saveExpectation = XCTestExpectation(description: "Save data")
        let mergeExpectation = XCTestExpectation(description: "Merge transactions")
        let fetchDate = Date()
        
        // Insert data using the other author's service
        let feeds = (0..<2).map { _ in createRandomFeed(in: .default) }
        let operation = otherRepository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)
        
        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        
        // when
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                mergeExpectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: fetchDate)
                XCTAssertFalse(transactions.isEmpty, "Should have transactions from other author")
                
                let merger = CoreDataHistoryMerger()
                let notifications = merger.merge(context: context, transactions: transactions)
                
                // then - notifications should contain userInfo with object IDs
                XCTAssertFalse(notifications.isEmpty)
                notifications.forEach { XCTAssertNotNil($0.userInfo, "Notification should have userInfo") }
                mergeExpectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                mergeExpectation.fulfill()
            }
        }
        
        wait(for: [mergeExpectation], timeout: Constants.expectationDuration)
        
        // Cleanup
        try? otherAuthorService.close()
    }
}
