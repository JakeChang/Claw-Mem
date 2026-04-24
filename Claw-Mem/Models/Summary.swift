import Foundation
import SwiftData

enum SummaryStatus: String, Codable {
    case notGenerated
    case fresh
    case stale
    case failed
}

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var summaryKey: String
    var localDate: String
    var project: String
    var contentJSON: String
    var promptForClaude: String
    var sourceLastTimestamp: Date?
    var sourceRawEventCount: Int
    var status: SummaryStatus
    var errorMessage: String?
    var createdAt: Date
    var lastAttemptedAt: Date?

    init(
        id: UUID = UUID(),
        summaryKey: String,
        localDate: String,
        project: String,
        contentJSON: String = "",
        promptForClaude: String = "",
        sourceLastTimestamp: Date? = nil,
        sourceRawEventCount: Int = 0,
        status: SummaryStatus = .notGenerated,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        lastAttemptedAt: Date? = nil
    ) {
        self.id = id
        self.summaryKey = summaryKey
        self.localDate = localDate
        self.project = project
        self.contentJSON = contentJSON
        self.promptForClaude = promptForClaude
        self.sourceLastTimestamp = sourceLastTimestamp
        self.sourceRawEventCount = sourceRawEventCount
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.lastAttemptedAt = lastAttemptedAt
    }
}
