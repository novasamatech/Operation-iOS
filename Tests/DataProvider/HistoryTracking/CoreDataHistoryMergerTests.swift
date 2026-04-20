import XCTest
import CoreData
@testable import Operation_iOS
#if SWIFT_PACKAGE
import Helpers
#endif

final class CoreDataHistoryMergerTests: HistoryTrackingTestCase {

    // MARK: - Tests

    /// Merger is stateless for the empty path; no need to spin up a full Core Data stack.
    func testMergeReturnsEmptyArrayWhenNoTransactions() {
        // given
        let merger = CoreDataHistoryMerger()
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)

        // when
        let notifications = merger.merge(context: context, transactions: [])

        // then
        XCTAssertTrue(notifications.isEmpty)
    }

    func testMergeReturnsOneNotificationPerTransaction() {
        // given - writes from another author produce one history transaction per save
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        let fetchDate = Date().addingTimeInterval(-1)
        let feedCount = 3

        for _ in 0..<feedCount {
            save(makeRandomFeeds(1), using: otherRepository)
        }

        // when
        onDatabaseContext { context in
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: fetchDate)
            XCTAssertEqual(
                transactions.count,
                feedCount,
                "Expected one transaction per save"
            )

            let notifications = CoreDataHistoryMerger().merge(context: context, transactions: transactions)

            // then
            XCTAssertEqual(notifications.count, transactions.count)
        }
    }

    func testMergedNotificationsCarryObjectIDUserInfo() {
        // given
        let (_, otherRepository) = makeOtherAuthorServiceAndRepository()
        let fetchDate = Date()
        save(makeRandomFeeds(2), using: otherRepository)

        // when
        onDatabaseContext { context in
            let transactions = try CoreDataHistoryFetcher().fetch(context: context, fromDate: fetchDate)
            XCTAssertFalse(transactions.isEmpty)

            let notifications = CoreDataHistoryMerger().merge(context: context, transactions: transactions)

            // then - every notification should carry the object-ID userInfo payload, which is
            // what `CoreDataContextObservable` downstream relies on.
            XCTAssertFalse(notifications.isEmpty)
            for notification in notifications {
                let userInfo = try XCTUnwrap(notification.userInfo)
                XCTAssertFalse(userInfo.isEmpty, "Object-ID notification should carry keys")
            }
        }
    }
}
