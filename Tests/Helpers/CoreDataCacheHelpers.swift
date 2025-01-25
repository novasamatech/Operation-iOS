import Foundation
import Operation_iOS
import CoreData

public func clear(databaseService: CoreDataServiceProtocol) throws {
    try databaseService.close()
    try databaseService.drop()
}

public final class CoreDataRepositoryFacade {
    public static let shared = CoreDataRepositoryFacade()

    public let databaseService: CoreDataServiceProtocol

    private init() {
        let configuration = CoreDataServiceConfiguration.createDefaultConfigutation()
        databaseService = CoreDataService(configuration: configuration)
    }

    public func createCoreDataRepository<T, U>(filter: NSPredicate? = nil,
                                        sortDescriptors: [NSSortDescriptor] = []) -> CoreDataRepository<T, U>
        where T: Identifiable & Codable, U: NSManagedObject & CoreDataCodable  {

            let mapper = AnyCoreDataMapper(CodableCoreDataMapper<T, U>())
            return CoreDataRepository(databaseService: databaseService,
                                      mapper: mapper,
                                      filter: filter,
                                      sortDescriptors: sortDescriptors)
    }

    public func clearDatabase() throws {
        try clear(databaseService: databaseService)
    }
}
