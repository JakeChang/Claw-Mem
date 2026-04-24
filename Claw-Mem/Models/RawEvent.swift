import Foundation
import SwiftData

enum ParseStatus: String, Codable {
    case parsed
    case skipped
    case failed
}

@Model
final class RawEvent {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var dedupeKey: String
    var sourceFilePath: String
    var byteOffset: Int64
    var rawJSON: String
    var lineHash: String
    var parseStatus: ParseStatus
    var parsedAt: Date
    var eventTimestampUTC: Date?
    var eventTimestampLocal: Date?
    var sessionId: String?
    var project: String?
    var localDate: String?

    init(
        id: UUID = UUID(),
        dedupeKey: String,
        sourceFilePath: String,
        byteOffset: Int64,
        rawJSON: String,
        lineHash: String,
        parseStatus: ParseStatus = .parsed,
        parsedAt: Date = Date(),
        eventTimestampUTC: Date? = nil,
        eventTimestampLocal: Date? = nil,
        sessionId: String? = nil,
        project: String? = nil,
        localDate: String? = nil
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.sourceFilePath = sourceFilePath
        self.byteOffset = byteOffset
        self.rawJSON = rawJSON
        self.lineHash = lineHash
        self.parseStatus = parseStatus
        self.parsedAt = parsedAt
        self.eventTimestampUTC = eventTimestampUTC
        self.eventTimestampLocal = eventTimestampLocal
        self.sessionId = sessionId
        self.project = project
        self.localDate = localDate
    }
}
