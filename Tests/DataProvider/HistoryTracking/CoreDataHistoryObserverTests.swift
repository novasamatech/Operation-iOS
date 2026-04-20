import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryObserverTests: XCTestCase {

    private var databaseService: CoreDataServiceProtocol!
    private var repository: CoreDataRepository<FeedData, CDFeed>!
    private let operationQueue = OperationQueue()

    override func setUp() {
        super.setUp()

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryObserverTests"
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

    func testObserverProcessesRemoteChanges() {
        // given - create a second service with a different author but same database
        let otherAuthorConfig = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryObserverTests",
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

        let didSaveExpectation = XCTestExpectation(description: "didSave notification posted")
        let saveExpectation = XCTestExpectation(description: "Save data from other author")
        let contextExpectation = XCTestExpectation(description: "Context ready")

        // when - set up observer on main service context, then insert data from other author
        databaseService.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                contextExpectation.fulfill()
                return
            }

            // Listen for didSave notifications that the observer re-posts after merging
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: context,
                queue: nil
            ) { _ in
                didSaveExpectation.fulfill()
            }

            contextExpectation.fulfill()
        }

        wait(for: [contextExpectation], timeout: Constants.expectationDuration)

        // Insert data from a different author to trigger remote change
        let feeds = (0..<3).map { _ in createRandomFeed(in: .default) }
        let operation = otherRepository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)

        wait(for: [saveExpectation], timeout: Constants.expectationDuration)

        // then - observer should process the remote change and re-post as didSave
        wait(for: [didSaveExpectation], timeout: Constants.expectationDuration)

        // Cleanup
        try? otherAuthorService.close()
    }

    func testObserverUpdatesTimestampAfterProcessing() {
        // given - unique shared-container name per test run; CoreDataService will build
        // its own manager from this name, so we schedule teardown of the backing suite.
        let sharedSuiteName = "HistoryObserverTimestampTests.\(UUID().uuidString)"
        let sharedDefaults = UserDefaults(suiteName: sharedSuiteName)!
        addTeardownBlock {
            sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        }

        let transactionAuthor = "timestamp_test_target"

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryObserverTimestampTests",
            transactionAuthor: transactionAuthor,
            sharedContainerName: sharedSuiteName
        )
        let service = CoreDataService(configuration: configuration)

        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        let mapper = AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>())

        let otherAuthorConfig = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "HistoryObserverTimestampTests",
            transactionAuthor: "other_process"
        )
        let otherAuthorService = CoreDataService(configuration: otherAuthorConfig)
        let otherRepository = CoreDataRepository<FeedData, CDFeed>(
            databaseService: otherAuthorService,
            mapper: mapper,
            filter: nil,
            sortDescriptors: [sortDescriptor]
        )

        let timestampManager = CoreDataHistoryTimestampManager(
            target: transactionAuthor,
            userDefaults: sharedDefaults
        )

        // Verify no timestamp initially
        XCTAssertNil(timestampManager.lastTimestamp)

        let contextExpectation = XCTestExpectation(description: "Context ready")
        let saveExpectation = XCTestExpectation(description: "Save data")
        let processExpectation = XCTestExpectation(description: "History processed")

        // when - trigger service setup (creates internal observer), then insert remote data
        service.performAsync { context, error in
            guard let context else {
                XCTFail("Failed to get context: \(String(describing: error))")
                contextExpectation.fulfill()
                return
            }

            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: context,
                queue: nil
            ) { _ in
                processExpectation.fulfill()
            }

            contextExpectation.fulfill()
        }

        wait(for: [contextExpectation], timeout: Constants.expectationDuration)

        // Insert data from another author
        let feeds = (0..<2).map { _ in createRandomFeed(in: .default) }
        let operation = otherRepository.saveOperation({ feeds }, { [] })
        operation.completionBlock = { saveExpectation.fulfill() }
        operationQueue.addOperation(operation)

        wait(for: [saveExpectation], timeout: Constants.expectationDuration)
        wait(for: [processExpectation], timeout: Constants.expectationDuration)

        // then - service's internal observer should have updated the timestamp
        XCTAssertNotNil(timestampManager.lastTimestamp, "Timestamp should be set after processing history")

        // Cleanup
        try? otherAuthorService.close()
        try? service.close()
        try? service.drop()
    }
}
