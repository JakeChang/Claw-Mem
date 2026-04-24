import SwiftUI

/// Right column: AI summary + manual notes, independent scroll.
struct SummaryPanel: View {
    let localDate: String
    let selectedProject: String?
    let summaries: [SummaryInfo]

    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryGenerator.self) private var generator

    @State private var userNotes = ""
    @State private var loadedDate = ""
    @State private var loadedProject = ""
    @State private var saveTask: Task<Void, Never>?

    /// Identity of the currently-displayed note. Changes on date/project
    /// switch and drives `.task(id:)` to flush old + load new.
    private var noteIdentity: String {
        guard let project = selectedProject else { return "" }
        return "\(localDate)#\(project)"
    }

    private var currentSummary: SummaryInfo? {
        guard let project = selectedProject else { return nil }
        let key = "\(localDate)#\(project)"
        return summaries.first { $0.summaryKey == key }
    }

    private var isGeneratingThis: Bool {
        guard let project = selectedProject else { return false }
        return generator.isGeneratingFor(date: localDate, project: project)
    }

    private var streamingText: String {
        guard let project = selectedProject else { return "" }
        return generator.currentStreamingText(date: localDate, project: project)
    }

    private var summaryError: String? {
        guard let project = selectedProject else { return nil }
        return generator.currentError(date: localDate, project: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dateHeader
                SummarySection(
                    summary: currentSummary,
                    isAllProjects: selectedProject == nil,
                    isGenerating: isGeneratingThis,
                    streamingText: streamingText,
                    error: summaryError,
                    userNotes: $userNotes,
                    onGenerate: {
                        guard let project = selectedProject else { return }
                        generator.generate(
                            date: localDate,
                            project: project,
                            coordinator: coordinator,
                            settings: settings
                        )
                    },
                    onCopy: copySummaryToClaude
                )
            }
            .padding(20)
        }
        .task(id: noteIdentity) {
            // Flush pending edits to the previously-loaded (date, project)
            // before swapping in the new one.
            saveTask?.cancel()
            if !loadedProject.isEmpty &&
                (loadedDate != localDate || loadedProject != (selectedProject ?? "")) {
                await coordinator.saveNote(
                    localDate: loadedDate,
                    project: loadedProject,
                    content: userNotes
                )
            }
            loadedDate = localDate
            loadedProject = selectedProject ?? ""
            if let project = selectedProject {
                userNotes = await coordinator.fetchNote(localDate: localDate, project: project)
            } else {
                userNotes = ""
            }
        }
        .onChange(of: userNotes) { _, newValue in
            guard !loadedProject.isEmpty else { return }
            let date = loadedDate
            let project = loadedProject
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
                await coordinator.saveNote(localDate: date, project: project, content: newValue)
            }
        }
        .onDisappear {
            saveTask?.cancel()
            guard !loadedProject.isEmpty else { return }
            let date = loadedDate
            let project = loadedProject
            let content = userNotes
            Task { await coordinator.saveNote(localDate: date, project: project, content: content) }
        }
    }

    private var workSeconds: TimeInterval {
        guard let project = selectedProject else { return 0 }
        return coordinator.workHoursByDateProject["\(localDate)#\(project)"] ?? 0
    }

    private var dateHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(formatDate(localDate))
                .font(.title3.weight(.semibold))
            if isToday(localDate) {
                Text("今天")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
            if workSeconds > 0 {
                Label(formatDuration(workSeconds), systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func formatDate(_ s: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        guard let d = input.date(from: s) else { return s }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_TW")
        output.dateFormat = "yyyy/MM/dd（E）"
        return output.string(from: d)
    }

    private func isToday(_ s: String) -> Bool {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return s == f.string(from: Date())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }

    private func copySummaryToClaude() {
        guard let summary = currentSummary, !summary.promptForClaude.isEmpty else { return }
        var text = summary.promptForClaude
        if !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = text.replacingOccurrences(
                of: "---\n請根據以上進度繼續協助我開發。",
                with: "### 補充備註\n\(userNotes.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n請根據以上進度繼續協助我開發。"
            )
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Project Summary Panel

struct ProjectSummaryPanel: View {
    let project: String
    let summary: SummaryInfo?

    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(SummaryGenerator.self) private var generator

    private var isGeneratingThis: Bool {
        generator.isGeneratingFor(date: projectSummaryDate, project: project)
    }

    private var streamingText: String {
        generator.currentStreamingText(date: projectSummaryDate, project: project)
    }

    private var summaryError: String? {
        generator.currentError(date: projectSummaryDate, project: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("專案總摘要")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }

                // Actions
                HStack(alignment: .center) {
                    Label("AI 摘要", systemImage: "sparkles")
                        .font(.title3.weight(.semibold))

                    if let summary, summary.status == .fresh || summary.status == .stale {
                        Text("新鮮")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                    }

                    Spacer()

                    if let summary, !summary.promptForClaude.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary.promptForClaude, forType: .string)
                        } label: {
                            Label("複製給 Claude", systemImage: "doc.on.clipboard")
                                .font(.callout)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(action: {
                        generator.generateProjectSummary(
                            project: project,
                            coordinator: coordinator,
                            settings: settings
                        )
                    }) {
                        if isGeneratingThis {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("生成中…").font(.callout)
                            }
                        } else {
                            Label(
                                summary == nil ? "產生總摘要" : "重新產生",
                                systemImage: summary == nil ? "sparkles" : "arrow.clockwise"
                            )
                            .font(.callout)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isGeneratingThis)
                }

                // Streaming
                if isGeneratingThis && !streamingText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("AI 生成中…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(streamingText)
                            .font(.callout.monospaced())
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
                    )
                }

                // Content
                if isGeneratingThis && streamingText.isEmpty {
                    hintCard(icon: "network", text: "正在連線至 AI…")
                } else if let error = summaryError {
                    errorCard(message: error)
                } else if let summary, let content = summary.projectContent {
                    ProjectSummaryContentView(content: content)
                } else if summary?.status == .failed {
                    errorCard(message: summary?.errorMessage ?? "摘要產生失敗，請重試")
                } else {
                    hintCard(
                        icon: "doc.text.magnifyingglass",
                        text: "按下「產生總摘要」，從所有歷史每日摘要中歸納專案全貌"
                    )
                }
            }
            .padding(20)
        }
    }

    private func hintCard(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("錯誤", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Project Summary Content View

struct ProjectSummaryContentView: View {
    let content: ProjectSummaryContent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CollapsibleCard(title: "專案概述", icon: "doc.text") {
                Text(content.projectOverview)
                    .font(.body)
                    .lineSpacing(3)
            }

            if !content.techStack.isEmpty {
                CollapsibleCard(title: "技術棧", icon: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.techStack, id: \.self) { item in
                            Label(item, systemImage: "gearshape")
                                .font(.callout)
                        }
                    }
                }
            }

            if !content.milestones.isEmpty {
                CollapsibleCard(title: "里程碑", icon: "flag") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.milestones, id: \.self) { item in
                            Label(item, systemImage: "checkmark.seal")
                                .font(.callout)
                        }
                    }
                }
            }

            if !content.architecture.isEmpty {
                CollapsibleCard(title: "架構", icon: "building.columns") {
                    Text(content.architecture)
                        .font(.body)
                        .lineSpacing(3)
                }
            }

            if !content.currentState.isEmpty {
                CollapsibleCard(title: "目前狀態", icon: "location") {
                    Text(content.currentState)
                        .font(.body)
                        .lineSpacing(3)
                }
            }

            if !content.knownIssues.isEmpty {
                CollapsibleCard(title: "已知問題", icon: "ladybug") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.knownIssues, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if !content.nextSteps.isEmpty {
                CollapsibleCard(title: "下一步", icon: "arrow.forward.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.nextSteps, id: \.self) { item in
                            Label(item, systemImage: "arrow.right.circle")
                                .font(.callout)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}
