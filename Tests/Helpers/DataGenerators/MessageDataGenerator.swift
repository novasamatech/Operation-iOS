import Foundation

public func createRandomMessage() -> MessageData {
    let chat = createRandomChat()

    return createRandomMessage(for: chat)
}

public func createRandomMessage(for chat: ChatData) -> MessageData {
    return MessageData(identifier: UUID().uuidString,
                       chat: chat,
                       text: UUID().uuidString)
}

public func createRandomChat() -> ChatData {
    return ChatData(identifier: UUID().uuidString,
                    title: UUID().uuidString)
}
