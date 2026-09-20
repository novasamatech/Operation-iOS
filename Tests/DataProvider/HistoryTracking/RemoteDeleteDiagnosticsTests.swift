import XCTest
import CoreData
import SDKLogger
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/// Remote deletes reach an observable only through persistent-history tombstones, and Core Data writes an
/// attribute into a tombstone only when the model marks it ``preserveAfterDeletion``. Without it the delete
/// is dropped in silence, so the library says something instead.
final class RemoteDeleteDiagnosticsTests: XCTestCase {
    private var service: CoreDataService!
    private var logger: SpyLogger!

    override func setUp() {
        super.setUp()

        logger = SpyLogger()

        let configuration = CoreDataServiceConfiguration.createConfigurationWithHistoryTracking(
            databaseName: "RemoteDeleteDiagnostics-\(UUID().uuidString)",
            sharedContainerName: "RemoteDeleteDiagnostics.\(UUID().uuidString)",
            logger: logger
        )

        service = CoreDataService(configuration: configuration)
    }

    override func tearDown() {
        try? service.close()
        try? service.drop()
        service = nil
        logger = nil

        super.tearDown()
    }

    /// ``CDMessage.identifier`` is not preserved after deletion, so this observable can never receive a
    /// remote delete. Starting it must say so.
    func testStartWarnsWhenIdentifierIsNotPreserved() {
        let observable = CoreDataContextObservable(
            service: service,
            mapper: AnyCoreDataMapper(CodableCoreDataMapper<MessageData, CDMessage>()),
            predicate: { _ in true }
        )

        let started = expectation(description: "observable started")
        observable.start { _ in started.fulfill() }
        wait(for: [started], timeout: Constants.expectationDuration)

        XCTAssertTrue(
            logger.warnings.contains { $0.contains("CDMessage") && $0.contains("identifier") },
            "expected a warning naming the entity and attribute, got \(logger.warnings)"
        )
    }

    /// ``CDFeed.identifier`` is preserved, so the same start must stay quiet — a diagnostic that fires for
    /// correctly configured models is worse than none.
    func testStartStaysQuietWhenIdentifierIsPreserved() {
        let observable = CoreDataContextObservable(
            service: service,
            mapper: AnyCoreDataMapper(CodableCoreDataMapper<FeedData, CDFeed>()),
            predicate: { _ in true }
        )

        let started = expectation(description: "observable started")
        observable.start { _ in started.fulfill() }
        wait(for: [started], timeout: Constants.expectationDuration)

        XCTAssertTrue(logger.warnings.isEmpty, "unexpected warnings: \(logger.warnings)")
    }
}
