import Foundation
import SwiftData

@ModelActor
actor IngestActor {

    func ingestFile(path: String, sessionId: String, project: String) throws -> IngestResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return IngestResult(newLines: 0, errors: 0)
        }

        let attrs = try fm.attributesOfItem(atPath: path)
        let currentFileSize = (attrs[.size] as? Int64) ?? 0
        let modDate = attrs[.modificationDate] as? Date

        // Find or create SourceFile
        let predicate = #Predicate<SourceFile> { $0.path == path }
        var descriptor = FetchDescriptor<SourceFile>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor)

        let sourceFile: SourceFile
        if let sf = existing.first {
            sourceFile = sf

            if currentFileSize < sf.lastOffset {
                sf.status = .rotated
                sf.lastOffset = 0
                sf.fileSize = currentFileSize
            }

            sf.lastSeenAt = Date()
            sf.modifiedAt = modDate
            sf.fileSize = currentFileSize
        } else {
            sourceFile = SourceFile(
                path: path,
                sessionId: sessionId,
                project: project,
                lastOffset: 0,
                fileSize: currentFileSize,
                modifiedAt: modDate,
                lastSeenAt: Date(),
                ingestStatus: .idle,
                status: .active
            )
            modelContext.insert(sourceFile)
        }

        // Skip if no new data
        if sourceFile.lastOffset >= currentFileSize {
            return IngestResult(newLines: 0, errors: 0)
        }

        sourceFile.ingestStatus = .ingesting

        guard let fh = FileHandle(forReadingAtPath: path) else {
            sourceFile.ingestStatus = .failed
            try modelContext.save()
            return IngestResult(newLines: 0, errors: 0)
        }
        defer { try? fh.close() }

        try fh.seek(toOffset: UInt64(sourceFile.lastOffset))
        let newData = fh.readDataToEndOfFile()
        guard !newData.isEmpty,
              let text = String(data: newData, encoding: .utf8) else {
            sourceFile.ingestStatus = newData.isEmpty ? .success : .failed
            try modelContext.save()
            return IngestResult(newLines: 0, errors: 0)
        }

        // Drop the trailing incomplete line (JSONL flushed mid-write by
        // Claude Code). If `text` doesn't end with \n the last component
        // is a partial JSON line — processing it would log a spurious
        // `invalidJSON` error AND advance the offset past the incomplete
        // bytes, causing the remainder to be parsed as orphan bytes next
        // pass. Leave it for the next ingest.
        var lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n") && !lines.isEmpty {
            lines.removeLast()
        } else if text.hasSuffix("\n") && lines.last == "" {
            // components(separatedBy:) yields a trailing "" for text ending
            // in \n — drop it so we don't iterate a no-op line.
            lines.removeLast()
        }
        var currentOffset = sourceFile.lastOffset
        var newLineCount = 0
        var errorCount = 0

        // Batch-load tombstones for this project so we can skip events the
        // user has marked deleted without needing a per-line DB query.
        let proj = project
        let tombPred = #Predicate<DeletedRecord> { $0.project == proj }
        let tombstones = (try? modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: tombPred))) ?? []
        let tombstoneByDate: [String: Date] = Dictionary(
            uniqueKeysWithValues: tombstones.map { ($0.localDate, $0.deletedAt) }
        )

        // Batch dedupe: fetch existing dedupeKeys for this file's offset range in one query.
        // This replaces per-line queries that caused priority inversion.
        let existingKeys: Set<String>
        do {
            let filePath = path
            let startOffset = sourceFile.lastOffset
            let pred = #Predicate<RawEvent> {
                $0.sourceFilePath == filePath && $0.byteOffset >= startOffset
            }
            let desc = FetchDescriptor<RawEvent>(predicate: pred)
            existingKeys = Set(try modelContext.fetch(desc).map(\.dedupeKey))
        }

        for line in lines {
            let lineBytes = Int64(line.utf8.count)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                currentOffset += lineBytes + 1
                continue
            }

            let dedupeKey = "\(path)#\(currentOffset)"

            // Skip if already ingested (crash recovery)
            if existingKeys.contains(dedupeKey) {
                currentOffset += lineBytes + 1
                continue
            }

            // Parse raw event
            let (parsed, parseError) = Parser.parseRawEvent(
                line: trimmed,
                sourceFilePath: path,
                byteOffset: currentOffset,
                fallbackSessionId: sessionId,
                fallbackProject: project
            )

            // Tombstone check — if this event falls under a deleted
            // (date, project) and its timestamp is at or before the
            // deletion time, advance the offset but insert nothing.
            if let ld = parsed.localDate,
               let ts = parsed.eventTimestampUTC,
               let tomb = tombstoneByDate[ld],
               ts <= tomb {
                currentOffset += lineBytes + 1
                continue
            }

            if let errKind = parseError {
                let ingestErr = IngestError(
                    sourceFilePath: path,
                    byteOffset: currentOffset,
                    rawJSON: String(trimmed.prefix(500)),
                    errorKind: errKind,
                    errorMessage: "Parse error: \(errKind.rawValue)"
                )
                modelContext.insert(ingestErr)
                errorCount += 1
            }

            let rawEvent = RawEvent(
                dedupeKey: parsed.dedupeKey,
                sourceFilePath: parsed.sourceFilePath,
                byteOffset: parsed.byteOffset,
                rawJSON: parsed.rawJSON,
                lineHash: parsed.lineHash,
                parseStatus: parsed.parseStatus,
                eventTimestampUTC: parsed.eventTimestampUTC,
                eventTimestampLocal: parsed.eventTimestampLocal,
                sessionId: parsed.sessionId,
                project: parsed.project,
                localDate: parsed.localDate
            )
            modelContext.insert(rawEvent)

            // Normalize if parsed
            if parsed.parseStatus == .parsed,
               let ts = parsed.eventTimestampUTC,
               let ld = parsed.localDate {
                let sid = parsed.sessionId ?? sessionId
                let proj = parsed.project ?? project

                if let output = Parser.normalize(
                    line: trimmed,
                    sessionId: sid,
                    project: proj,
                    timestamp: ts,
                    localDateStr: ld
                ) {
                    for msg in output.messages {
                        let m = Message(
                            sessionId: msg.sessionId,
                            project: msg.project,
                            localDate: msg.localDate,
                            type: msg.type,
                            role: msg.role,
                            textContent: msg.textContent,
                            timestamp: msg.timestamp,
                            rawEventId: rawEvent.id
                        )
                        modelContext.insert(m)
                    }

                    for tool in output.toolEvents {
                        let t = ToolEvent(
                            sessionId: tool.sessionId,
                            project: tool.project,
                            localDate: tool.localDate,
                            toolCallId: tool.toolCallId,
                            toolName: tool.toolName,
                            toolKind: tool.toolKind,
                            inputPreview: tool.inputPreview,
                            timestamp: tool.timestamp,
                            rawEventId: rawEvent.id
                        )
                        modelContext.insert(t)
                    }

                    for result in output.toolResults {
                        if let toolId = result.toolCallId.nilIfEmpty {
                            let toolPred = #Predicate<ToolEvent> { $0.toolCallId == toolId }
                            var toolDesc = FetchDescriptor<ToolEvent>(predicate: toolPred)
                            toolDesc.fetchLimit = 1
                            if let matchedTool = try modelContext.fetch(toolDesc).first {
                                matchedTool.resultPreview = result.resultPreview
                            }
                        }
                    }
                }
            }

            newLineCount += 1
            currentOffset += lineBytes + 1
        }

        // Single save per file instead of every 100 lines — avoids
        // triggering @Query refreshes mid-ingest which blocks the UI.
        sourceFile.lastOffset = currentOffset
        sourceFile.lastIngestedAt = Date()
        sourceFile.ingestStatus = errorCount > 0 ? .failed : .success
        try modelContext.save()

        return IngestResult(newLines: newLineCount, errors: errorCount)
    }

    func markMissing(paths: [String]) throws {
        for path in paths {
            let predicate = #Predicate<SourceFile> { $0.path == path }
            var descriptor = FetchDescriptor<SourceFile>(predicate: predicate)
            descriptor.fetchLimit = 1
            if let sf = try modelContext.fetch(descriptor).first {
                sf.status = .missing
            }
        }
        try modelContext.save()
    }

    func getTrackedFiles() throws -> [TrackedFileInfo] {
        let descriptor = FetchDescriptor<SourceFile>()
        let files = try modelContext.fetch(descriptor)
        return files.map {
            TrackedFileInfo(path: $0.path, lastOffset: $0.lastOffset, fileSize: $0.fileSize, status: $0.status)
        }
    }

    func clearAllIngestErrors() throws {
        try modelContext.delete(model: IngestError.self)
        try modelContext.save()
    }

    func getIngestErrors(limit: Int = 50) throws -> [IngestErrorInfo] {
        var descriptor = FetchDescriptor<IngestError>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let errors = try modelContext.fetch(descriptor)
        return errors.map {
            IngestErrorInfo(
                sourceFilePath: $0.sourceFilePath,
                errorKind: $0.errorKind,
                errorMessage: $0.errorMessage,
                createdAt: $0.createdAt
            )
        }
    }

    // MARK: - Delete / tombstone

    /// Delete all DB rows for a (date, project) bucket, insert/refresh its
    /// `DeletedRecord` tombstone, and optionally remove JSONL files whose
    /// events are entirely contained within the deleted date.
    /// Returns the number of records removed in each category.
    func deleteDateProject(
        localDate: String,
        project: String,
        deviceID: String,
        alsoDeleteJSONL: Bool
    ) throws -> DeleteStats {
        let now = Date()
        var stats = DeleteStats()

        // 1. Delete Messages
        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        let msgs = try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred))
        stats.messages = msgs.count
        for m in msgs { modelContext.delete(m) }

        // 2. Delete ToolEvents
        let toolPred = #Predicate<ToolEvent> {
            $0.localDate == localDate && $0.project == project
        }
        let tools = try modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred))
        stats.toolEvents = tools.count
        for t in tools { modelContext.delete(t) }

        // 3. Delete Summary
        let key = "\(localDate)#\(project)"
        let sumPred = #Predicate<Summary> { $0.summaryKey == key }
        let summaries = try modelContext.fetch(FetchDescriptor<Summary>(predicate: sumPred))
        stats.summaries = summaries.count
        for s in summaries { modelContext.delete(s) }

        // 4. Delete UserNote
        let notePred = #Predicate<UserNote> { $0.summaryKey == key }
        let notes = try modelContext.fetch(FetchDescriptor<UserNote>(predicate: notePred))
        stats.notes = notes.count
        for n in notes { modelContext.delete(n) }

        // 5. Delete RawEvents (Optional wrappers for SwiftData predicate)
        let optDate: String? = localDate
        let optProj: String? = project
        let rawPred = #Predicate<RawEvent> {
            $0.localDate == optDate && $0.project == optProj
        }
        let raws = try modelContext.fetch(FetchDescriptor<RawEvent>(predicate: rawPred))
        stats.rawEvents = raws.count
        for r in raws { modelContext.delete(r) }

        // 6. Optional JSONL deletion — only safe for sessions whose events
        //    are entirely within the deleted date and that are not currently
        //    being written (modified within last 5 minutes).
        if alsoDeleteJSONL {
            let deletable = try safelyDeletableSourceFiles(localDate: localDate, project: project)
            let fm = FileManager.default
            for file in deletable {
                if let m = file.modifiedAt, now.timeIntervalSince(m) < 300 { continue }
                try? fm.removeItem(atPath: file.path)
                let p = file.path
                let sfPred = #Predicate<SourceFile> { $0.path == p }
                if let sf = try modelContext.fetch(FetchDescriptor<SourceFile>(predicate: sfPred)).first {
                    modelContext.delete(sf)
                    stats.sourceFilesDeleted += 1
                    stats.bytesFreed += file.fileSize
                }
            }
        }

        // 7. Upsert tombstone
        let deletedPred = #Predicate<DeletedRecord> { $0.summaryKey == key }
        if let existing = try modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: deletedPred)).first {
            existing.deletedAt = now
            existing.deviceID = deviceID
        } else {
            modelContext.insert(DeletedRecord(
                summaryKey: key,
                localDate: localDate,
                project: project,
                deletedAt: now,
                deviceID: deviceID
            ))
        }

        try modelContext.save()
        return stats
    }

    /// Returns source files (JSONL) that can be safely deleted when purging
    /// a given (date, project) bucket — i.e., all of their events fall on
    /// exactly that date. Files spanning multiple dates are excluded.
    func safelyDeletableSourceFiles(
        localDate: String,
        project: String
    ) throws -> [SafeDeleteFile] {
        // Gather session IDs that have messages in this bucket.
        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project
        }
        let sessionIds = Set(
            try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred)).map(\.sessionId)
        )

        var result: [SafeDeleteFile] = []
        for sid in sessionIds {
            // Does this session have any events on OTHER dates?
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

    @discardableResult
    func importDeletion(_ sync: SyncDeletion) throws -> Bool {
        let key = sync.summaryKey
        let existingPred = #Predicate<DeletedRecord> { $0.summaryKey == key }
        let existing = try modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: existingPred)).first

        // Ours is already newer or equal — nothing to do.
        if let existing, existing.deletedAt >= sync.deletedAt {
            return false
        }

        // Delete local records with timestamps at or before the incoming cutoff.
        let localDate = sync.localDate
        let project = sync.project
        let cutoff = sync.deletedAt

        let msgPred = #Predicate<Message> {
            $0.localDate == localDate && $0.project == project && $0.timestamp <= cutoff
        }
        for m in try modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred)) {
            modelContext.delete(m)
        }

        let toolPred = #Predicate<ToolEvent> {
            $0.localDate == localDate && $0.project == project && $0.timestamp <= cutoff
        }
        for t in try modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred)) {
            modelContext.delete(t)
        }

        // Summary/UserNote are keyed on (date, project) only — drop whole thing.
        let sumPred = #Predicate<Summary> { $0.summaryKey == key }
        for s in try modelContext.fetch(FetchDescriptor<Summary>(predicate: sumPred)) {
            modelContext.delete(s)
        }
        let notePred = #Predicate<UserNote> { $0.summaryKey == key }
        for n in try modelContext.fetch(FetchDescriptor<UserNote>(predicate: notePred)) {
            modelContext.delete(n)
        }

        // SwiftData predicates don't support `?? Date.distantPast` chained
        // with the outer boolean, so filter in Swift.
        let optDate: String? = localDate
        let optProj: String? = project
        let rawPred = #Predicate<RawEvent> {
            $0.localDate == optDate && $0.project == optProj
        }
        let matchedRaws = try modelContext.fetch(FetchDescriptor<RawEvent>(predicate: rawPred))
        for r in matchedRaws where (r.eventTimestampUTC ?? .distantPast) <= cutoff {
            modelContext.delete(r)
        }

        if let existing {
            existing.deletedAt = sync.deletedAt
            existing.deviceID = sync.deviceID
        } else {
            modelContext.insert(DeletedRecord(
                summaryKey: sync.summaryKey,
                localDate: sync.localDate,
                project: sync.project,
                deletedAt: sync.deletedAt,
                deviceID: sync.deviceID
            ))
        }
        try modelContext.save()
        return true
    }

    // MARK: - Sync import helpers

    /// Upsert a synced summary. Local wins only if it has a later
    /// `lastAttemptedAt`; otherwise the incoming copy replaces it.
    /// Returns true if a change was persisted.
    @discardableResult
    func importSummary(_ sync: SyncSummary) throws -> Bool {
        let key = sync.summaryKey

        // Tombstone check: if this (date, project) has been deleted AFTER
        // this summary's updatedAt, skip — user's deletion is newer than
        // the incoming summary.
        let tombPred = #Predicate<DeletedRecord> { $0.summaryKey == key }
        if let tomb = try modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: tombPred)).first,
           tomb.deletedAt >= sync.updatedAt {
            return false
        }

        let predicate = #Predicate<Summary> { $0.summaryKey == key }
        var descriptor = FetchDescriptor<Summary>(predicate: predicate)
        descriptor.fetchLimit = 1

        let existing = try modelContext.fetch(descriptor).first

        // Compare timestamps — local wins if newer or equal
        if let existing,
           let localTime = existing.lastAttemptedAt,
           localTime >= sync.updatedAt {
            return false
        }

        let status = SummaryStatus(rawValue: sync.status) ?? .fresh

        if let existing {
            existing.contentJSON = sync.contentJSON
            existing.promptForClaude = sync.promptForClaude
            existing.sourceLastTimestamp = sync.sourceLastTimestamp
            existing.sourceRawEventCount = sync.sourceRawEventCount
            existing.status = status
            existing.errorMessage = sync.errorMessage
            existing.lastAttemptedAt = sync.updatedAt
        } else {
            modelContext.insert(Summary(
                summaryKey: sync.summaryKey,
                localDate: sync.localDate,
                project: sync.project,
                contentJSON: sync.contentJSON,
                promptForClaude: sync.promptForClaude,
                sourceLastTimestamp: sync.sourceLastTimestamp,
                sourceRawEventCount: sync.sourceRawEventCount,
                status: status,
                errorMessage: sync.errorMessage,
                lastAttemptedAt: sync.updatedAt
            ))
        }
        try modelContext.save()
        return true
    }

    @discardableResult
    func importNote(_ sync: SyncNote) throws -> Bool {
        let key = sync.summaryKey

        // Tombstone check — same rationale as importSummary.
        let tombPred = #Predicate<DeletedRecord> { $0.summaryKey == key }
        if let tomb = try modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: tombPred)).first,
           tomb.deletedAt >= sync.updatedAt {
            return false
        }

        let predicate = #Predicate<UserNote> { $0.summaryKey == key }
        var descriptor = FetchDescriptor<UserNote>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if let existing, existing.updatedAt >= sync.updatedAt {
            return false
        }

        if let existing {
            existing.content = sync.content
            existing.updatedAt = sync.updatedAt
        } else {
            modelContext.insert(UserNote(
                summaryKey: sync.summaryKey,
                localDate: sync.localDate,
                project: sync.project,
                content: sync.content,
                updatedAt: sync.updatedAt
            ))
        }
        try modelContext.save()
        return true
    }

    /// Bulk-insert message/tool-event log entries synced from another device.
    /// Dedupes against existing records by UUID; returns the count newly
    /// inserted (for reporting in the UI).
    @discardableResult
    func importLogEntries(_ entries: [SyncLogEntry]) throws -> Int {
        guard !entries.isEmpty else { return 0 }

        // Batch fetch existing IDs to avoid N round trips
        let ids = entries.map(\.id)
        let msgPred = #Predicate<Message> { ids.contains($0.id) }
        let existingMsgIDs = try Set(modelContext.fetch(FetchDescriptor<Message>(predicate: msgPred)).map(\.id))
        let toolPred = #Predicate<ToolEvent> { ids.contains($0.id) }
        let existingToolIDs = try Set(modelContext.fetch(FetchDescriptor<ToolEvent>(predicate: toolPred)).map(\.id))

        // Batch-load tombstones for every (date, project) appearing in this
        // chunk so we can skip re-importing records the user just deleted.
        // Without this check, sync races the deletion and resurrects data.
        let keys = Set(entries.map { "\($0.localDate)#\($0.project)" })
        let tombPred = #Predicate<DeletedRecord> { keys.contains($0.summaryKey) }
        let tombstones = try modelContext.fetch(FetchDescriptor<DeletedRecord>(predicate: tombPred))
        let tombstoneByKey: [String: Date] = Dictionary(
            uniqueKeysWithValues: tombstones.map { ($0.summaryKey, $0.deletedAt) }
        )

        var inserted = 0
        for entry in entries {
            let key = "\(entry.localDate)#\(entry.project)"
            if let tomb = tombstoneByKey[key], entry.timestamp <= tomb {
                continue
            }

            switch entry.kind {
            case .message:
                if existingMsgIDs.contains(entry.id) { continue }
                guard let typeRaw = entry.messageType,
                      let type = MessageType(rawValue: typeRaw) else { continue }
                modelContext.insert(Message(
                    id: entry.id,
                    sessionId: entry.sessionId,
                    project: entry.project,
                    localDate: entry.localDate,
                    type: type,
                    role: entry.role,
                    textContent: entry.textContent,
                    timestamp: entry.timestamp,
                    rawEventId: UUID()  // no local RawEvent for synced entries
                ))
                inserted += 1

            case .toolEvent:
                if existingToolIDs.contains(entry.id) { continue }
                guard let name = entry.toolName,
                      let kindRaw = entry.toolKind,
                      let kind = ToolKind(rawValue: kindRaw) else { continue }
                modelContext.insert(ToolEvent(
                    id: entry.id,
                    sessionId: entry.sessionId,
                    project: entry.project,
                    localDate: entry.localDate,
                    toolCallId: entry.toolCallId,
                    toolName: name,
                    toolKind: kind,
                    inputPreview: entry.inputPreview,
                    resultPreview: entry.resultPreview,
                    timestamp: entry.timestamp,
                    rawEventId: UUID()
                ))
                inserted += 1
            }
        }

        if inserted > 0 {
            try modelContext.save()
        }
        return inserted
    }

    func saveNote(
        summaryKey: String,
        localDate: String,
        project: String,
        content: String
    ) throws {
        let key = summaryKey
        let predicate = #Predicate<UserNote> { $0.summaryKey == key }
        var descriptor = FetchDescriptor<UserNote>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if content.isEmpty {
            if let existing { modelContext.delete(existing) }
        } else if let existing {
            existing.content = content
            existing.updatedAt = Date()
        } else {
            modelContext.insert(UserNote(
                summaryKey: summaryKey,
                localDate: localDate,
                project: project,
                content: content
            ))
        }
        try modelContext.save()
    }

    func saveSummary(
        localDate: String,
        project: String,
        contentJSON: String,
        promptForClaude: String,
        sourceLastTimestamp: Date?,
        sourceRawEventCount: Int,
        status: SummaryStatus,
        errorMessage: String? = nil
    ) throws {
        let key = "\(localDate)#\(project)"
        let predicate = #Predicate<Summary> { $0.summaryKey == key }
        var descriptor = FetchDescriptor<Summary>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.contentJSON = contentJSON
            existing.promptForClaude = promptForClaude
            existing.sourceLastTimestamp = sourceLastTimestamp
            existing.sourceRawEventCount = sourceRawEventCount
            existing.status = status
            existing.errorMessage = errorMessage
            existing.lastAttemptedAt = Date()
        } else {
            let summary = Summary(
                summaryKey: key,
                localDate: localDate,
                project: project,
                contentJSON: contentJSON,
                promptForClaude: promptForClaude,
                sourceLastTimestamp: sourceLastTimestamp,
                sourceRawEventCount: sourceRawEventCount,
                status: status,
                errorMessage: errorMessage,
                lastAttemptedAt: Date()
            )
            modelContext.insert(summary)
        }
        try modelContext.save()
    }
}

struct IngestResult: Sendable {
    let newLines: Int
    let errors: Int
}

struct TrackedFileInfo: Sendable {
    let path: String
    let lastOffset: Int64
    let fileSize: Int64
    let status: SourceFileStatus
}

struct IngestErrorInfo: Sendable {
    let sourceFilePath: String
    let errorKind: IngestErrorKind
    let errorMessage: String
    let createdAt: Date
}

nonisolated struct DeleteStats: Sendable {
    var messages: Int = 0
    var toolEvents: Int = 0
    var summaries: Int = 0
    var notes: Int = 0
    var rawEvents: Int = 0
    var sourceFilesDeleted: Int = 0
    var bytesFreed: Int64 = 0
}

nonisolated struct SafeDeleteFile: Sendable {
    let path: String
    let sessionId: String
    let fileSize: Int64
    let modifiedAt: Date?
}

struct StaleSummaryInfo: Sendable {
    let rawEventCount: Int
    let lastTimestamp: Date?
}

struct RawEventForSummary: Sendable {
    let rawJSON: String
    let eventTimestampUTC: Date?
}

struct DateProjectIndex: Sendable {
    let dates: [String]
    let projectsByDate: [String: [String]]
    let summaryCountByDate: [String: Int]
    let messageCountByDateProject: [String: Int] // key: "date#project"
    let summaryKeySet: Set<String> // keys: "date#project" that have fresh/stale summary
    let workHoursByDateProject: [String: TimeInterval] // key: "date#project" → seconds
}

struct MessageInfo: Sendable, Identifiable {
    let id: UUID
    let project: String
    let type: MessageType
    let textContent: String?
    let timestamp: Date
}

struct ToolEventInfo: Sendable, Identifiable {
    let id: UUID
    let project: String
    let toolName: String
    let toolKind: ToolKind
    let toolCallId: String?
    let inputPreview: String?
    let resultPreview: String?
    let timestamp: Date
}

struct SummaryInfo: Sendable, Identifiable {
    var id: String { summaryKey }
    let summaryKey: String
    let localDate: String
    let project: String
    let contentJSON: String
    let promptForClaude: String
    let sourceLastTimestamp: Date?
    let sourceRawEventCount: Int
    let status: SummaryStatus
    let errorMessage: String?

    var content: SummaryContent? {
        guard let data = contentJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SummaryContent.self, from: data)
    }

    var projectContent: ProjectSummaryContent? {
        guard localDate == projectSummaryDate,
              let data = contentJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProjectSummaryContent.self, from: data)
    }
}

extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
