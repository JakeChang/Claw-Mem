import Foundation
import SwiftData

/// Separate actor for UI reads — never blocks on IngestActor's write operations.
@ModelActor
actor ReadActor {

    func getDateProjectIndex() async throws -> DateProjectIndex {
        let descriptor = FetchDescriptor<Message>()
        let messages = try modelContext.fetch(descriptor)

        var dateSet = Set<String>()
        var projectsByDate = [String: Set<String>]()
        var messageCountByDateProject = [String: Int]()

        // Collect timestamps grouped by (date#project, sessionId) for work hours.
        // Key: "date#project", Value: [sessionId: [timestamps]]
        var timestampsBySession = [String: [String: [Date]]]()

        // Batch-iterate with periodic yields so a huge Message table
        // (~86K rows) doesn't starve other ReadActor work (MainView's
        // fetchMessages / fetchToolEvents queued right behind this).
        for (i, msg) in messages.enumerated() {
            dateSet.insert(msg.localDate)
            projectsByDate[msg.localDate, default: []].insert(msg.project)
            let key = "\(msg.localDate)#\(msg.project)"
            messageCountByDateProject[key, default: 0] += 1
            timestampsBySession[key, default: [:]][msg.sessionId, default: []].append(msg.timestamp)
            if i % 5000 == 0 { await Task.yield() }
        }

        // Also include ToolEvent timestamps for more accurate work hours.
        let toolDescriptor = FetchDescriptor<ToolEvent>()
        let toolEvents = try modelContext.fetch(toolDescriptor)
        for (i, tool) in toolEvents.enumerated() {
            let key = "\(tool.localDate)#\(tool.project)"
            timestampsBySession[key, default: [:]][tool.sessionId, default: []].append(tool.timestamp)
            if i % 5000 == 0 { await Task.yield() }
        }

        // Calculate work hours per date#project using session-based + 10min threshold.
        let idleThreshold: TimeInterval = 600 // 10 minutes
        var workHoursByDateProject = [String: TimeInterval]()
        for (key, sessions) in timestampsBySession {
            var total: TimeInterval = 0
            for (_, timestamps) in sessions {
                let sorted = timestamps.sorted()
                guard sorted.count >= 2 else { continue }
                for i in 1..<sorted.count {
                    let gap = sorted[i].timeIntervalSince(sorted[i - 1])
                    total += min(gap, idleThreshold)
                }
            }
            if total > 0 {
                workHoursByDateProject[key] = total
            }
        }

        let summaries = try modelContext.fetch(FetchDescriptor<Summary>())
        var summaryCountByDate = [String: Int]()
        var summaryKeySet = Set<String>()
        for s in summaries {
            if s.status == .fresh || s.status == .stale {
                summaryCountByDate[s.localDate, default: 0] += 1
                summaryKeySet.insert(s.summaryKey)
                // Surface summary-only (date, project) entries in the calendar
                // and sidebar — needed when a summary syncs from another
                // device without the underlying Messages.
                dateSet.insert(s.localDate)
                projectsByDate[s.localDate, default: []].insert(s.project)
            }
        }

        return DateProjectIndex(
            dates: dateSet.sorted(by: >),
            projectsByDate: projectsByDate.mapValues { $0.sorted() },
            summaryCountByDate: summaryCountByDate,
            messageCountByDateProject: messageCountByDateProject,
            summaryKeySet: summaryKeySet,
            workHoursByDateProject: workHoursByDateProject
        )
    }

    func getMessagesForDate(_ localDate: String, project: String? = nil) throws -> [MessageInfo] {
        let descriptor: FetchDescriptor<Message>
        if let project {
            let predicate = #Predicate<Message> {
                $0.localDate == localDate && $0.project == project
            }
            descriptor = FetchDescriptor<Message>(
                predicate: predicate,
                sortBy: [SortDescriptor(\Message.timestamp)]
            )
        } else {
            let predicate = #Predicate<Message> { $0.localDate == localDate }
            descriptor = FetchDescriptor<Message>(
                predicate: predicate,
                sortBy: [SortDescriptor(\Message.timestamp)]
            )
        }
        return try modelContext.fetch(descriptor).map {
            MessageInfo(
                id: $0.id,
                project: $0.project,
                type: $0.type,
                textContent: $0.textContent,
                timestamp: $0.timestamp
            )
        }
    }

    func getToolEventsForDate(_ localDate: String, project: String? = nil) throws -> [ToolEventInfo] {
        let descriptor: FetchDescriptor<ToolEvent>
        if let project {
            let predicate = #Predicate<ToolEvent> {
                $0.localDate == localDate && $0.project == project
            }
            descriptor = FetchDescriptor<ToolEvent>(
                predicate: predicate,
                sortBy: [SortDescriptor(\ToolEvent.timestamp)]
            )
        } else {
            let predicate = #Predicate<ToolEvent> { $0.localDate == localDate }
            descriptor = FetchDescriptor<ToolEvent>(
                predicate: predicate,
                sortBy: [SortDescriptor(\ToolEvent.timestamp)]
            )
        }
        return try modelContext.fetch(descriptor).map {
            ToolEventInfo(
                id: $0.id,
                project: $0.project,
                toolName: $0.toolName,
                toolKind: $0.toolKind,
                toolCallId: $0.toolCallId,
                inputPreview: $0.inputPreview,
                resultPreview: $0.resultPreview,
                timestamp: $0.timestamp
            )
        }
    }

    func getSummariesForDate(_ localDate: String) throws -> [SummaryInfo] {
        let predicate = #Predicate<Summary> { $0.localDate == localDate }
        let descriptor = FetchDescriptor<Summary>(predicate: predicate)
        return try modelContext.fetch(descriptor).map {
            SummaryInfo(
                summaryKey: $0.summaryKey,
                localDate: $0.localDate,
                project: $0.project,
                contentJSON: $0.contentJSON,
                promptForClaude: $0.promptForClaude,
                sourceLastTimestamp: $0.sourceLastTimestamp,
                sourceRawEventCount: $0.sourceRawEventCount,
                status: $0.status,
                errorMessage: $0.errorMessage
            )
        }
    }

    func getAllSummariesForProject(_ project: String) throws -> [SummaryInfo] {
        let sentinel = projectSummaryDate
        let predicate = #Predicate<Summary> {
            $0.project == project && $0.localDate != sentinel
        }
        let descriptor = FetchDescriptor<Summary>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Summary.localDate)]
        )
        return try modelContext.fetch(descriptor).map {
            SummaryInfo(
                summaryKey: $0.summaryKey,
                localDate: $0.localDate,
                project: $0.project,
                contentJSON: $0.contentJSON,
                promptForClaude: $0.promptForClaude,
                sourceLastTimestamp: $0.sourceLastTimestamp,
                sourceRawEventCount: $0.sourceRawEventCount,
                status: $0.status,
                errorMessage: $0.errorMessage
            )
        }
    }

    func getProjectSummary(project: String) throws -> SummaryInfo? {
        let sentinel = projectSummaryDate
        let predicate = #Predicate<Summary> {
            $0.project == project && $0.localDate == sentinel
        }
        var descriptor = FetchDescriptor<Summary>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map {
            SummaryInfo(
                summaryKey: $0.summaryKey,
                localDate: $0.localDate,
                project: $0.project,
                contentJSON: $0.contentJSON,
                promptForClaude: $0.promptForClaude,
                sourceLastTimestamp: $0.sourceLastTimestamp,
                sourceRawEventCount: $0.sourceRawEventCount,
                status: $0.status,
                errorMessage: $0.errorMessage
            )
        }
    }

    func getNote(summaryKey: String) throws -> String {
        let key = summaryKey
        let predicate = #Predicate<UserNote> { $0.summaryKey == key }
        var descriptor = FetchDescriptor<UserNote>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.content ?? ""
    }

    func getIngestErrors(limit: Int = 20) throws -> [IngestErrorInfo] {
        var descriptor = FetchDescriptor<IngestError>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map {
            IngestErrorInfo(
                sourceFilePath: $0.sourceFilePath,
                errorKind: $0.errorKind,
                errorMessage: $0.errorMessage,
                createdAt: $0.createdAt
            )
        }
    }

    func getStaleSummaryInfo(localDate: String, project: String) throws -> StaleSummaryInfo {
        // Count is now Message + ToolEvent (not RawEvent) so that synced data
        // from other devices — which only syncs Message/ToolEvent — still
        // drives staleness detection correctly.
        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        let messages = try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred))

        let toolPred = #Predicate<ToolEvent> {
            $0.localDate == localDate && $0.project == project
        }
        let tools = try modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred))

        let latest = max(
            messages.map(\.timestamp).max() ?? .distantPast,
            tools.map(\.timestamp).max() ?? .distantPast
        )

        return StaleSummaryInfo(
            rawEventCount: messages.count + tools.count,
            lastTimestamp: latest == .distantPast ? nil : latest
        )
    }

    // MARK: - Delete preview

    func getDeleteStats(localDate: String, project: String) throws -> DeleteStats {
        var stats = DeleteStats()

        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        stats.messages = try modelContext.fetchCount(FetchDescriptor<Message>(predicate: msgPred))

        let toolPred = #Predicate<ToolEvent> {
            $0.localDate == localDate && $0.project == project
        }
        stats.toolEvents = try modelContext.fetchCount(FetchDescriptor<ToolEvent>(predicate: toolPred))

        let key = "\(localDate)#\(project)"
        let sumPred = #Predicate<Summary> { $0.summaryKey == key }
        stats.summaries = try modelContext.fetchCount(FetchDescriptor<Summary>(predicate: sumPred))

        let notePred = #Predicate<UserNote> { $0.summaryKey == key }
        stats.notes = try modelContext.fetchCount(FetchDescriptor<UserNote>(predicate: notePred))

        let optDate: String? = localDate
        let optProj: String? = project
        let rawPred = #Predicate<RawEvent> {
            $0.localDate == optDate && $0.project == optProj
        }
        stats.rawEvents = try modelContext.fetchCount(FetchDescriptor<RawEvent>(predicate: rawPred))

        return stats
    }

    /// Mirror of IngestActor.safelyDeletableSourceFiles for the read path —
    /// used by the delete confirm dialog to show how much disk space the
    /// optional JSONL purge would free.
    func safelyDeletableSourceFiles(
        localDate: String,
        project: String
    ) throws -> [SafeDeleteFile] {
        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        let sessionIds = Set(
            try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred)).map(\.sessionId)
        )

        var result: [SafeDeleteFile] = []
        for sid in sessionIds {
            let otherPred = #Predicate<Message> {
                $0.sessionId == sid && $0.localDate != localDate
            }
            var desc = FetchDescriptor<Message>(predicate: otherPred)
            desc.fetchLimit = 1
            let hasOther = !(try modelContext.fetch(desc).isEmpty)
            guard !hasOther else { continue }

            let sfPred = #Predicate<SourceFile> { $0.sessionId == sid }
            if let sf = try modelContext.fetch(FetchDescriptor<SourceFile>(predicate: sfPred)).first {
                result.append(SafeDeleteFile(
                    path: sf.path,
                    sessionId: sid,
                    fileSize: sf.fileSize,
                    modifiedAt: sf.modifiedAt
                ))
            }
        }
        return result
    }

    /// Returns the set of `(date, project)` keys whose Message or ToolEvent
    /// has a timestamp strictly after `since`. Used by incremental sync
    /// export to skip buckets with no new local data.
    func changedBucketKeysAfter(_ since: Date) throws -> Set<String> {
        var keys = Set<String>()

        let msgPred = #Predicate<Message> { $0.timestamp > since }
        let msgs = try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred))
        for m in msgs { keys.insert("\(m.localDate)#\(m.project)") }

        let toolPred = #Predicate<ToolEvent> { $0.timestamp > since }
        let tools = try modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred))
        for t in tools { keys.insert("\(t.localDate)#\(t.project)") }

        return keys
    }

    func exportDeletions() throws -> [SyncDeletion] {
        let all = try modelContext.fetch(FetchDescriptor<DeletedRecord>())
        return all.map {
            SyncDeletion(
                summaryKey: $0.summaryKey,
                localDate: $0.localDate,
                project: $0.project,
                deletedAt: $0.deletedAt,
                deviceID: $0.deviceID
            )
        }
    }

    // MARK: - Sync export helpers

    func exportSummaries() throws -> [SyncSummary] {
        let all = try modelContext.fetch(FetchDescriptor<Summary>())
        return all.compactMap { s in
            guard s.status == .fresh || s.status == .stale else { return nil }
            return SyncSummary(
                summaryKey: s.summaryKey,
                localDate: s.localDate,
                project: s.project,
                contentJSON: s.contentJSON,
                promptForClaude: s.promptForClaude,
                status: s.status.rawValue,
                sourceLastTimestamp: s.sourceLastTimestamp,
                sourceRawEventCount: s.sourceRawEventCount,
                errorMessage: s.errorMessage,
                updatedAt: s.lastAttemptedAt ?? s.createdAt
            )
        }
    }

    func exportNotes() throws -> [SyncNote] {
        let all = try modelContext.fetch(FetchDescriptor<UserNote>())
        return all.compactMap { n in
            guard !n.content.isEmpty else { return nil }
            return SyncNote(
                summaryKey: n.summaryKey,
                localDate: n.localDate,
                project: n.project,
                content: n.content,
                updatedAt: n.updatedAt
            )
        }
    }

    func exportLogEntries(localDate: String, project: String) throws -> [SyncLogEntry] {
        var entries: [SyncLogEntry] = []

        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        let messages = try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred))
        for m in messages {
            entries.append(SyncLogEntry(
                kind: .message,
                id: m.id,
                sessionId: m.sessionId,
                project: m.project,
                localDate: m.localDate,
                timestamp: m.timestamp,
                messageType: m.type.rawValue,
                role: m.role,
                textContent: m.textContent,
                toolName: nil,
                toolKind: nil,
                toolCallId: nil,
                inputPreview: nil,
                resultPreview: nil
            ))
        }

        let toolPred = #Predicate<ToolEvent> {
            $0.localDate == localDate && $0.project == project
        }
        let tools = try modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred))
        for t in tools {
            entries.append(SyncLogEntry(
                kind: .toolEvent,
                id: t.id,
                sessionId: t.sessionId,
                project: t.project,
                localDate: t.localDate,
                timestamp: t.timestamp,
                messageType: nil,
                role: nil,
                textContent: nil,
                toolName: t.toolName,
                toolKind: t.toolKind.rawValue,
                toolCallId: t.toolCallId,
                inputPreview: t.inputPreview,
                resultPreview: t.resultPreview
            ))
        }

        return entries
    }

    func getRawEventsForSummary(localDate: String, project: String) throws -> [RawEventForSummary] {
        let optDate: String? = localDate
        let optProject: String? = project
        let predicate = #Predicate<RawEvent> { $0.localDate == optDate && $0.project == optProject }
        let events = try modelContext.fetch(FetchDescriptor<RawEvent>(predicate: predicate))
        // Filter in Swift — SwiftData predicates with enum comparison can silently fail
        return events
            .filter { $0.parseStatus == .parsed }
            .map { RawEventForSummary(rawJSON: $0.rawJSON, eventTimestampUTC: $0.eventTimestampUTC) }
    }
}
