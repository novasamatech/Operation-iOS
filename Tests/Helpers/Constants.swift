import Foundation

public struct Constants {
    public static let defaultCoreDataModelName = "Entities"
    public static let incompatibleCoreDataModelName = "IEntities"
    public static let repositoryDomain = "io.novasama.test.repository"
    public static let expectationDuration: TimeInterval = 60.0
    public static let dummyNetworkURL: URL = URL(string: "https://google.com")!
    public static let networkRequestTimeout: TimeInterval = 60.0
}
