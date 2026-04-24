import Foundation
import SwiftData

enum ToolKind: String, Codable {
    case read
    case edit
    case write
    case bash
    case search
    case other
}

@Model
final class ToolEvent {
    @Attribute(.unique) var id: UUID
    var sessionId: String
    var project: String
    var localDate: String
    var toolCallId: String?
    var toolName: String
    var toolKind: ToolKind
    var inputPreview: String?
    var resultPreview: String?
    var timestamp: Date
    var rawEventId: UUID

    init(
        id: UUID = UUID(),
        sessionId: String,
        project: String,
        localDate: String,
        toolCallId: String? = nil,
        toolName: String,
        toolKind: ToolKind,
        inputPreview: String? = nil,
        resultPreview: String? = nil,
        timestamp: Date,
        rawEventId: UUID
    ) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.localDate = localDate
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.toolKind = toolKind
        self.inputPreview = inputPreview
        self.resultPreview = resultPreview
        self.timestamp = timestamp
        self.rawEventId = rawEventId
    }
}
