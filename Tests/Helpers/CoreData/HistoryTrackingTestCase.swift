import XCTest
import CoreData
@testable import Operation_iOS

/// Shared base class for tests that exercise Core Data persistent history tracking.
///
/// Centralises the boilerplate that was previously copy-pasted across every history test:
/// per-test unique database isolation, service/repository wiring, context helpers, and
/// cross-author save helpers with automatic teardown.
///
/// Design goals:
///  - Per-test ``databaseName`` derived from ``UUID`` — no shared on-disk state between tests.
///  - Trailing cleanup registered via ``addTeardownBlock``, so resources are released even
///    when an assertion fails mid-test (which bare inline ``try? service.close()`` does not do).
///  - Tight timeouts (5 s) on Core-Data-only work so hangs surface as failures quickly;
///    ``Constants/expectationDuration`` (60 s) is reserved for network-bearing tests.
open class HistoryTrackingTestCase: XCTestCase {

    /// Reasonable timeout for local Core Data operations. Anything slower than this is almost
    /// certainly a hang, so a short timeout keeps CI honest.
    public static let coreDataTimeout: TimeInterval = 5

    /// Placeholder target injected into the main service's history-tracking config so the
    /// built-in auto-cleaner never fires during tests. The cleaner requires every configured
    /// target to have a persisted timestamp before deleting history; this one never writes,
    /// so `lastCommonTransactionTimestamp` returns nil and raw history survives long enough
    /// for tests to inspect it. The service's observer still merges and re-posts normally.
    public static let phantomCleanerTarget = "history-tests.phantom-target"

    public private(set) var databaseName: String!
    public private(set) var sharedContainerName: String!
    public private(set) var databaseService: CoreDataServiceProtocol!
    public private(set) var repository: CoreDataRepository<FeedData, CDFeed>!
    public let operationQueue = OperationQueue()

    override open func setUp() {
        super.setUp()

        databaseName = uniqueDatabaseName()
        // Per-test UserDefaults suite so timestamp state cannot leak between runs of the
        // same author across tests.
        sharedContainerName = "HistoryTrackingTests.\(UUID().uuidString)"

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: databaseName,
            transactionAuthor: HistoryTestAuthors.defaultTest,
            targets: [HistoryTestAuthors.defaultTest, Self.phantomCleanerTarget],
            sharedContainerName: sharedContainerName
        )
        databaseService = CoreDataService(configuration: configuration)
        repository = Self.makeFeedRepository(for: databaseService)
    }

    override open func tearDown() {
        try? databaseService?.close()
        try? databaseService?.drop()
        if let suite = sharedContainerName {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        databaseService = nil
        repository = nil
        databaseName = nil
        sharedContainerName = nil

        super.tearDown()
    }

    /// Returns a database name unique to the current test method, ensuring on-disk isolation.
    public func uniqueDatabaseName(
        prefix: String = "HistoryTrackingTests",
        function: StaticString = #function
    ) -> String {
        "\(prefix).\(type(of: self)).\(function).\(UUID().uuidString)"
    }

    /// Creates a repository wired to the given service, using the same mapper/sort as the
    /// per-test default so cross-author tests behave consistently.
    public static func makeFeedRepository(
        for service: CoreDataServiceProtocol
    ) -> CoreDataRepository<FeedData, CDFeed> {
        let sortDescriptor = NSSortDescriptor(key: FeedData.CodingKeys.name.rawValue, ascending: false)
        let mapper = AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>())
        return CoreDataRepository(
            databaseService: service,
            mapper: mapper,
            filter: nil,
            sortDescriptors: [sortDescriptor]
        )
    }

    /// Spins up a second service writing to the same underlying database under a different
    /// transaction author, plus a matching repository. Registers teardown automatically so
    /// the caller never has to remember ``try? close()``.
    ///
    /// - Returns: tuple of (service, repository) using the given author.
    public func makeOtherAuthorServiceAndRepository(
        author: String = HistoryTestAuthors.otherProcess,
        sharedContainerName: String? = nil
    ) -> (service: CoreDataServiceProtocol, repository: CoreDataRepository<FeedData, CDFeed>) {
        let suite = sharedContainerName ?? self.sharedContainerName!
        let config = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: databaseName,
            transactionAuthor: author,
            sharedContainerName: suite
        )
        let service = CoreDataService(configuration: config)
        let repo = Self.makeFeedRepository(for: service)

        addTeardownBlock {
            try? service.close()
        }

        return (service, repo)
    }

    /// Runs ``body`` on a managed object context, synchronously waiting for completion.
    /// Fails the test (not crashes) if the service refuses to hand out a context or the
    /// body throws.
    public func onDatabaseContext(
        timeout: TimeInterval = coreDataTimeout,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping (NSManagedObjectContext) throws -> Void
    ) {
        let expectation = expectation(description: "database context ready")

        databaseService.performAsync { context, error in
            defer { expectation.fulfill() }
            guard let context else {
                XCTFail(
                    "Failed to get managed object context: \(String(describing: error))",
                    file: file,
                    line: line
                )
                return
            }
            do {
                try body(context)
            } catch {
                XCTFail("Context block threw: \(error)", file: file, line: line)
            }
        }

        wait(for: [expectation], timeout: timeout)
    }

    /// Saves entities via the given repository and waits for the operation to complete.
    @discardableResult
    public func save(
        _ feeds: [FeedData],
        using repository: CoreDataRepository<FeedData, CDFeed>? = nil,
        timeout: TimeInterval = coreDataTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [FeedData] {
        let repo = repository ?? self.repository!
        let expectation = expectation(description: "save \(feeds.count) feeds")

        let operation = repo.saveOperation({ feeds }, { [] })
        operation.completionBlock = { expectation.fulfill() }
        operationQueue.addOperation(operation)

        wait(for: [expectation], timeout: timeout)

        if case let .failure(operationError) = operation.result {
            XCTFail("Save failed: \(operationError)", file: file, line: line)
        }

        return feeds
    }

    /// Generates ``count`` random feeds in the default domain.
    public func makeRandomFeeds(_ count: Int) -> [FeedData] {
        (0..<count).map { _ in createRandomFeed(in: .default) }
    }

    /// Fetches ALL persistent-history transactions since the distant past, bypassing the
    /// author filter in ``CoreDataHistoryFetcher``. Used by tests that need to assert about
    /// raw history state (e.g. cleaner tests verifying deletion).
    public func fetchAllHistory(
        context: NSManagedObjectContext
    ) throws -> [NSPersistentHistoryTransaction] {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
        guard
            let result = try context.execute(request) as? NSPersistentHistoryResult,
            let transactions = result.result as? [NSPersistentHistoryTransaction]
        else {
            return []
        }
        return transactions
    }
}
