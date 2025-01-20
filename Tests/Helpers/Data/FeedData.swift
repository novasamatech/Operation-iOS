import Foundation

public enum FeedDataStatus: String, Codable {
    case open = "OPEN"
    case hidden = "HIDDEN"
}

public enum Domain: String, Codable {
    case `default` = "default"
    case favorites = "favorites"
}

public struct FeedData: Equatable, Codable {
    public enum CodingKeys: String, CodingKey {
        case identifier = "id"
        case domain
        case favorite
        case favoriteCount
        case name
        case description
        case imageLink
        case status
        case likesCount
    }

    public var identifier: String
    public var domain: Domain
    public var favorite: Bool
    public var favoriteCount: UInt
    public var name: String
    public var description: String?
    public var imageLink: URL?
    public var status: FeedDataStatus
    public var likesCount: Int32
    
    public init(
        identifier: String,
        domain: Domain,
        favorite: Bool,
        favoriteCount: UInt,
        name: String,
        description: String? = nil,
        imageLink: URL? = nil,
        status: FeedDataStatus,
        likesCount: Int32
    ) {
        self.identifier = identifier
        self.domain = domain
        self.favorite = favorite
        self.favoriteCount = favoriteCount
        self.name = name
        self.description = description
        self.imageLink = imageLink
        self.status = status
        self.likesCount = likesCount
    }
}
