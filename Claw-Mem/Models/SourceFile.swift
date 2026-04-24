import Foundation
import SwiftData

enum SourceFileStatus: String, Codable {
    case active
    case missing
    case rotated
}

enum IngestStatus: String, Codable {
    case idle
    case ingesting
    case success
    case failed
}

@Model
final class SourceFile {
    @Attribute(.unique) var path: String
    var sessionId: String
    var project: String
    var lastOffset: Int64
    var fileSize: Int64
    var modifiedAt: Date?
    var lastSeenAt: Date
    var lastIngestedAt: Date?
    var ingestStatus: IngestStatus
    var status: SourceFileStatus

    init(
        path: String,
        sessionId: String,
        project: String,
        lastOffset: Int64 = 0,
        fileSize: Int64 = 0,
        modifiedAt: Date? = nil,
        lastSeenAt: Date,
        lastIngestedAt: Date? = nil,
        ingestStatus: IngestStatus = .idle,
        status: SourceFileStatus = .active
    ) {
        self.path = path
        self.sessionId = sessionId
        self.project = project
        self.lastOffset = lastOffset
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.lastSeenAt = lastSeenAt
        self.lastIngestedAt = lastIngestedAt
        self.ingestStatus = ingestStatus
        self.status = status
    }
}
