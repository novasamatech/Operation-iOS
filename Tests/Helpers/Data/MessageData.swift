import Foundation

public struct MessageData: Equatable, Codable {
    public var identifier: String
    public var chat: ChatData
    public var text: String
}
