import Foundation
import Operation_iOS

extension CoreDataServiceConfiguration {
    public static func createDefaultConfigutation() -> CoreDataServiceConfiguration {
        return createDefaultConfigutation(with: Constants.defaultCoreDataModelName,
                                          databaseName: Constants.defaultCoreDataModelName,
                                          incompatibleModelStrategy: .ignore)
    }

    public static func createDefaultConfigutation(
        with modelName: String,
        databaseName: String,
        incompatibleModelStrategy: IncompatibleModelHandlingStrategy
    ) -> CoreDataServiceConfiguration {
        let bundle: Bundle
#if SWIFT_PACKAGE
        bundle = Bundle.module
#else
        bundle = Bundle(for: LoadableBundleClass.self)
#endif
        
        let modelURL = bundle.url(forResource: modelName, withExtension: "momd")
        let databaseName = "\(databaseName).sqlite"

        let baseURL = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask).first?.appendingPathComponent("CoreData")

        let persistentSettings = CoreDataPersistentSettings(databaseDirectory: baseURL!,
                                                            databaseName: databaseName,
                                                            incompatibleModelStrategy: incompatibleModelStrategy)

        let configuration = CoreDataServiceConfiguration(modelURL: modelURL!,
                                                         storageType: .persistent(settings: persistentSettings))

        return configuration
    }
    
    public static func createConfigurationWithHistoryTracking(
        with modelName: String = Constants.defaultCoreDataModelName,
        databaseName: String,
        incompatibleModelStrategy: IncompatibleModelHandlingStrategy = .removeStore,
        transactionAuthor: String = "test",
        targets: [String] = [],
        sharedContainerName: String = "test"
    ) -> CoreDataServiceConfiguration {
        let bundle: Bundle
#if SWIFT_PACKAGE
        bundle = Bundle.module
#else
        bundle = Bundle(for: LoadableBundleClass.self)
#endif

        let modelURL = bundle.url(forResource: modelName, withExtension: "momd")
        let databaseName = "\(databaseName).sqlite"

        let baseURL = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask).first?.appendingPathComponent("CoreData")

        let historyTracking = CoreDataHistoryTrackingSettings(
            transactionAuthor: transactionAuthor,
            targets: targets,
            sharedContainerName: sharedContainerName
        )

        let persistentSettings = CoreDataPersistentSettings(
            databaseDirectory: baseURL!,
            databaseName: databaseName,
            incompatibleModelStrategy: incompatibleModelStrategy,
            historyTracking: historyTracking
        )

        let configuration = CoreDataServiceConfiguration(modelURL: modelURL!,
                                                         storageType: .persistent(settings: persistentSettings))

        return configuration
    }
}
