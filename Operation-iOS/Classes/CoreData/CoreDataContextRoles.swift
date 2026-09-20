import Foundation
import CoreData

/**
 *  The contexts a service hands out, resolved once at setup. In ```.serial``` mode every role is the
 *  same context and there is no reader queue; in ```.concurrent``` mode the writer and observer are
 *  siblings on the coordinator and readers are created per operation on the reader queue.
 */

struct CoreDataContextRoles {
    let coordinator: NSPersistentStoreCoordinator
    let writer: NSManagedObjectContext
    let observer: NSManagedObjectContext
    let readerQueue: OperationQueue?

    /// Counts the reads currently holding the store. Shared by every copy of these roles and replaced
    /// when the store is reopened, so it only ever tracks reads against this coordinator.
    let readerActivity = CoreDataReaderActivity()

    var allContexts: [NSManagedObjectContext] {
        writer === observer ? [writer] : [writer, observer]
    }

    static func make(
        coordinator: NSPersistentStoreCoordinator,
        mode: CoreDataConcurrencyMode,
        historyTracking: CoreDataHistoryTrackingSettings?
    ) throws -> CoreDataContextRoles {
        let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        writer.persistentStoreCoordinator = coordinator

        if let historyTracking {
            writer.transactionAuthor = historyTracking.transactionAuthor
            writer.name = historyTracking.transactionAuthor
            writer.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        }

        switch mode {
        case .serial:
            return CoreDataContextRoles(coordinator: coordinator, writer: writer, observer: writer, readerQueue: nil)

        case .concurrent(let readerConcurrency):
            guard readerConcurrency >= 1 else {
                throw CoreDataServiceError.invalidReaderConcurrency(readerConcurrency)
            }

            let observer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            observer.persistentStoreCoordinator = coordinator
            observer.name = "io.novasama.coredata.observer"
            observer.automaticallyMergesChangesFromParent = true
            observer.shouldDeleteInaccessibleFaults = true

            let readerQueue = OperationQueue()
            readerQueue.name = "io.novasama.coredata.readers"
            readerQueue.maxConcurrentOperationCount = readerConcurrency
            readerQueue.qualityOfService = .userInitiated

            return CoreDataContextRoles(
                coordinator: coordinator,
                writer: writer,
                observer: observer,
                readerQueue: readerQueue
            )
        }
    }

    func makeReader() -> NSManagedObjectContext {
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.name = "io.novasama.coredata.reader"
        reader.undoManager = nil
        return reader
    }
}
