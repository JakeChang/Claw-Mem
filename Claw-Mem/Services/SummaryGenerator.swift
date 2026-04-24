import Foundation

/// Holds AI summary generation state. Lives in MainView, survives date/project switches.
@Observable @MainActor
final class SummaryGenerator {
    var isGenerating = false
    var streamingText = ""
    var error: String?
    /// Which date+project is currently generating
    var generatingKey: String?

    private var generationTask: Task<Void, Never>?

    var generatingDate: String? {
        guard isGenerating, let key = generatingKey else { return nil }
        return key.components(separatedBy: "#").first
    }

    var generatingProject: String? {
        guard isGenerating, let key = generatingKey else { return nil }
        let parts = key.components(separatedBy: "#")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "#") : nil
    }

    func isGeneratingFor(date: String, project: String) -> Bool {
        isGenerating && generatingKey == "\(date)#\(project)"
    }

    func isGeneratingForDate(_ date: String) -> Bool {
        isGenerating && generatingDate == date
    }

    func currentStreamingText(date: String, project: String) -> String {
        isGeneratingFor(date: date, project: project) ? streamingText : ""
    }

    func currentError(date: String, project: String) -> String? {
        generatingKey == "\(date)#\(project)" ? error : nil
    }

    func generate(
        date: String,
        project: String,
        coordinator: IngestCoordinator,
        settings: AppSettings
    ) {
        if isGenerating {
            generationTask?.cancel()
            generationTask = nil
            isGenerating = false
            streamingText = ""
        }
        guard settings.hasAPIKey else {
            error = "請先在設定中設定 Gemini API Key"
            generatingKey = "\(date)#\(project)"
            return
        }

        isGenerating = true
        error = nil
        streamingText = ""
        generatingKey = "\(date)#\(project)"

        generationTask = Task(priority: .utility) {
            guard let info = await coordinator.getStaleSummaryInfo(localDate: date, project: project) else {
                error = "無法取得資料"
                isGenerating = false
                return
            }

            guard info.lastTimestamp != nil else {
                error = "無法判定資料時間，請確認來源格式"
                isGenerating = false
                return
            }

            async let msgsFetch = coordinator.fetchMessages(localDate: date, project: project)
            async let toolsFetch = coordinator.fetchToolEvents(localDate: date, project: project)
            let (messages, toolEvents) = await (msgsFetch, toolsFetch)
            let context = Summarizer.buildPromptContext(
                messages: messages,
                toolEvents: toolEvents
            )
            let prompt = Summarizer.buildPrompt(
                date: date,
                project: project,
                context: context,
                language: settings.summaryLanguage.rawValue
            )

            do {
                let content = try await Summarizer.callGeminiStreaming(
                    prompt: prompt,
                    apiKey: settings.geminiAPIKey,
                    model: settings.geminiModel,
                    onChunk: { [weak self] text in
                        self?.streamingText = text
                    }
                )

                streamingText = ""
                let contentData = try JSONEncoder().encode(content)
                let contentJSON = String(data: contentData, encoding: .utf8) ?? ""
                let claudePrompt = Summarizer.buildClaudePrompt(
                    date: date,
                    project: project,
                    content: content
                )

                await coordinator.saveSummary(
                    localDate: date,
                    project: project,
                    contentJSON: contentJSON,
                    promptForClaude: claudePrompt,
                    sourceLastTimestamp: info.lastTimestamp,
                    sourceRawEventCount: info.rawEventCount,
                    status: .fresh
                )
                error = nil
            } catch {
                streamingText = ""
                print("[ClawMem] Summary error: \(error)")
                self.error = "\(error)"
                await coordinator.saveSummary(
                    localDate: date,
                    project: project,
                    contentJSON: "",
                    promptForClaude: "",
                    sourceLastTimestamp: info.lastTimestamp,
                    sourceRawEventCount: info.rawEventCount,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }

            isGenerating = false
        }
    }

    func generateProjectSummary(
        project: String,
        coordinator: IngestCoordinator,
        settings: AppSettings
    ) {
        if isGenerating {
            generationTask?.cancel()
            generationTask = nil
            isGenerating = false
            streamingText = ""
        }
        guard settings.hasAPIKey else {
            error = "請先在設定中設定 Gemini API Key"
            generatingKey = "\(projectSummaryDate)#\(project)"
            return
        }

        isGenerating = true
        error = nil
        streamingText = ""
        generatingKey = "\(projectSummaryDate)#\(project)"

        generationTask = Task(priority: .utility) {
            let allSummaries = await coordinator.fetchAllSummariesForProject(project)
            let validSummaries = allSummaries.filter { $0.status == .fresh || $0.status == .stale }

            guard !validSummaries.isEmpty else {
                self.error = "此專案尚無任何每日摘要，請先產生每日摘要"
                isGenerating = false
                return
            }

            let context = Summarizer.buildProjectSummaryContext(summaries: validSummaries)
            let prompt = Summarizer.buildProjectSummaryPrompt(
                project: project,
                context: context,
                language: settings.summaryLanguage.rawValue
            )

            do {
                let rawJSON = try await Summarizer.callGeminiStreamingRaw(
                    prompt: prompt,
                    apiKey: settings.geminiAPIKey,
                    model: settings.geminiModel,
                    onChunk: { [weak self] text in
                        self?.streamingText = text
                    }
                )

                streamingText = ""

                guard let data = rawJSON.data(using: .utf8) else {
                    throw SummarizerError.parseError("Empty response")
                }
                let projectContent = try JSONDecoder().decode(ProjectSummaryContent.self, from: data)
                let contentData = try JSONEncoder().encode(projectContent)
                let contentJSON = String(data: contentData, encoding: .utf8) ?? ""
                let claudePrompt = Summarizer.buildProjectClaudePrompt(
                    project: project,
                    content: projectContent
                )

                await coordinator.saveSummary(
                    localDate: projectSummaryDate,
                    project: project,
                    contentJSON: contentJSON,
                    promptForClaude: claudePrompt,
                    sourceLastTimestamp: Date(),
                    sourceRawEventCount: validSummaries.count,
                    status: .fresh
                )
                error = nil
            } catch {
                streamingText = ""
                print("[ClawMem] Project summary error: \(error)")
                self.error = "\(error)"
                await coordinator.saveSummary(
                    localDate: projectSummaryDate,
                    project: project,
                    contentJSON: "",
                    promptForClaude: "",
                    sourceLastTimestamp: Date(),
                    sourceRawEventCount: validSummaries.count,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }

            isGenerating = false
        }
    }
}
