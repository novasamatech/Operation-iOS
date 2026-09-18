import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/// A 2.x-shaped conformer that only knows ```performAsync```, ```close``` and ```drop```. The role entry
/// points must come from protocol defaults so such conformers keep compiling and keep working.
private final class LegacyCoreDataService: CoreDataServiceProtocol {
    private let inner: CoreDataService

    init(inner: CoreDataService) {
        self.inner = inner
    }

    var configuration: CoreDataServiceConfigurationProtocol { inner.configuration }

    func performAsync(block: @escaping CoreDataContextInvocationBlock) {
        inner.performAsync(block: block)
    }

    func close() throws { try inner.close() }
    func drop() throws { try inner.drop() }
}

final class CoreDataServiceProtocolDefaultsTests: XCTestCase {
    private struct TestError: Error {}

    private var service: LegacyCoreDataService!

    override func setUp() {
        super.setUp()

        let configuration = CoreDataServiceConfiguration.createDefaultConfigutation(
            with: Constants.defaultCoreDataModelName,
            databaseName: "ProtocolDefaults-\(UUID().uuidString)",
            incompatibleModelStrategy: .removeStore
        )
        service = LegacyCoreDataService(inner: CoreDataService(configuration: configuration))
    }

    override func tearDown() {
        try? service.close()
        try? service.drop()
        service = nil

        super.tearDown()
    }

    func testDefaultWriteSavesAndDefaultReadSeesIt() {
        let identifier = UUID().uuidString

        let written = expectation(description: "written")
        service.performWrite({ context in
            let feed = CDFeed(context: context)
            feed.identifier = identifier
            feed.name = "default"
            feed.status = "new"
        }, completion: { result in
            if case .failure(let error) = result {
                XCTFail("write failed with \(error)")
            }
            written.fulfill()
        })
        wait(for: [written], timeout: Constants.expectationDuration)

        XCTAssertEqual(count(identifier), 1)
    }

    func testDefaultWriteRollsBackWhenBlockThrows() {
        let identifier = UUID().uuidString

        let written = expectation(description: "written")
        service.performWrite({ context in
            let feed = CDFeed(context: context)
            feed.identifier = identifier
            feed.name = "default"
            feed.status = "new"
            throw TestError()
        }, completion: { result in
            guard case .failure = result else {
                return XCTFail("expected failure")
            }
            written.fulfill()
        })
        wait(for: [written], timeout: Constants.expectationDuration)

        XCTAssertEqual(count(identifier), 0)
    }

    func testDefaultObserveDeliversContext() {
        let observed = expectation(description: "observed")
        service.performObserve { context, error in
            XCTAssertNotNil(context)
            XCTAssertNil(error)
            observed.fulfill()
        }
        wait(for: [observed], timeout: Constants.expectationDuration)
    }

    func testDefaultWithObserverDeliversTheSameContextForBothRoles() {
        let delivered = expectation(description: "delivered")
        service.performWithObserver { writer, observer, error in
            XCTAssertNotNil(writer)
            XCTAssertTrue(writer === observer)
            XCTAssertNil(error)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: Constants.expectationDuration)
    }

    private func count(_ identifier: String) -> Int? {
        let read = expectation(description: "read")
        var count: Int?
        service.performRead({ context -> Int in
            let request = NSFetchRequest<CDFeed>(entityName: "CDFeed")
            request.predicate = NSPredicate(format: "identifier == %@", identifier)
            return try context.count(for: request)
        }, completion: { result in
            if case .success(let value) = result {
                count = value
            } else {
                XCTFail("read failed: \(result)")
            }
            read.fulfill()
        })
        wait(for: [read], timeout: Constants.expectationDuration)
        return count
    }
}
