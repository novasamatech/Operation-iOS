import Foundation
import SDKLogger

/**
 *  Structure is designed to provide setup values for Core Data service.
 *  See ```CoreDataServiceProtocol``` for more details.
 */

public struct CoreDataServiceConfiguration: CoreDataServiceConfigurationProtocol {
    /// URL to Core Data entity model.
    public var modelURL: URL

    /// Type of the Core Data store.
    public var storageType: CoreDataServiceStorageType

    /// Context topology; ```.serial``` reproduces 2.x behaviour.
    public var concurrencyMode: CoreDataConcurrencyMode

    /// Destination for diagnostics that cannot be surfaced as errors.
    public var logger: SDKLoggerProtocol?

    /// Queue ```performRead``` delivers its completions on. Must be concurrent; see the protocol.
    public var completionQueue: DispatchQueue

    /**
     *  Creates Core Data service configuration.
     *
     *  - parameters:
     *    - modelURL: URL to Core Data entity model.
     *    - storageType: Type of the Core Data store.
     *    - concurrencyMode: Context topology. Defaults to ```.serial```.
     */

    public init(
        modelURL: URL,
        storageType: CoreDataServiceStorageType,
        concurrencyMode: CoreDataConcurrencyMode = .serial,
        logger: SDKLoggerProtocol? = nil,
        completionQueue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        self.modelURL = modelURL
        self.storageType = storageType
        self.concurrencyMode = concurrencyMode
        self.logger = logger
        self.completionQueue = completionQueue
    }
}
