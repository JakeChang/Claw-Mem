import SwiftUI

struct MainView: View {
    @Environment(IngestCoordinator.self) private var ingestCoordinator
    @Environment(AppSettings.self) private var settings

    @State private var selectedProject: String?
    @State private var selectedDate: String?
    @State private var summaryGenerator = SummaryGenerator()
    @State private var filterStart: String?
    @State private var filterEnd: String?

    // Only the right column needs loaded data — summaries for the picked
    // day. Messages/tool events load lazily inside ConversationModal when
    // the user actually wants to see them.
    @State private var summaries: [SummaryInfo] = []
    @State private var lastSummaryFingerprint = ""

    private var loadKey: String {
        guard let date = selectedDate else { return "" }
        return "\(date)#\(selectedProject ?? "")"
    }

    var body: some View {
        Group {
            if ingestCoordinator.hasLoadedInitialIndex {
                loadedBody
            } else {
                loadingBody
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                IngestStatusView()
            }
        }
    }

    private var loadingBody: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("載入索引中…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadedBody: some View {
        HStack(spacing: 0) {
            ProjectsSidebar(
                selectedProject: $selectedProject,
                filterStart: $filterStart,
                filterEnd: $filterEnd
            )
            .background(Color.primary.opacity(0.02))

            Divider()

            if let project = selectedProject {
                ProjectDetailView(
                    project: project,
                    selectedDate: $selectedDate,
                    filterStart: filterStart,
                    filterEnd: filterEnd
                )
            } else {
                ContentUnavailableView(
                    "選擇專案",
                    systemImage: "folder",
                    description: Text("從左側選一個專案開始")
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }

            Divider()

            if let project = selectedProject, let date = selectedDate {
                if date == projectSummaryDate {
                    ProjectSummaryPanel(
                        project: project,
                        summary: summaries.first
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    SummaryPanel(
                        localDate: date,
                        selectedProject: project,
                        summaries: summaries
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "選日期",
                    systemImage: "calendar",
                    description: Text("在中欄月曆或清單上點選一天")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .environment(summaryGenerator)
        .task(id: loadKey) {
            guard !loadKey.isEmpty else { return }
            lastSummaryFingerprint = ""
            summaries = []
            await loadSummaries()
        }
        .onChange(of: selectedProject) { _, newProject in
            // When the user picks a new project, default the date to that
            // project's most-recent active day so the right column isn't
            // stuck empty.
            guard let newProject else {
                selectedDate = nil
                return
            }
            let lastDate = lastActiveDate(for: newProject)
            selectedDate = lastDate
        }
        .onChange(of: ingestCoordinator.dataVersion) {
            Task { await loadSummaries() }
        }
    }

    private func loadSummaries() async {
        guard let date = selectedDate else { return }

        let fetched: [SummaryInfo]
        if date == projectSummaryDate, let project = selectedProject {
            if let ps = await ingestCoordinator.fetchProjectSummary(project: project) {
                fetched = [ps]
            } else {
                fetched = []
            }
        } else {
            fetched = await ingestCoordinator.fetchSummaries(localDate: date)
        }
        guard date == selectedDate else { return }

        let statusStr = fetched.first.map { "\($0.status)" } ?? ""
        let fp = "\(fetched.count):\(fetched.first?.summaryKey ?? ""):\(fetched.first?.sourceRawEventCount ?? 0):\(statusStr):\(fetched.first?.contentJSON.count ?? 0)"
        if fp != lastSummaryFingerprint {
            summaries = fetched
            lastSummaryFingerprint = fp
        }
    }

    private func lastActiveDate(for project: String) -> String? {
        var latest: String?
        for (key, _) in ingestCoordinator.messageCountByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[1]) == project else { continue }
            let date = String(parts[0])
            if latest == nil || date > latest! {
                latest = date
            }
        }
        // Fall back to summary-only dates
        if latest == nil {
            for summaryKey in ingestCoordinator.summaryKeySet {
                let parts = summaryKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, String(parts[1]) == project else { continue }
                let date = String(parts[0])
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }
}
