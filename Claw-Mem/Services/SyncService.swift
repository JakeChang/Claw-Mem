import Foundation
import SwiftData
import os.log

nonisolated private let syncLog = Logger(subsystem: "me.jk.ClawMem", category: "Sync")

/// Filesystem layout under the user-chosen sync folder:
///
///   <folder>/
///     <date>/<project>/
///       summary.json          — one per (date, project)
///       notes.json            — one per (date, project)
///       log.<deviceID>.jsonl  — per-device Message+ToolEvent stream
///
/// Summary/note files use last-write-wins keyed on `updatedAt`.
/// Log files are per-device append-only; import dedupes by UUID so
/// redundant content across devices is harmless.
@Observable @MainActor
final class SyncService {
    var isEnabled: Bool { !folderPath.isEmpty }
    var isSyncing = false
    var lastSyncTime: Date?
    var lastError: String?
    var lastImportedCount: Int = 0
    /// Progress during a sync pass. `syncTotal` is the combined number of
    /// import + export buckets to process. Both are reset to 0 when idle.
    var syncProgress: Int = 0
    var syncTotal: Int = 0

    /// Dependencies needed by the background worker. Declared nonisolated so
    /// the detached Task inside `syncNow` can access them without bouncing
    /// back to MainActor — file I/O and JSON coding must NOT run on the UI
    /// thread or Settings/toolbar freeze during sync.
    nonisolated private let ingestActor: IngestActor
    nonisolated private let readActor: ReadActor
    nonisolated private let deviceID: String

    private weak var coordinator: IngestCoordinator?
    private var folderPath: String = ""
    private var debounceTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    /// Timestamp of our last export. FSEvents fired within this window are
    /// likely echoes of our own writes and can be safely ignored.
    private var lastExportAt: Date = .distantPast
    /// Start time of the previous successful sync. Subsequent syncs only
    /// re-export buckets whose records were modified after this moment,
    /// so steady-state syncs touch a handful of buckets instead of all 454.
    private var lastSyncStartedAt: Date?

    init(
        modelContainer: ModelContainer,
        coordinator: IngestCoordinator,
        deviceID: String
    ) {
        self.ingestActor = IngestActor(modelContainer: modelContainer)
        self.readActor = ReadActor(modelContainer: modelContainer)
        self.coordinator = coordinator
        self.deviceID = deviceID
    }

    // MARK: - Public API

    func setFolder(_ path: String) {
        folderPath = path
        watcher?.stop()
        watcher = nil
        guard !path.isEmpty else { return }

        let w = FileWatcher(watchPath: path)
        w.onChangeDetected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore FSEvents that fire while we're mid-sync; our own
                // writes cause these, and a new sync can't start until
                // `isSyncing` flips back to false anyway.
                if self.isSyncing { return }
                // Also skip echoes of our own writes from the last export.
                if Date().timeIntervalSince(self.lastExportAt) < 5 { return }
                self.scheduleSync()
            }
        }
        w.start()
        watcher = w
    }

    /// Schedules a sync after a short debounce. Safe to call many times in
    /// rapid succession (e.g. after each of several DB edits).
    func scheduleSync(delay: Duration = .seconds(2)) {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard isEnabled, !isSyncing else { return }
        guard let folder = resolveFolderURL() else {
            lastError = "同步資料夾無效：\(folderPath)"
            return
        }

        isSyncing = true
        lastError = nil
        syncProgress = 0
        syncTotal = 0

        // Capture Sendable dependencies so the detached task doesn't need
        // to touch MainActor state while working.
        let ingest = ingestActor
        let read = readActor
        let device = deviceID
        let since = lastSyncStartedAt  // used by incremental filters
        let currentSyncStart = Date()
        lastSyncStartedAt = currentSyncStart

        let setTotal: @Sendable (Int) -> Void = { [weak self] total in
            Task { @MainActor [weak self] in self?.syncTotal = total }
        }
        // Throttled progress reporter. Previous impl dispatched a MainActor
        // Task every bucket (454+ per sync) — the resulting re-render
        // storm starved scrolling. Now we keep a local counter in the
        // detached context and only bounce to main at ~10 Hz.
        let counter = ProgressCounter()
        let tickProgress: @Sendable () -> Void = { [weak self] in
            let snapshot = counter.bumpAndRead()
            guard snapshot.shouldEmit else { return }
            Task { @MainActor [weak self] in
                self?.syncProgress = snapshot.value
            }
        }
        let flushProgress: @Sendable () -> Void = { [weak self] in
            let value = counter.finalValue()
            Task { @MainActor [weak self] in self?.syncProgress = value }
        }

        // Entire sync pass runs off-main. MainActor only flips flags and
        // records results — no file I/O, no JSON coding on the UI thread.
        let outcome: (imported: Int, error: String?) = await Task.detached(priority: .userInitiated) {
            do {
                // --- Plan phase: discover all work up-front so syncTotal
                // ---  is announced ONCE and stays stable through the run.
                //     `since` lets both phases skip unchanged buckets:
                //     initial sync touches everything, incremental syncs
                //     only touch what was modified since the previous start.
                let importBuckets = Self.collectImportBuckets(from: folder, since: since)
                let exportPlan = try await Self.planExport(readActor: read, since: since)
                setTotal(importBuckets.count + exportPlan.keys.count)

                // --- Execute phase: import, then export, ticking progress.
                var imported = 0
                for url in importBuckets {
                    imported += try await Self.importOneBucket(url: url, ingestActor: ingest)
                    tickProgress()
                }
                for key in exportPlan.keys {
                    try await Self.exportOneBucket(
                        key: key,
                        plan: exportPlan,
                        folder: folder,
                        readActor: read,
                        deviceID: device
                    )
                    tickProgress()
                }
                flushProgress()  // ensure final count hits UI
                return (imported, nil)
            } catch {
                syncLog.error("Sync failed: \(error)")
                return (0, error.localizedDescription)
            }
        }.value

        lastExportAt = Date()
        lastSyncTime = Date()

        if let err = outcome.error {
            lastError = err
        } else {
            lastImportedCount = outcome.imported
            if outcome.imported > 0 {
                coordinator?.bumpDataVersionForSync()
            }
        }

        isSyncing = false
        syncProgress = 0
        syncTotal = 0
    }

    // MARK: - Background workers (nonisolated)

    /// Scan the sync folder and return every `<date>/<project>/` bucket
    /// URL whose contents were modified after `since`. Pass `nil` on the
    /// first sync to include every bucket.
    nonisolated private static func collectImportBuckets(from folder: URL, since: Date?) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path(percentEncoded: false)) else { return [] }
        var buckets: [URL] = []
        let dateDirs = (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for dateName in dateDirs {
            let dateURL = folder.appending(path: dateName)
            guard isDirectory(dateURL) else { continue }
            guard dateName.count == 10, dateName.contains("-") else { continue }
            let projectDirs = (try? fm.contentsOfDirectory(atPath: dateURL.path(percentEncoded: false))) ?? []
            for projName in projectDirs {
                let projURL = dateURL.appending(path: projName)
                guard isDirectory(projURL) else { continue }
                if let since, !bucketModified(projURL, after: since) { continue }
                buckets.append(projURL)
            }
        }
        return buckets
    }

    /// Is any file inside the bucket's directory newer than `since`?
    nonisolated private static func bucketModified(_ url: URL, after since: Date) -> Bool {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        for file in files {
            let p = url.appending(path: file).path(percentEncoded: false)
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > since {
                return true
            }
        }
        return false
    }

    nonisolated private static func importOneBucket(
        url: URL,
        ingestActor: IngestActor
    ) async throws -> Int {
        let fm = FileManager.default
        var inserted = 0

        // _deleted.json — apply tombstones FIRST so we don't re-insert data
        // from log.jsonl that was just deleted on the originating device.
        let deletedURL = url.appending(path: "_deleted.json")
        if let data = readFileSkippingICloudPlaceholder(deletedURL) {
            if let sync = try? JSONDecoder.clawMem.decode(SyncDeletion.self, from: data) {
                if try await ingestActor.importDeletion(sync) { inserted += 1 }
            }
        }

        // summary.json
        let summaryURL = url.appending(path: "summary.json")
        if let data = readFileSkippingICloudPlaceholder(summaryURL) {
            if let sync = try? JSONDecoder.clawMem.decode(SyncSummary.self, from: data) {
                if try await ingestActor.importSummary(sync) { inserted += 1 }
            }
        }

        // notes.json
        let notesURL = url.appending(path: "notes.json")
        if let data = readFileSkippingICloudPlaceholder(notesURL) {
            if let sync = try? JSONDecoder.clawMem.decode(SyncNote.self, from: data) {
                if try await ingestActor.importNote(sync) { inserted += 1 }
            }
        }

        // All log.*.jsonl (including other devices)
        let files = (try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        for file in files {
            guard file.hasPrefix("log."), file.hasSuffix(".jsonl") else { continue }
            let fileURL = url.appending(path: file)
            guard let data = readFileSkippingICloudPlaceholder(fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }

            var entries: [SyncLogEntry] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8) else { continue }
                if let entry = try? JSONDecoder.clawMem.decode(SyncLogEntry.self, from: lineData) {
                    entries.append(entry)
                }
            }

            // Chunk big log files so IngestActor releases between batches.
            // Each call to `importLogEntries` is an atomic actor task — if a
            // single call carried 5000 entries, a user-initiated delete or
            // note-save would be stuck waiting behind it. 200 per chunk lets
            // user ops sneak in without killing throughput.
            let chunkSize = 200
            for chunkStart in stride(from: 0, to: entries.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, entries.count)
                let chunk = Array(entries[chunkStart..<chunkEnd])
                let added = (try? await ingestActor.importLogEntries(chunk)) ?? 0
                inserted += added
                await Task.yield()
            }
        }

        return inserted
    }

    /// Pre-compute every `(date, project)` key that needs exporting and
    /// the lookup tables its loop will consult. When `since` is non-nil,
    /// only buckets with records newer than that moment are included —
    /// making steady-state syncs touch 2-3 buckets instead of all 454.
    nonisolated private static func planExport(
        readActor: ReadActor,
        since: Date?
    ) async throws -> ExportPlan {
        let summaries = try await readActor.exportSummaries()
        let notes = try await readActor.exportNotes()
        let deletions = try await readActor.exportDeletions()

        var keys = Set<String>()

        if let since {
            // Incremental: only include buckets whose records changed after
            // the previous sync started.
            for s in summaries where (s.updatedAt) > since {
                keys.insert(s.summaryKey)
            }
            for n in notes where n.updatedAt > since {
                keys.insert(n.summaryKey)
            }
            for d in deletions where d.deletedAt > since {
                keys.insert(d.summaryKey)
            }
            let changed = try await readActor.changedBucketKeysAfter(since)
            keys.formUnion(changed)
        } else {
            // First sync — include everything that has any data.
            for s in summaries { keys.insert(s.summaryKey) }
            for n in notes { keys.insert(n.summaryKey) }
            for d in deletions { keys.insert(d.summaryKey) }
            let index = try await readActor.getDateProjectIndex()
            for (date, projects) in index.projectsByDate {
                for project in projects {
                    keys.insert("\(date)#\(project)")
                }
            }
        }

        return ExportPlan(
            keys: Array(keys),
            summaryByKey: Dictionary(uniqueKeysWithValues: summaries.map { ($0.summaryKey, $0) }),
            noteByKey: Dictionary(uniqueKeysWithValues: notes.map { ($0.summaryKey, $0) }),
            deletionByKey: Dictionary(uniqueKeysWithValues: deletions.map { ($0.summaryKey, $0) })
        )
    }

    nonisolated private static func exportOneBucket(
        key: String,
        plan: ExportPlan,
        folder: URL,
        readActor: ReadActor,
        deviceID: String
    ) async throws {
        let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let date = String(parts[0])
        let project = String(parts[1])

        let fm = FileManager.default
        let bucketURL = folder
            .appending(path: date)
            .appending(path: sanitizePathComponent(project))
        try fm.createDirectory(at: bucketURL, withIntermediateDirectories: true)

        if let d = plan.deletionByKey[key] {
            let data = try JSONEncoder.clawMem.encode(d)
            try atomicWrite(data: data, to: bucketURL.appending(path: "_deleted.json"))
            // Tombstoned bucket — clear stragglers so the cloud folder
            // reflects the deletion. Other devices' log files stay; their
            // own tombstone imports clean them up.
            for name in ["summary.json", "notes.json", "log.\(deviceID).jsonl"] {
                let fileURL = bucketURL.appending(path: name)
                if fm.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                    try? fm.removeItem(at: fileURL)
                }
            }
            return
        }

        if let s = plan.summaryByKey[key] {
            let data = try JSONEncoder.clawMem.encode(s)
            try atomicWrite(data: data, to: bucketURL.appending(path: "summary.json"))
        }
        if let n = plan.noteByKey[key] {
            let data = try JSONEncoder.clawMem.encode(n)
            try atomicWrite(data: data, to: bucketURL.appending(path: "notes.json"))
        }

        let logEntries = try await readActor.exportLogEntries(localDate: date, project: project)
        if !logEntries.isEmpty {
            let lines = try logEntries.map { entry -> String in
                let data = try JSONEncoder.clawMem.encode(entry)
                return String(data: data, encoding: .utf8) ?? ""
            }
            let body = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
            try atomicWrite(
                data: body,
                to: bucketURL.appending(path: "log.\(deviceID).jsonl")
            )
        }
    }

    nonisolated struct ExportPlan: Sendable {
        let keys: [String]
        let summaryByKey: [String: SyncSummary]
        let noteByKey: [String: SyncNote]
        let deletionByKey: [String: SyncDeletion]
    }

    // MARK: - File helpers (all nonisolated, safe for background use)

    private func resolveFolderURL() -> URL? {
        guard !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath)
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDir
        ) else { return false }
        return isDir.boolValue
    }

    /// Reads a file's contents, returning nil (instead of throwing) if the
    /// file is an iCloud placeholder that hasn't been downloaded yet.
    nonisolated private static func readFileSkippingICloudPlaceholder(_ url: URL) -> Data? {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else {
            let dir = url.deletingLastPathComponent()
            let placeholder = dir.appending(path: ".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: placeholder.path(percentEncoded: false)) {
                return nil
            }
            return nil
        }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func atomicWrite(data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    nonisolated private static func sanitizePathComponent(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }
}

// MARK: - Progress counter

/// Tracks bucket completion count and rate-limits UI updates to ~10 Hz.
/// Used from the detached sync task to avoid storming the MainActor with
/// one Task-per-bucket, which otherwise blocked user scrolling during
/// active syncs.
nonisolated private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastEmitAt: ContinuousClock.Instant = .now

    nonisolated struct Snapshot {
        let value: Int
        let shouldEmit: Bool
    }

    nonisolated func bumpAndRead() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        let now = ContinuousClock.now
        if now - lastEmitAt >= .milliseconds(100) {
            lastEmitAt = now
            return Snapshot(value: count, shouldEmit: true)
        }
        return Snapshot(value: count, shouldEmit: false)
    }

    nonisolated func finalValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - JSON coders configured once

extension JSONEncoder {
    nonisolated static let clawMem: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    nonisolated static let clawMem: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
