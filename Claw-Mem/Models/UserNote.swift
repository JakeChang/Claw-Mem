import Foundation
import SwiftData

@Model
final class UserNote {
    @Attribute(.unique) var summaryKey: String
    var localDate: String
    var project: String
    var content: String
    var updatedAt: Date

    init(
        summaryKey: String,
        localDate: String,
        project: String,
        content: String = "",
        updatedAt: Date = Date()
    ) {
        self.summaryKey = summaryKey
        self.localDate = localDate
        self.project = project
        self.content = content
        self.updatedAt = updatedAt
    }
}
