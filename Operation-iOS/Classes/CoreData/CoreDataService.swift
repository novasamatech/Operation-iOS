import Foundation
import CoreData

/**
 *  Enum is defining errors which can occur during
 *  Core Data service work.
 */

public enum CoreDataServiceError: Error {
    /// Database file can't be created at given url.
    case databaseURLInvalid

    /// Can't instantiate Core Data entity model from url.
    case modelInitializationFailed

    /// Thrown when service is trying to be closed during setup.
    case unexpectedCloseDuringSetup

    /// Thrown when service is trying to drop persistent store but not closed.
    case unexpectedDropWhenOpen

    /// Can't remove incompatible persistent store.
    case incompatibleModelRemoveFailed

    /// ```.concurrent``` mode was configured with fewer than one reader.
    case invalidReaderConcurrency(Int)

    /// A context was requested but none was delivered and no other error explains why.
    case contextUnavailable

    /// ```close()``` was reached while another close is still draining the store. The service is neither
    /// open nor closed at that point, so work is rejected rather than served by a second store.
    case closeInProgress

    /// ```close()``` was called from inside a read block, where it could only wait for the read it is
    /// running on. Close the service from the completion or from another thread instead.
    case closeFromReadBlock

    /// A read block left changes on its context. The changes are rolled back and the read fails: a read
    /// must not mutate, and in ```.serial``` mode the change would otherwise join the next write's save.
    case readLeftChanges
}

/**
 *  Class is designed to provide implementation of ```CoreDataServiceProtocol```
 *  which manages Core Data persistent store and contexts.
 */

public class CoreDataService {
    public let configuration: CoreDataServiceConfigurationProtocol

    /**
     *  Creates Core Data service object.
     *
     *  - parameters:
     *    - configuration: Value to setup the service.
     */

    public init(configuration: CoreDataServiceConfigurationProtocol) {
        self.configuration = configuration
    }

    /// Lifecycle of the store. ```closing``` is neither open nor closed: the roles are detached but their
    /// queued work is still draining, so arriving work is rejected rather than served by a second store.
    private enum State {
        case closed
        case open(CoreDataContextRoles)
        case closing
    }

    private var state: State = .closed
    private var historyObserver: CoreDataHistoryObserver?
    private let lock = NSLock()

    /// The open roles, or ```nil``` while the store is closed or still closing. Internal callers read
    /// ```state``` directly: this takes the lock and would deadlock under ```withRoles```.
    var roles: CoreDataContextRoles? {
        lock.lock()

        defer {
            lock.unlock()
        }

        guard case .open(let roles) = state else {
            return nil
        }

        return roles
    }

    /// The writer context, or ```nil``` while the store is closed.
    var context: NSManagedObjectContext? {
        roles?.writer
    }

    func databaseURL(with fileManager: FileManager) -> URL? {
        guard case .persistent(let settings) = configuration.storageType else {
            return nil
        }

        var dabaseDirectory = settings.databaseDirectory

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dabaseDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return dabaseDirectory.appendingPathComponent(settings.databaseName)
        }

        do {
            try fileManager.createDirectory(at: dabaseDirectory, withIntermediateDirectories: true)

            var resources = URLResourceValues()
            resources.isExcludedFromBackup = settings.excludeFromiCloudBackup
            try dabaseDirectory.setResourceValues(resources)

            return dabaseDirectory.appendingPathComponent(settings.databaseName)
        } catch {
            return nil
        }
    }
}

// MARK: Internal Invocations logic
extension CoreDataService {
    /// Resolves the roles under the setup lock, opening the store on first use, and hands them to ```body```
    /// while the lock is still held, so work ```body``` enqueues is guaranteed to be queued before a later
    /// ```close()``` drains the contexts. Bodies must only enqueue asynchronously. Setup errors go to
    /// ```onFailure``` on the caller's thread with the lock released, as a failure completion may call back
    /// into the service.
    ///
    /// Work that arrives while a ```close()``` is draining is rejected: opening a second store on the same
    /// file would leave the close tearing down a store that is no longer the service's, and would let a
    /// following ```drop()``` delete the file under it.
    func withRoles(onFailure: (Error) -> Void, _ body: (CoreDataContextRoles) -> Void) {
        lock.lock()

        let failure: Error?

        do {
            switch state {
            case .open(let roles):
                body(roles)
            case .closed:
                body(try setup())
            case .closing:
                throw CoreDataServiceError.closeInProgress
            }

            failure = nil
        } catch {
            failure = error
        }

        lock.unlock()

        if let failure {
            onFailure(failure)
        }
    }
}

// MARK: Internal Setup Logic
extension CoreDataService {
    func setup() throws -> CoreDataContextRoles {
        if case .concurrent(let readerConcurrency) = configuration.concurrencyMode, readerConcurrency < 1 {
            // Programmer error: reject before any store is touched, so nothing is created on disk.
            throw CoreDataServiceError.invalidReaderConcurrency(readerConcurrency)
        }

        let fileManager = FileManager.default
        let optionalDatabaseURL = self.databaseURL(with: fileManager)
        let storageType: String
        var historyTracking: CoreDataHistoryTrackingSettings?

        guard let model = NSManagedObjectModel(contentsOf: configuration.modelURL) else {
            throw CoreDataServiceError.modelInitializationFailed
        }

        switch configuration.storageType {
        case .persistent(let settings):
            guard let databaseURL = optionalDatabaseURL  else {
                throw CoreDataServiceError.databaseURLInvalid
            }

            if settings.incompatibleModelStrategy != .ignore &&
                !checkCompatibility(of: model, with: databaseURL, using: fileManager) {

                try fileManager.removeItem(at: databaseURL)
            }

            storageType = NSSQLiteStoreType
            historyTracking = settings.historyTracking
        case .inMemory:
            storageType = NSInMemoryStoreType
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)

        var storeOptions: [String: Any]?

        if historyTracking != nil {
            storeOptions = [
                NSPersistentHistoryTrackingKey: true,
                NSPersistentStoreRemoteChangeNotificationPostOptionKey: true
            ]
        }

        try coordinator.addPersistentStore(
            ofType: storageType,
            configurationName: nil,
            at: optionalDatabaseURL,
            options: storeOptions
        )

        let roles = try CoreDataContextRoles.make(
            coordinator: coordinator,
            mode: configuration.concurrencyMode,
            historyTracking: historyTracking
        )

        self.state = .open(roles)

        if let historyTracking {
            let targets = historyTracking.targets.isEmpty
                ? [historyTracking.transactionAuthor]
                : historyTracking.targets

            let timestampManagers = try targets.map {
                try CoreDataHistoryTimestampManager(
                    target: $0,
                    sharedContainer: historyTracking.sharedContainerName
                )
            }

            let currentTimestampManager = try CoreDataHistoryTimestampManager(
                target: historyTracking.transactionAuthor,
                sharedContainer: historyTracking.sharedContainerName
            )

            let observer = CoreDataHistoryObserver(
                contexts: roles.allContexts,
                timestampManager: currentTimestampManager,
                cleaner: CoreDataHistoryCleaner(timestampManagers: timestampManagers),
                logger: configuration.logger
            )
            observer.startObserving()
            self.historyObserver = observer
        }

        return roles
    }
}

// MARK: Model Compatability
extension CoreDataService {
    func checkCompatibility(of model: NSManagedObjectModel,
                            with databaseURL: URL,
                            using fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return true
        }

        do {
            let storeMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                                                                                            at: databaseURL,
                                                                                            options: nil)
            return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: storeMetadata)
        } catch {
            return false
        }
    }
}

extension CoreDataService: CoreDataServiceProtocol {
    public func performAsync(block: @escaping CoreDataContextInvocationBlock) {
        withRoles(onFailure: { block(nil, $0) }) { roles in
            roles.writer.perform {
                block(roles.writer, nil)
            }
        }
    }

    public func performWrite<T>(
        _ block: @escaping CoreDataContextBlock<T>,
        completion: @escaping CoreDataResultBlock<T>
    ) {
        withRoles(onFailure: { completion(.failure($0)) }) { roles in
            roles.writer.perform {
                // Changes a legacy ```performAsync``` block left unsaved join this transaction, as they
                // always did on the shared context in 2.x.
                do {
                    let value = try block(roles.writer)

                    if roles.writer.hasChanges {
                        try roles.writer.save()
                    }

                    completion(.success(value))
                } catch {
                    roles.writer.rollback()
                    completion(.failure(error))
                }
            }
        }
    }

    public func performRead<T>(
        _ block: @escaping CoreDataContextBlock<T>,
        completion: @escaping CoreDataResultBlock<T>
    ) {
        withRoles(onFailure: { completion(.failure($0)) }) { roles in
            guard let readerQueue = roles.readerQueue else {
                roles.writer.perform {
                    // Only discard what the read itself introduced; a legacy block may own pending changes.
                    let wasClean = !roles.writer.hasChanges
                    let result = Result { try block(roles.writer) }

                    if wasClean, roles.writer.hasChanges {
                        // A read must not mutate: the change would otherwise join the next write's save.
                        // Rolling back is what protects the store; the failure is what tells the caller.
                        roles.writer.rollback()

                        // A block that threw already has a more informative error than this one.
                        if case .success = result {
                            completion(.failure(CoreDataServiceError.readLeftChanges))
                            return
                        }
                    }

                    completion(result)
                }
                return
            }

            // Counted here, under the service lock, so a ```close()``` reaching the lock next still waits
            // for this read even though its operation has not started.
            roles.readerActivity.enter()

            readerQueue.addOperation {
                let result: Result<T, Error> = {
                    defer { roles.readerActivity.leave() }

                    let reader = roles.makeReader()
                    var value: Result<T, Error>!

                    reader.performAndWait {
                        value = CoreDataReaderActivity.markingCurrentThread {
                            Result { try block(reader) }
                        }

                        if reader.hasChanges {
                            // The reader is discarded unsaved either way, but the contract is reported
                            // identically in both modes so callers see one behaviour.
                            reader.rollback()

                            // A block that threw already has a more informative error than this one.
                            if case .success = value {
                                value = .failure(CoreDataServiceError.readLeftChanges)
                            }
                        }
                    }

                    return value
                }()

                // Off the reader's queue and after the store is released, so the completion is free to
                // close the service or start another read.
                completion(result)
            }
        }
    }

    public func performObserve(block: @escaping CoreDataContextInvocationBlock) {
        withRoles(onFailure: { block(nil, $0) }) { roles in
            roles.observer.perform {
                block(roles.observer, nil)
            }
        }
    }

    public func performWithObserver(block: @escaping CoreDataWriterObserverBlock) {
        withRoles(onFailure: { block(nil, nil, $0) }) { roles in
            roles.writer.perform {
                block(roles.writer, roles.observer, nil)
            }
        }
    }

    /// Detaches the roles under the lock, then drains them with the lock released: queued work may call back
    /// into the service (a read completion issuing another read, an observable reacting to a save), and those
    /// calls must find a free lock rather than deadlock. Work arriving while the drain is running is rejected
    /// with ```closeInProgress```; work arriving after this returns opens a fresh store.
    ///
    /// - throws: ```closeFromReadBlock``` when called from inside a read block, which still holds the store
    /// this call would wait for, and ```closeInProgress``` when another close is already draining.
    public func close() throws {
        guard !CoreDataReaderActivity.isReadingOnCurrentThread else {
            throw CoreDataServiceError.closeFromReadBlock
        }

        lock.lock()

        let roles: CoreDataContextRoles

        switch state {
        case .closed:
            lock.unlock()
            return
        case .closing:
            lock.unlock()
            throw CoreDataServiceError.closeInProgress
        case .open(let open):
            roles = open
            state = .closing

            historyObserver?.stopObserving()
            historyObserver = nil
        }

        lock.unlock()

        defer {
            lock.lock()
            state = .closed
            lock.unlock()
        }

        // Reads hold the store only while their block runs; their completions come after and may re-enter
        // the service, so waiting on the reader queue itself would wait for those too.
        roles.readerActivity.waitUntilIdle()

        // Flush queued transactions first: their did-save notifications enqueue the observer work that the
        // reset below must run after.
        roles.writer.performAndWait {}

        if roles.observer !== roles.writer {
            roles.observer.performAndWait {
                roles.observer.reset()
            }
        }

        roles.writer.performAndWait {
            for store in roles.coordinator.persistentStores {
                try? roles.coordinator.remove(store)
            }
        }
    }

    public func drop() throws {
        lock.lock()

        defer {
            lock.unlock()
        }

        switch state {
        case .open:
            throw CoreDataServiceError.unexpectedDropWhenOpen
        case .closing:
            // Detached but still draining: removing the file now pulls it out from under a live coordinator.
            throw CoreDataServiceError.closeInProgress
        case .closed:
            break
        }

        guard case .persistent(let settings) = configuration.storageType else {
            return
        }

        try removeDatabaseFile(using: FileManager.default, settings: settings)
    }

    private func removeDatabaseFile(using fileManager: FileManager, settings: CoreDataPersistentSettings) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: settings.databaseDirectory.path,
                                  isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.removeItem(at: settings.databaseDirectory)
        }
    }
}
