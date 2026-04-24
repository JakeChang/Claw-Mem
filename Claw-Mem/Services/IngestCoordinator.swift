import Foundation
import SwiftData
import os.log

nonisolated private let log = Logger(subsystem: "me.jk.ClawMem", category: "Ingest")

@Observable @MainActor
final class IngestCoordinator {
    var lastIngestTime: Date?
    var isIngesting = false
    var hasErrors = false
    var errorCount = 0
    var recentErrors: [IngestErrorInfo] = []
    var availableDates: [String] = []
    var projectsByDate: [String: [String]] = [:]
    var summaryCountByDate: [String: Int] = [:]
    var messageCountByDateProject: [String: Int] = [:]
    var summaryKeySet: Set<String> = []
    var workHoursByDateProject: [String: TimeInterval] = [:]
    /// Bumps on ANY data change — local user action OR sync import — so
    /// UI panels (MainView, SummaryPanel) reload their data.
    var dataVersion: Int = 0
    /// Bumps only on LOCAL changes (ingest, save, delete). Used to drive
    /// `SyncService.scheduleSync()` without causing a sync→refresh→sync
    /// feedback loop when imported remote data updates `dataVersion`.
    var localDataVersion: Int = 0
    var ingestProgress: Int = 0
    var ingestTotal: Int = 0

    private let ingestActor: IngestActor
    private let readActor: ReadActor
    private let rescanCoordinator: RescanCoordinator
    private let fileWatcher: FileWatcher
    private var ingestTask: Task<Void, Never>?
    /// Set when a file-change event arrives while ingest is already running.
    /// Triggers a follow-up ingest so we don't miss edits made during the
    /// previous pass.
    private var pendingIngest = false

    init(modelContainer: ModelContainer, watchPath: String = NSHomeDirectory() + "/.claude/projects") {
        self.ingestActor = IngestActor(modelContainer: modelContainer)
        self.readActor = ReadActor(modelContainer: modelContainer)
        self.rescanCoordinator = RescanCoordinator(watchPath: watchPath)
        self.fileWatcher = FileWatcher(watchPath: watchPath)

        self.fileWatcher.onChangeDetected = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.runIngest()
            }
        }
    }

    func startWatching() {
        fileWatcher.start()
        // Show previously-indexed data immediately so the UI is usable
        // while background ingest runs.
        Task { await refreshFromDB() }
        runIngest()
    }

    /// Read the current index from DB without running ingest. Lets the UI
    /// render previous session's data on launch instead of waiting for
    /// the full ingest pipeline.
    private func refreshFromDB() async {
        do {
            let index = try await readActor.getDateProjectIndex()
            let errors = try await readActor.getIngestErrors(limit: 20)
            applyIndex(index)
            self.recentErrors = errors
            self.errorCount = errors.count
            self.hasErrors = !errors.isEmpty
            self.dataVersion += 1
        } catch {
            log.error("Failed to refresh index from DB: \(error)")
        }
    }

    /// Called by SyncService after imports so the UI refreshes its index
    /// (left sidebar, available dates, message counts) without having to
    /// re-run the full ingest pipeline.
    func bumpDataVersionForSync() {
        Task { await refreshFromDB() }
    }

    private func applyIndex(_ index: DateProjectIndex) {
        // Only assign properties that actually changed — each @Observable
        // write notifies subscribers and triggers SwiftUI re-renders. After
        // a sync that didn't really move data, applying the same snapshot
        // blindly fired redundant re-renders that stuttered scrolling.
        if self.availableDates != index.dates {
            self.availableDates = index.dates
        }
        if self.projectsByDate != index.projectsByDate {
            self.projectsByDate = index.projectsByDate
        }
        if self.summaryCountByDate != index.summaryCountByDate {
            self.summaryCountByDate = index.summaryCountByDate
        }
        if self.messageCountByDateProject != index.messageCountByDateProject {
            self.messageCountByDateProject = index.messageCountByDateProject
        }
        if self.summaryKeySet != index.summaryKeySet {
            self.summaryKeySet = index.summaryKeySet
        }
        if self.workHoursByDateProject != index.workHoursByDateProject {
            self.workHoursByDateProject = index.workHoursByDateProject
        }
    }

    func stopWatching() {
        fileWatcher.stop()
        ingestTask?.cancel()
        ingestTask = nil
    }

    func runIngest() {
        if isIngesting {
            pendingIngest = true
            return
        }
        isIngesting = true
        pendingIngest = false
        ingestProgress = 0
        ingestTotal = 0

        let ingest = ingestActor
        let read = readActor
        let coordinator = rescanCoordinator

        // Detached at userInitiated priority — cancelled on stopWatching().
        // Originally .utility, but the mid-ingest ReadActor refresh would
        // queue behind MainView's user-interactive fetches and trigger
        // priority-inversion warnings. userInitiated puts ingest close enough
        // to the UI thread that Swift's executor no longer flags waits as
        // inversions, while still yielding to true userInteractive work.
        ingestTask = Task.detached(priority: .userInitiated) { @Sendable [weak self] in
            // 1. Discover files, processing newest-modified first so today's
            // sessions surface in the UI before old files finish.
            let allDiscovered = coordinator.discoverJSONLFiles().sorted { a, b in
                (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast)
            }
            let discoveredPaths = Set(allDiscovered.map(\.path))

            // 2. Fetch tracked offsets + mark missing in the same pass.
            var offsetByPath: [String: Int64] = [:]
            do {
                let tracked = try await ingest.getTrackedFiles()
                offsetByPath = Dictionary(uniqueKeysWithValues: tracked.map { ($0.path, $0.lastOffset) })
                let missingPaths = tracked
                    .filter { $0.status == .active && !discoveredPaths.contains($0.path) }
                    .map(\.path)
                if !missingPaths.isEmpty {
                    try await ingest.markMissing(paths: missingPaths)
                }
            } catch {
                log.error("Failed to track/mark missing files: \(error)")
            }

            // 3. Filter down to files that actually have new bytes to read.
            // Unchanged files short-circuit in ingestFile() anyway, but
            // counting them against `ingestTotal` makes the progress bar
            // reset to 0/N on every FileWatcher trigger — looks alarming.
            let files = allDiscovered.filter { file in
                let lastOffset = offsetByPath[file.path] ?? 0
                return file.fileSize > lastOffset
            }

            await MainActor.run { [weak self] in
                self?.ingestTotal = files.count
            }

            // Early-exit if nothing to ingest; still run a final refresh so
            // any stale UI state gets cleared.
            guard !files.isEmpty else {
                guard let self else { return }
                await MainActor.run { [self] in
                    self.lastIngestTime = Date()
                    self.isIngesting = false
                    self.ingestProgress = 0
                    self.ingestTotal = 0
                    if self.pendingIngest {
                        self.pendingIngest = false
                        self.runIngest()
                    }
                }
                return
            }

            // 4. Ingest files. Files are sorted newest-first so the first
            // batch covers today/recent days. After that batch we do a
            // single UI refresh so current-day data surfaces quickly,
            // then the bulk historical ingest continues silently until
            // the final refresh at the end.
            let earlyRefreshAt = min(100, files.count)
            for (i, file) in files.enumerated() {
                do {
                    _ = try await ingest.ingestFile(
                        path: file.path,
                        sessionId: file.sessionId,
                        project: file.project
                    )
                } catch {
                    log.error("Failed to ingest \(file.path): \(error)")
                }

                let progress = i + 1
                await MainActor.run { [weak self] in
                    self?.ingestProgress = progress
                }

                if progress == earlyRefreshAt {
                    if let partial = try? await read.getDateProjectIndex() {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.applyIndex(partial)
                            self.dataVersion += 1
                        }
                    }
                }
            }

            // 4. Final read of indexes + errors
            let finalIndex: DateProjectIndex?
            do {
                finalIndex = try await read.getDateProjectIndex()
            } catch {
                log.error("Failed to read index: \(error)")
                finalIndex = nil
            }
            let finalErrors: [IngestErrorInfo]
            do {
                finalErrors = try await read.getIngestErrors(limit: 20)
            } catch {
                log.error("Failed to read ingest errors: \(error)")
                finalErrors = []
            }

            // 5. Update UI on MainActor
            guard let self else { return }
            await MainActor.run { [self] in
                if let finalIndex {
                    self.applyIndex(finalIndex)
                }
                self.recentErrors = finalErrors
                self.errorCount = finalErrors.count
                self.hasErrors = !finalErrors.isEmpty
                self.lastIngestTime = Date()
                self.dataVersion += 1
                self.localDataVersion += 1
                self.isIngesting = false
                self.ingestProgress = 0
                self.ingestTotal = 0

                // If file changes arrived during this pass, catch them now.
                if self.pendingIngest {
                    self.pendingIngest = false
                    self.runIngest()
                }
            }
        }
    }

    // MARK: - Read operations (via ReadActor, never blocks on ingest)

    func fetchMessages(localDate: String, project: String? = nil) async -> [MessageInfo] {
        (try? await readActor.getMessagesForDate(localDate, project: project)) ?? []
    }

    func fetchToolEvents(localDate: String, project: String? = nil) async -> [ToolEventInfo] {
        (try? await readActor.getToolEventsForDate(localDate, project: project)) ?? []
    }

    func fetchSummaries(localDate: String) async -> [SummaryInfo] {
        (try? await readActor.getSummariesForDate(localDate)) ?? []
    }

    func getStaleSummaryInfo(localDate: String, project: String) async -> StaleSummaryInfo? {
        try? await readActor.getStaleSummaryInfo(localDate: localDate, project: project)
    }

    func getRawEventsForSummary(localDate: String, project: String) async -> [RawEventForSummary] {
        (try? await readActor.getRawEventsForSummary(localDate: localDate, project: project)) ?? []
    }

    func fetchAllSummariesForProject(_ project: String) async -> [SummaryInfo] {
        (try? await readActor.getAllSummariesForProject(project)) ?? []
    }

    func fetchProjectSummary(project: String) async -> SummaryInfo? {
        try? await readActor.getProjectSummary(project: project)
    }

    // MARK: - Delete

    func getDeleteStats(localDate: String, project: String) async -> DeleteStats? {
        try? await readActor.getDeleteStats(localDate: localDate, project: project)
    }

    func getSafelyDeletableSourceFiles(
        localDate: String,
        project: String
    ) async -> [SafeDeleteFile] {
        (try? await readActor.safelyDeletableSourceFiles(localDate: localDate, project: project)) ?? []
    }

    func deleteDateProject(
        localDate: String,
        project: String,
        deviceID: String,
        alsoDeleteJSONL: Bool
    ) async -> DeleteStats? {
        do {
            let stats = try await ingestActor.deleteDateProject(
                localDate: localDate,
                project: project,
                deviceID: deviceID,
                alsoDeleteJSONL: alsoDeleteJSONL
            )
            // Re-read the index so CalendarSidebar's projectsByDate /
            // availableDates reflect the deletion — `dataVersion += 1`
            // alone only nudges MainView's data reload.
            await refreshFromDB()
            localDataVersion += 1
            return stats
        } catch {
            log.error("Failed to delete \(localDate)#\(project): \(error)")
            return nil
        }
    }

    func clearIngestErrors() async {
        try? await ingestActor.clearAllIngestErrors()
        recentErrors = []
        errorCount = 0
        hasErrors = false
    }

    func fetchNote(localDate: String, project: String) async -> String {
        let key = "\(localDate)#\(project)"
        return (try? await readActor.getNote(summaryKey: key)) ?? ""
    }

    func saveNote(localDate: String, project: String, content: String) async {
        let key = "\(localDate)#\(project)"
        do {
            try await ingestActor.saveNote(
                summaryKey: key,
                localDate: localDate,
                project: project,
                content: content
            )
            dataVersion += 1
            localDataVersion += 1
        } catch {
            log.error("Failed to save note for \(key): \(error)")
        }
    }

    // MARK: - Write operations (via IngestActor)

    func saveSummary(
        localDate: String,
        project: String,
        contentJSON: String,
        promptForClaude: String,
        sourceLastTimestamp: Date?,
        sourceRawEventCount: Int,
        status: SummaryStatus,
        errorMessage: String? = nil
    ) async {
        var saved = false
        do {
            try await ingestActor.saveSummary(
                localDate: localDate,
                project: project,
                contentJSON: contentJSON,
                promptForClaude: promptForClaude,
                sourceLastTimestamp: sourceLastTimestamp,
                sourceRawEventCount: sourceRawEventCount,
                status: status,
                errorMessage: errorMessage
            )
            saved = true
        } catch {
            log.error("Failed to save summary for \(localDate)#\(project): \(error)")
        }
        // When a summary is newly fresh/stale, mirror it into the in-memory
        // index so CalendarSidebar's ✨ icon appears immediately — without
        // this, the icon only updated on the next full index refresh.
        if saved, status == .fresh || status == .stale {
            let key = "\(localDate)#\(project)"
            let wasPresent = summaryKeySet.contains(key)
            summaryKeySet.insert(key)
            if !wasPresent {
                summaryCountByDate[localDate, default: 0] += 1
            }
        }
        dataVersion += 1
        localDataVersion += 1
    }
}
