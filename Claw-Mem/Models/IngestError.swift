import Foundation
import SwiftData

enum IngestErrorKind: String, Codable {
    case invalidJSON
    case missingField
    case timestampParseFailed
    case unknownEventType
    case normalizationFailed
}

@Model
final class IngestError {
    @Attribute(.unique) var id: UUID
    var sourceFilePath: String
    var byteOffset: Int64?
    var rawJSON: String?
    var errorKind: IngestErrorKind
    var errorMessage: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceFilePath: String,
        byteOffset: Int64? = nil,
        rawJSON: String? = nil,
        errorKind: IngestErrorKind,
        errorMessage: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceFilePath = sourceFilePath
        self.byteOffset = byteOffset
        self.rawJSON = rawJSON
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
