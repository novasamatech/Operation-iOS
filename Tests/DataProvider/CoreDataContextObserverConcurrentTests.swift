import XCTest
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

/// The observable contract of ``CoreDataContextObserverTests`` against a service in
/// ``CoreDataConcurrencyMode/concurrent(readerConcurrency:)``.
final class CoreDataContextObserverConcurrentTests: CoreDataContextObserverTests {
    override class var facade: CoreDataRepositoryFacade { .concurrent }
}
