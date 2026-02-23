import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryFetcherTests: XCTestCase {
    
    private var databaseService: CoreDataServiceProtocol!
    private var repository: CoreDataRepository<FeedData, CDFeed>!
    private let operationQueue = OperationQueue()
    
    override func setUp() {
        super.setUp()
        
        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryFetcherTests"
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
    
    func testFetchReturnsEmptyArrayWhenNoChanges() {
        // given
        let expectation = XCTestExpectation()
        
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                expectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            // when
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: Date())
                
                // then
                XCTAssertTrue(transactions.isEmpty)
                expectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: Constants.expectationDuration)
    }
    
    func testFetchFiltersOutOwnTransactions() {
        // given
        let saveExpectation = XCTestExpectation(description: "Save data")
        let fetchExpectation = XCTestExpectation(description: "Fetch history")
        let fetchDate = Date()
        
        // Insert data using the same context/author
        let feeds = (0..<3).map { _ in createRandomFeed(in: .default) }
        let operation = repository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)
        
        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        
        // when - fetch history after insert from the same context
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                fetchExpectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: fetchDate)
                
                // then - fetcher filters out own transactions (same author/context)
                // so we should get empty results when fetching our own changes
                XCTAssertTrue(transactions.isEmpty, "Fetcher should filter out own transactions")
                fetchExpectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                fetchExpectation.fulfill()
            }
        }
        
        wait(for: [fetchExpectation], timeout: Constants.expectationDuration)
    }
    
    func testFetchWithFutureDateReturnsNoTransactions() {
        // given
        let saveExpectation = XCTestExpectation(description: "Save data")
        let fetchExpectation = XCTestExpectation(description: "Fetch history")
        
        // Insert data first
        let feeds = (0..<3).map { _ in createRandomFeed(in: .default) }
        let operation = repository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)
        
        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        
        // when - fetch with future date
        let futureDate = Date().addingTimeInterval(3600)
        
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                fetchExpectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: futureDate)
                
                // then - should have no transactions since we're fetching from future
                XCTAssertTrue(transactions.isEmpty, "Should have no transactions when fetching from future date")
                fetchExpectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                fetchExpectation.fulfill()
            }
        }
        
        wait(for: [fetchExpectation], timeout: Constants.expectationDuration)
    }
    
    func testFetchReturnsTransactionsFromDifferentAuthor() {
        // given - create a second service with a different author but same database
        let otherAuthorConfig = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryFetcherTests",
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
        
        let saveExpectation = XCTestExpectation(description: "Save data from other author")
        let fetchExpectation = XCTestExpectation(description: "Fetch history")
        let fetchDate = Date()
        
        // Insert data using the other author's service
        let feeds = (0..<3).map { _ in createRandomFeed(in: .default) }
        let operation = otherRepository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)
        
        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        
        // when - fetch history from the main service (different author)
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                fetchExpectation.fulfill()
                return
            }
            
            let fetcher = CoreDataHistoryFetcher()
            
            do {
                let transactions = try fetcher.fetch(context: context, fromDate: fetchDate)
                
                // then - should have transactions from the other author
                XCTAssertFalse(transactions.isEmpty, "Should have transactions from different author")
                fetchExpectation.fulfill()
            } catch {
                XCTFail("Fetch threw unexpected error: \(error)")
                fetchExpectation.fulfill()
            }
        }
        
        wait(for: [fetchExpectation], timeout: Constants.expectationDuration)
        
        // Cleanup
        try? otherAuthorService.close()
    }
}
