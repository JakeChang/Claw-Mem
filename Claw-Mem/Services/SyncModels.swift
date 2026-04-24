import Foundation

/// Shape of an on-disk `summary.json` file in the sync folder.
nonisolated struct SyncSummary: Codable, Sendable {
    let summaryKey: String
    let localDate: String
    let project: String
    let contentJSON: String
    let promptForClaude: String
    let status: String
    let sourceLastTimestamp: Date?
    let sourceRawEventCount: Int
    let errorMessage: String?
    let updatedAt: Date
}

/// Shape of an on-disk `notes.json` file in the sync folder.
nonisolated struct SyncNote: Codable, Sendable {
    let summaryKey: String
    let localDate: String
    let project: String
    let content: String
    let updatedAt: Date
}

/// Shape of `_deleted.json` — a tombstone marker in the sync folder.
/// When another device imports it, the corresponding records in its DB are
/// purged (subject to the deletedAt cutoff).
nonisolated struct SyncDeletion: Codable, Sendable {
    let summaryKey: String
    let localDate: String
    let project: String
    let deletedAt: Date
    let deviceID: String
}

/// One line of a `log.{device}.jsonl` file. Represents either a Message or
/// a ToolEvent — differentiated by `kind` — so both streams share a single
/// append-only file per device.
nonisolated struct SyncLogEntry: Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case message
        case toolEvent
    }

    let kind: Kind
    let id: UUID
    let sessionId: String
    let project: String
    let localDate: String
    let timestamp: Date

    // Message fields (nil when kind == .toolEvent)
    let messageType: String?
    let role: String?
    let textContent: String?

    // ToolEvent fields (nil when kind == .message)
    let toolName: String?
    let toolKind: String?
    let toolCallId: String?
    let inputPreview: String?
    let resultPreview: String?
}
