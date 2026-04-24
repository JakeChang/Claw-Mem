import Foundation

nonisolated struct SummaryContent: Codable, Sendable {
    let schemaVersion: Int
    let overview: String
    let completed: [String]
    let filesModified: [FileChange]
    let problems: [Problem]
    let unfinished: [String]
    let nextSteps: [String]

    static func decode(from data: Data) -> SummaryContent? {
        try? JSONDecoder().decode(SummaryContent.self, from: data)
    }
}

nonisolated struct FileChange: Codable, Sendable {
    let path: String
    let reason: String
}

nonisolated struct Problem: Codable, Sendable {
    let description: String
    let solution: String
}

// MARK: - Project-level summary

nonisolated struct ProjectSummaryContent: Codable, Sendable {
    let schemaVersion: Int
    let projectOverview: String
    let techStack: [String]
    let milestones: [String]
    let architecture: String
    let currentState: String
    let knownIssues: [String]
    let nextSteps: [String]

    static func decode(from data: Data) -> ProjectSummaryContent? {
        try? JSONDecoder().decode(ProjectSummaryContent.self, from: data)
    }
}

/// Sentinel date used for project-level summaries.
nonisolated let projectSummaryDate = "__project__"
