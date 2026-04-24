import Foundation
import SwiftData

enum MessageType: String, Codable {
    case user
    case assistant
    case toolResult
    case system
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var sessionId: String
    var project: String
    var localDate: String
    var type: MessageType
    var role: String?
    var textContent: String?
    var timestamp: Date
    var rawEventId: UUID

    init(
        id: UUID = UUID(),
        sessionId: String,
        project: String,
        localDate: String,
        type: MessageType,
        role: String? = nil,
        textContent: String? = nil,
        timestamp: Date,
        rawEventId: UUID
    ) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.localDate = localDate
        self.type = type
        self.role = role
        self.textContent = textContent
        self.timestamp = timestamp
        self.rawEventId = rawEventId
    }
}
