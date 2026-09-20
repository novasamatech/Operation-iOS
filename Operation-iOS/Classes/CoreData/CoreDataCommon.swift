import Foundation
import CoreData
import SDKLogger

/**
 *  Enum is defining possible strategies to handle situations
 *  when Core Data entity model is incompatible with persistent store.
 */

public enum IncompatibleModelHandlingStrategy {
    /// do nothing.
    case ignore

    /// remove incompatible stored data.
    case removeStore
}

/**
 *  Structure is designed to configure persistent history tracking for cross-process
 *  change notifications.
 *
 *  When multiple targets (app and extensions) share the same persistent store,
 *  history tracking enables each target to observe changes made by other targets.
 *  The cleaner uses the full list of targets to ensure history is only deleted
 *  after all targets have processed it.
 */

public struct CoreDataHistoryTrackingSettings {
    /// Identifier for this target's transactions in the shared store.
    public var transactionAuthor: String

    /// All target identifiers that share the persistent store (for safe history cleanup).
    /// When empty, defaults to ``[transactionAuthor]``.
    public var targets: [String]

    /// App group container name for shared UserDefaults across targets.
    /// Required when multiple targets share the store so they can read each other's timestamps.
    public var sharedContainerName: String

    public init(
        transactionAuthor: String,
        targets: [String] = [],
        sharedContainerName: String
    ) {
        self.transactionAuthor = transactionAuthor
        self.targets = targets
        self.sharedContainerName = sharedContainerName
    }
}

/**
 *  Structure is designed to define persistence settings of Core Data store.
 */

public struct CoreDataPersistentSettings {
    /// Url of the directory where to store database.
    public var databaseDirectory: URL

    /// Name of the database file.
    public var databaseName: String

    /// Strategy that defines how to handle incompatible persisten store.
    public var incompatibleModelStrategy: IncompatibleModelHandlingStrategy

    /// Flag that states whether to allow database backup to iCloud.
    public var excludeFromiCloudBackup: Bool

    /// Settings for persistent history tracking. When ``nil``, tracking is disabled.
    public var historyTracking: CoreDataHistoryTrackingSettings?

    /**
     *  Creates Core Data persistent store settins.
     *
     *  - parameters:
     *    - databaseDirectory: Url of the directory where to store database.
     *    - databaseName: Name of the database file.
     *    - incompatibleModelStrategy: Strategy that defines how to handle
     *    incompatible persisten store.
     *    - excludeFromiCloudBackup: Flag that states whether to allow database
     *    backup to iCloud.
     *    - historyTracking: Settings for persistent history tracking.
     *    Pass ``nil`` to disable tracking.
     */

    public init(
        databaseDirectory: URL,
        databaseName: String,
        incompatibleModelStrategy: IncompatibleModelHandlingStrategy = .ignore,
        excludeFromiCloudBackup: Bool = true,
        historyTracking: CoreDataHistoryTrackingSettings? = nil
    ) {
        self.databaseDirectory = databaseDirectory
        self.databaseName = databaseName
        self.incompatibleModelStrategy = incompatibleModelStrategy
        self.excludeFromiCloudBackup = excludeFromiCloudBackup
        self.historyTracking = historyTracking
    }
}

/**
 *  Enum defines type of Core Data storage.
 */

public enum CoreDataServiceStorageType {
    /// Persist data to disk. Takes persistent settings as associated value.
    case persistent(settings: CoreDataPersistentSettings)

    /// Store data in memory.
    case inMemory
}

/**
 *  Enum defines how the service maps roles (writer, observer, readers) onto managed object contexts.
 */

public enum CoreDataConcurrencyMode {
    /// One private-queue context serves reads, writes and observation, as in 2.x. Change observers follow
    /// the same state-based delivery rules as ```.concurrent```.
    case serial

    /**
     *  A dedicated writer and observer context on the shared coordinator; one-shot reads run on
     *  short-lived sibling contexts, at most `readerConcurrency` at a time. Must be at least 1.
     */
    case concurrent(readerConcurrency: Int)
}

/**
 *  Protocol is designed to define configuration of Core Data service.
 */

public protocol CoreDataServiceConfigurationProtocol {
    /// URL of the Core Data entity model.
    var modelURL: URL { get }

    /// Storage type to use.
    var storageType: CoreDataServiceStorageType { get }

    /// Context topology. Defaults to ```.serial``` for conformers that predate the setting.
    var concurrencyMode: CoreDataConcurrencyMode { get }

    /// Destination for diagnostics the store and its observables cannot raise as errors — a model that
    /// cannot deliver remote deletes, for instance. Defaults to ```nil```, which silences them.
    var logger: SDKLoggerProtocol? { get }

    /// Queue ```performRead``` delivers its completions on. Defaults to a global concurrent queue.
    ///
    /// - important: It must be concurrent. Completions in this library routinely block — that is what
    /// ```extractNoCancellableResultData``` and ```addOperations(_:waitUntilFinished:)``` do — and on a
    /// serial queue one blocked completion stops every other completion behind it, including the one it is
    /// waiting for. Delivering here rather than on the reader pool is what keeps a blocked completion from
    /// holding a reader slot; a serial queue reintroduces the same deadlock one step further out.
    var completionQueue: DispatchQueue { get }
}

public extension CoreDataServiceConfigurationProtocol {
    var concurrencyMode: CoreDataConcurrencyMode { .serial }

    var logger: SDKLoggerProtocol? { nil }

    var completionQueue: DispatchQueue { .global(qos: .userInitiated) }
}

/**
 *  Closure to asynchroniously deliver Core Data context when requested. ```Nil```
 *  is passed for context parameter when an error occured which is delivered as
 *  a second parameter.
 */

public typealias CoreDataContextInvocationBlock = (NSManagedObjectContext?, Error?) -> Void

/// Work executed on a context's own queue; the returned value is delivered to the completion.
public typealias CoreDataContextBlock<T> = (NSManagedObjectContext) throws -> T

/// Completion of ```performWrite``` / ```performRead```.
public typealias CoreDataResultBlock<T> = (Result<T, Error>) -> Void

/// Receives the writer and the observer context together; both are ```nil``` when an error is delivered.
public typealias CoreDataWriterObserverBlock = (
    _ writer: NSManagedObjectContext?,
    _ observer: NSManagedObjectContext?,
    _ error: Error?
) -> Void

/**
 *  Protocol is designed to define an interface to manage configuration and access to Core Data store.
 */

public protocol CoreDataServiceProtocol {
    /// Value that is passed during initialization to configure the service.
    var configuration: CoreDataServiceConfigurationProtocol { get }

    /**
     *  Requests Core Data context. Context is asynchroniously delivered as soon
     *  as become available. If there is an error occured then context ```nil```
     *  is passed for context parameter and error value is delivered as a second one.
     */

    func performAsync(block: @escaping CoreDataContextInvocationBlock)

    /**
     *  Runs ```block``` on the writer context as one transaction: the context is saved when the block
     *  leaves changes and rolled back when it throws. Writes are serialized in call order.
     */
    func performWrite<T>(_ block: @escaping CoreDataContextBlock<T>, completion: @escaping CoreDataResultBlock<T>)

    /**
     *  Runs ```block``` as a one-shot read. In ```.concurrent``` mode it executes on a short-lived sibling
     *  context that is discarded as soon as the block returns and may overlap other reads and the writer.
     *  A read must not mutate: a change the block leaves behind is rolled back and the read fails with
     *  ```CoreDataServiceError.readLeftChanges``` in every mode, rather than being discarded silently.
     *
     *  - important: The value returned from ```block``` and anything the completion captures must be plain
     *  values, never ```NSManagedObject``` instances: in ```.concurrent``` mode their context no longer
     *  exists by the time the completion runs. ```block``` must not call ```close()``` — it still holds the
     *  store that call would wait for.
     */
    func performRead<T>(_ block: @escaping CoreDataContextBlock<T>, completion: @escaping CoreDataResultBlock<T>)

    /**
     *  Delivers the observer context for long-lived observation such as fetched results controllers.
     *  The context merges every writer save automatically and is never reset while the store is open.
     */
    func performObserve(block: @escaping CoreDataContextInvocationBlock)

    /**
     *  Delivers the writer and the observer context together, on the writer's queue, so a component that
     *  registers for the writer's saves and resolves them on the observer needs a single call to set up.
     */
    func performWithObserver(block: @escaping CoreDataWriterObserverBlock)

    /**
     *  Closes Core Data store after queued work has drained. Work that reaches the service while it is
     *  still draining is rejected with ```CoreDataServiceError.closeInProgress```; work arriving after this
     *  returns opens the store again on demand. A read's completion may close the service; a read's block
     *  may not.
     *
     *  - note: This waits for reads to release the store, not for their completions to run. A completion
     *  is allowed to re-enter the service, so waiting for one could wait for a completion that is itself
     *  closing. A read completion may therefore still be pending when this returns; it no longer touches
     *  the store by then, so dropping is safe.
     */
    func close() throws

    /**
     *  Removes Core Data store.
     *
     *  - note: Core Data store must be closed before calling this function, and a ```close()``` that is
     *  still draining does not count as closed: dropping then throws
     *  ```CoreDataServiceError.closeInProgress```. See ```close``` method for more details.
     */
    func drop() throws
}

/**
 *  Role entry points expressed through ```performAsync``` for conformers that predate them. Every role
 *  resolves to the single context such a conformer hands out, which is the ```.serial``` topology.
 */
public extension CoreDataServiceProtocol {
    func performWrite<T>(
        _ block: @escaping CoreDataContextBlock<T>,
        completion: @escaping CoreDataResultBlock<T>
    ) {
        performAsync { context, error in
            guard let context else {
                return completion(.failure(error ?? CoreDataServiceError.contextUnavailable))
            }

            do {
                let value = try block(context)

                if context.hasChanges {
                    try context.save()
                }

                completion(.success(value))
            } catch {
                context.rollback()
                completion(.failure(error))
            }
        }
    }

    func performRead<T>(
        _ block: @escaping CoreDataContextBlock<T>,
        completion: @escaping CoreDataResultBlock<T>
    ) {
        performAsync { context, error in
            guard let context else {
                return completion(.failure(error ?? CoreDataServiceError.contextUnavailable))
            }

            let wasClean = !context.hasChanges
            let result = Result { try block(context) }

            if wasClean, context.hasChanges {
                // A read must not mutate: the change would otherwise join the next write's save.
                context.rollback()

                // A block that threw already has a more informative error than this one.
                if case .success = result {
                    return completion(.failure(CoreDataServiceError.readLeftChanges))
                }
            }

            completion(result)
        }
    }

    func performObserve(block: @escaping CoreDataContextInvocationBlock) {
        performAsync(block: block)
    }

    func performWithObserver(block: @escaping CoreDataWriterObserverBlock) {
        performAsync { context, error in
            block(context, context, error)
        }
    }
}
