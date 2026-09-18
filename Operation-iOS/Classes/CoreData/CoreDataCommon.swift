import Foundation
import CoreData

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
    /// One private-queue context serves reads, writes and observation. Identical to 2.x behaviour.
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
}

public extension CoreDataServiceConfigurationProtocol {
    var concurrencyMode: CoreDataConcurrencyMode { .serial }
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
     *  context and may overlap other reads and the writer; changes left on the context are discarded.
     */
    func performRead<T>(_ block: @escaping CoreDataContextBlock<T>, completion: @escaping CoreDataResultBlock<T>)

    /**
     *  Delivers the observer context for long-lived observation such as fetched results controllers.
     *  The context merges every writer save automatically and is never reset while the store is open.
     */
    func performObserve(block: @escaping CoreDataContextInvocationBlock)

    /**
     *  Closes Core Data store. Implementation should open the store when a context
     *  is requested for the first time.
     */
    func close() throws

    /**
     *  Removes Core Data store.
     *
     *  - note: Core Data store must be closed before calling this function. See ```close``` method for
     *  more details.
     */
    func drop() throws
}
