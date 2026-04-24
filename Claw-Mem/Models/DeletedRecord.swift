import Foundation
import SwiftData

/// Tombstone for a deleted (date, project) bucket. Once present, ingest
/// will skip any event whose `timestamp <= deletedAt` so re-reading the
/// source JSONL won't resurrect the data. Future events (after deletedAt)
/// flow through normally — letting the user delete today's morning work
/// then keep working on the same project in the afternoon.
@Model
final class DeletedRecord {
    @Attribute(.unique) var summaryKey: String  // "date#project"
    var localDate: String
    var project: String
    var deletedAt: Date
    var deviceID: String

    init(
        summaryKey: String,
        localDate: String,
        project: String,
        deletedAt: Date,
        deviceID: String
    ) {
        self.summaryKey = summaryKey
        self.localDate = localDate
        self.project = project
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }
}
