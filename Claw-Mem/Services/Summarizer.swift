import Foundation

struct Summarizer: Sendable {

    /// Builds prompt context from normalized Message/ToolEvent instead of
    /// RawEvent. Used when regenerating AI across synced machines, where
    /// raw source JSONL is not available but Message/ToolEvent have been
    /// synced from the originating device.
    static func buildPromptContext(
        messages: [MessageInfo],
        toolEvents: [ToolEventInfo]
    ) -> String {
        struct Entry {
            let timestamp: Date
            let text: String
        }

        var entries: [Entry] = []

        for msg in messages {
            guard let text = msg.textContent, !text.isEmpty else { continue }
            switch msg.type {
            case .user:
                let truncated = text.count > 800 ? String(text.prefix(800)) + "…（截斷）" : text
                entries.append(Entry(timestamp: msg.timestamp, text: "[USER] \(truncated)"))
            case .assistant:
                let truncated = text.count > 600 ? String(text.prefix(600)) + "…" : text
                entries.append(Entry(timestamp: msg.timestamp, text: "[ASSISTANT] \(truncated)"))
            case .toolResult, .system:
                break
            }
        }

        for tool in toolEvents {
            let name = tool.toolName
            // Match the old filter: only keep significant tool calls
            let isSignificant = name == "Edit" || name == "Write"
                || name == "Bash" || name.contains("Agent")
                || name.hasPrefix("Edit") || name.hasPrefix("Write")
            if !isSignificant { continue }
            let preview = extractToolInputSummary(fromInputPreview: tool.inputPreview, toolName: name)
            entries.append(Entry(timestamp: tool.timestamp, text: "  [TOOL:\(name)] \(preview)"))
        }

        entries.sort { $0.timestamp < $1.timestamp }
        let allEntries = entries.map(\.text)
        return sampleWithinBudget(entries: allEntries)
    }

    /// Internal helper — extracts the same head/mid/tail sampling we use
    /// for the RawEvent-based path, reusable by both overloads.
    private static func sampleWithinBudget(entries allEntries: [String]) -> String {
        let limit = 30000
        let joined = allEntries.joined(separator: "\n")
        if joined.count <= limit {
            return joined
        }

        let headBudget = limit * 3 / 10
        let midBudget = limit * 3 / 10
        let tailBudget = limit * 4 / 10

        var headChars = 0
        var headEnd = 0
        for (i, entry) in allEntries.enumerated() {
            if headChars + entry.count > headBudget { break }
            headChars += entry.count + 1
            headEnd = i + 1
        }

        var tailChars = 0
        var tailStart = allEntries.count
        for i in stride(from: allEntries.count - 1, through: 0, by: -1) {
            if tailChars + allEntries[i].count > tailBudget { break }
            tailChars += allEntries[i].count + 1
            tailStart = i
        }
        tailStart = max(tailStart, headEnd)

        var midParts: [String] = []
        var midChars = 0
        let midRange = headEnd..<tailStart
        if !midRange.isEmpty {
            let step = max(1, midRange.count / max(1, midBudget / 200))
            var i = midRange.lowerBound
            while i < midRange.upperBound {
                let entry = allEntries[i]
                if midChars + entry.count > midBudget { break }
                midParts.append(entry)
                midChars += entry.count + 1
                i += step
            }
        }

        var result = allEntries[0..<headEnd].joined(separator: "\n")
        if !midParts.isEmpty {
            result += "\n\n…（略過部分紀錄）…\n\n" + midParts.joined(separator: "\n")
        }
        if tailStart < allEntries.count {
            result += "\n\n…（略過部分紀錄）…\n\n" + allEntries[tailStart...].joined(separator: "\n")
        }
        return result
    }

    private static func extractToolInputSummary(fromInputPreview preview: String?, toolName: String) -> String {
        guard let preview, !preview.isEmpty else { return "" }
        guard let data = preview.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(preview.prefix(200))
        }
        return extractToolInputSummary(dict, toolName: toolName)
    }

    static func buildPromptContext(rawEvents: [RawEventForSummary]) -> String {
        // Sort by timestamp for chronological order
        let sorted = rawEvents.sorted {
            ($0.eventTimestampUTC ?? .distantPast) < ($1.eventTimestampUTC ?? .distantPast)
        }

        // First pass: collect all entries
        var allEntries: [String] = []

        for event in sorted {
            guard let data = event.rawJSON.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let eventType = json["type"] as? String ?? "unknown"

            switch eventType {
            case "user":
                if let message = json["message"] as? [String: Any] {
                    let text = extractUserText(from: message)
                    if !text.isEmpty {
                        // Keep error messages and short prompts in full; truncate long specs
                        let truncated = text.count > 800 ? String(text.prefix(800)) + "…（截斷）" : text
                        allEntries.append("[USER] \(truncated)")
                    }
                }

            case "assistant":
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {

                    var textParts: [String] = []
                    var toolParts: [String] = []

                    for block in content {
                        let blockType = block["type"] as? String
                        if blockType == "text", let text = block["text"] as? String {
                            // Keep more assistant text — this contains fix explanations
                            let truncated = text.count > 600 ? String(text.prefix(600)) + "…" : text
                            textParts.append(truncated)
                        } else if blockType == "tool_use" {
                            let name = block["name"] as? String ?? "unknown"
                            let preview = extractToolInputSummary(block["input"], toolName: name)
                            toolParts.append("  [TOOL:\(name)] \(preview)")
                        }
                    }

                    if !textParts.isEmpty {
                        allEntries.append("[ASSISTANT] \(textParts.joined(separator: "\n"))")
                    }
                    for toolPart in toolParts {
                        if toolPart.contains("Edit") || toolPart.contains("Write")
                            || toolPart.contains("Bash") || toolPart.contains("Agent") {
                            allEntries.append(toolPart)
                        }
                    }
                }

            default:
                break
            }
        }

        // Second pass: fit within token budget, sampling evenly across the day
        let limit = 30000
        let joined = allEntries.joined(separator: "\n")
        if joined.count <= limit {
            return joined
        }

        // Evenly sample: keep head 30%, middle 30%, tail 40%
        let headBudget = limit * 3 / 10
        let midBudget = limit * 3 / 10
        let tailBudget = limit * 4 / 10

        // Head
        var headChars = 0
        var headEnd = 0
        for (i, entry) in allEntries.enumerated() {
            if headChars + entry.count > headBudget { break }
            headChars += entry.count + 1
            headEnd = i + 1
        }

        // Tail
        var tailChars = 0
        var tailStart = allEntries.count
        for i in stride(from: allEntries.count - 1, through: 0, by: -1) {
            if tailChars + allEntries[i].count > tailBudget { break }
            tailChars += allEntries[i].count + 1
            tailStart = i
        }
        tailStart = max(tailStart, headEnd)

        // Middle (sample from between head and tail)
        var midParts: [String] = []
        var midChars = 0
        let midRange = headEnd..<tailStart
        if !midRange.isEmpty {
            let step = max(1, midRange.count / max(1, midBudget / 200))
            var i = midRange.lowerBound
            while i < midRange.upperBound {
                let entry = allEntries[i]
                if midChars + entry.count > midBudget { break }
                midParts.append(entry)
                midChars += entry.count + 1
                i += step
            }
        }

        var result = allEntries[0..<headEnd].joined(separator: "\n")
        if !midParts.isEmpty {
            result += "\n\n…（略過部分紀錄）…\n\n" + midParts.joined(separator: "\n")
        }
        if tailStart < allEntries.count {
            result += "\n\n…（略過部分紀錄）…\n\n" + allEntries[tailStart...].joined(separator: "\n")
        }
        return result
    }

    static func buildPrompt(date: String, project: String, context: String, language: String) -> String {
        """
        你是工程師的工作記憶助手。以下是某工程師在 \(date) 於專案 \(project) 的工作紀錄。

        請輸出 JSON，格式如下：
        {
          "schemaVersion": 1,
          "overview": "...",
          "completed": ["...", "..."],
          "filesModified": [{"path": "...", "reason": "..."}],
          "problems": [{"description": "...", "solution": "..."}],
          "unfinished": ["...", "..."],
          "nextSteps": ["...", "..."]
        }

        要求：
        - 使用 \(language)
        - 只根據提供內容推論，不要虛構
        - 若資料不足，對應欄位可為空陣列或簡短說明
        - 只輸出 JSON，不要其他說明文字

        ---工作紀錄---
        \(context)
        ---
        """
    }

    static func buildClaudePrompt(date: String, project: String, content: SummaryContent) -> String {
        var lines: [String] = []
        lines.append("## 昨日工作摘要（\(date)）")
        lines.append("")
        lines.append("**專案**：\(project)")
        lines.append("")
        lines.append("### 工作概述")
        lines.append(content.overview)
        lines.append("")

        if !content.completed.isEmpty {
            lines.append("### 完成事項")
            for item in content.completed {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        if !content.filesModified.isEmpty {
            lines.append("### 修改的檔案")
            for file in content.filesModified {
                lines.append("- `\(file.path)` — \(file.reason)")
            }
            lines.append("")
        }

        if !content.problems.isEmpty {
            lines.append("### 遇到的問題")
            for prob in content.problems {
                lines.append("- **\(prob.description)** → \(prob.solution)")
            }
            lines.append("")
        }

        if !content.unfinished.isEmpty || !content.nextSteps.isEmpty {
            lines.append("### 未完成 / 今天繼續")
            for item in content.unfinished {
                lines.append("- \(item)")
            }
            for item in content.nextSteps {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("請根據以上進度繼續協助我開發。")
        return lines.joined(separator: "\n")
    }

    // MARK: - Project-level summary

    static func buildProjectSummaryContext(summaries: [SummaryInfo]) -> String {
        var parts: [String] = []
        let sorted = summaries
            .filter { $0.status == .fresh || $0.status == .stale }
            .sorted { $0.localDate < $1.localDate }

        for s in sorted {
            guard let content = s.content else { continue }
            var section = "## \(s.localDate)\n"
            section += "概述：\(content.overview)\n"
            if !content.completed.isEmpty {
                section += "完成：\(content.completed.joined(separator: "；"))\n"
            }
            if !content.filesModified.isEmpty {
                let files = content.filesModified.map { "`\($0.path)` — \($0.reason)" }
                section += "修改檔案：\(files.joined(separator: "；"))\n"
            }
            if !content.problems.isEmpty {
                let probs = content.problems.map { "\($0.description) → \($0.solution)" }
                section += "問題：\(probs.joined(separator: "；"))\n"
            }
            if !content.unfinished.isEmpty {
                section += "未完成：\(content.unfinished.joined(separator: "；"))\n"
            }
            if !content.nextSteps.isEmpty {
                section += "下一步：\(content.nextSteps.joined(separator: "；"))\n"
            }
            parts.append(section)
        }

        let joined = parts.joined(separator: "\n")
        // Trim to 60K budget (project summaries can span many days)
        if joined.count > 60000 {
            return String(joined.prefix(60000)) + "\n…（截斷）"
        }
        return joined
    }

    static func buildProjectSummaryPrompt(project: String, context: String, language: String) -> String {
        """
        你是工程師的工作記憶助手。以下是專案「\(project)」的所有歷史每日工作摘要。

        請根據這些歷史摘要，產生一份完整的專案總摘要。輸出 JSON，格式如下：
        {
          "schemaVersion": 1,
          "projectOverview": "專案的整體描述與目標",
          "techStack": ["使用的技術/框架/工具"],
          "milestones": ["已完成的重要里程碑，按時間排序"],
          "architecture": "專案架構描述（模組、資料流等）",
          "currentState": "專案目前的狀態",
          "knownIssues": ["已知問題或技術債"],
          "nextSteps": ["接下來應該做的事"]
        }

        要求：
        - 使用 \(language)
        - 從歷史摘要中歸納，不要虛構
        - 若資料不足，對應欄位可為空陣列或簡短說明
        - 只輸出 JSON，不要其他說明文字
        - milestones 按照時間先後排列，附上大致日期

        ---歷史摘要---
        \(context)
        ---
        """
    }

    static func buildProjectClaudePrompt(project: String, content: ProjectSummaryContent) -> String {
        var lines: [String] = []
        lines.append("## 專案總摘要")
        lines.append("")
        lines.append("**專案**：\(project)")
        lines.append("")
        lines.append("### 專案概述")
        lines.append(content.projectOverview)
        lines.append("")

        if !content.techStack.isEmpty {
            lines.append("### 技術棧")
            for item in content.techStack {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        if !content.milestones.isEmpty {
            lines.append("### 里程碑")
            for item in content.milestones {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        if !content.architecture.isEmpty {
            lines.append("### 架構")
            lines.append(content.architecture)
            lines.append("")
        }

        if !content.currentState.isEmpty {
            lines.append("### 目前狀態")
            lines.append(content.currentState)
            lines.append("")
        }

        if !content.knownIssues.isEmpty {
            lines.append("### 已知問題")
            for item in content.knownIssues {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        if !content.nextSteps.isEmpty {
            lines.append("### 下一步")
            for item in content.nextSteps {
                lines.append("- \(item)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("請根據以上專案背景繼續協助我開發。")
        return lines.joined(separator: "\n")
    }

    // MARK: - API

    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    static func callGeminiStreaming(
        prompt: String,
        apiKey: String,
        model: String,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> SummaryContent {
        let maxRetries = 4
        var lastError: Error?

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delay = Double(1 << attempt)
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                return try await callGeminiSSE(prompt: prompt, apiKey: apiKey, model: model, onChunk: onChunk)
            } catch let error as SummarizerError {
                lastError = error
                if case .apiError(let code, _) = error, code == 429 || code >= 500 {
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? SummarizerError.parseError("Max retries exceeded")
    }

    private static func callGeminiSSE(
        prompt: String,
        apiKey: String,
        model: String,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> SummaryContent {
        guard let url = URL(string: "\(baseURL)/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw SummarizerError.apiError(statusCode: 0, body: "Invalid URL for model: \(model)")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 4096,
                "temperature": 0.7,
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw SummarizerError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullText = ""
        var lastUIUpdate = ContinuousClock.now
        let throttleInterval = Duration.milliseconds(150)

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let data = String(line.dropFirst(6))

            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw SummarizerError.apiError(statusCode: 0, body: message)
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let candidate = candidates.first,
               let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if part["thought"] as? Bool == true { continue }
                    if let text = part["text"] as? String {
                        fullText += text
                    }
                }
            }

            // Throttle UI updates to ~150ms intervals
            let now = ContinuousClock.now
            if now - lastUIUpdate >= throttleInterval {
                let snapshot = fullText
                await MainActor.run { onChunk(snapshot) }
                lastUIUpdate = now
            }
        }

        // Final UI update with complete text
        let finalSnapshot = fullText
        await MainActor.run { onChunk(finalSnapshot) }

        // Strip markdown fences
        var cleaned = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Replace smart/curly quotes with straight quotes
        cleaned = cleaned
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // "
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // "
            .replacingOccurrences(of: "\u{2018}", with: "'")   // '
            .replacingOccurrences(of: "\u{2019}", with: "'")   // '

        guard let finalData = cleaned.data(using: .utf8), !cleaned.isEmpty else {
            throw SummarizerError.parseError("Empty response from API")
        }

        return try JSONDecoder().decode(SummaryContent.self, from: finalData)
    }

    /// Streams Gemini response and returns the cleaned raw JSON string
    /// without decoding into a specific type. Useful for non-SummaryContent schemas.
    static func callGeminiStreamingRaw(
        prompt: String,
        apiKey: String,
        model: String,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let maxRetries = 4
        var lastError: Error?

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let delay = Double(1 << attempt)
                try await Task.sleep(for: .seconds(delay))
            }

            do {
                return try await callGeminiSSERaw(prompt: prompt, apiKey: apiKey, model: model, onChunk: onChunk)
            } catch let error as SummarizerError {
                lastError = error
                if case .apiError(let code, _) = error, code == 429 || code >= 500 {
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? SummarizerError.parseError("Max retries exceeded")
    }

    private static func callGeminiSSERaw(
        prompt: String,
        apiKey: String,
        model: String,
        onChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/\(model):streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw SummarizerError.apiError(statusCode: 0, body: "Invalid URL for model: \(model)")
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": 4096,
                "temperature": 0.7,
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw SummarizerError.apiError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullText = ""
        var lastUIUpdate = ContinuousClock.now
        let throttleInterval = Duration.milliseconds(150)

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let data = String(line.dropFirst(6))
            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw SummarizerError.apiError(statusCode: 0, body: message)
            }

            if let candidates = json["candidates"] as? [[String: Any]],
               let candidate = candidates.first,
               let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if part["thought"] as? Bool == true { continue }
                    if let text = part["text"] as? String { fullText += text }
                }
            }

            let now = ContinuousClock.now
            if now - lastUIUpdate >= throttleInterval {
                let snapshot = fullText
                await MainActor.run { onChunk(snapshot) }
                lastUIUpdate = now
            }
        }

        let finalSnapshot = fullText
        await MainActor.run { onChunk(finalSnapshot) }

        var cleaned = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let nl = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: nl)...])
            }
            if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")

        guard !cleaned.isEmpty else {
            throw SummarizerError.parseError("Empty response from API")
        }
        return cleaned
    }

    static func testConnection(apiKey: String, model: String) async -> (Bool, String) {
        guard let url = URL(string: "\(baseURL)/\(model)?key=\(apiKey)") else {
            return (false, "Invalid URL for model: \(model)")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }
            if httpResponse.statusCode == 200 {
                return (true, "連線成功")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return (false, "HTTP \(httpResponse.statusCode): \(body.prefix(200))")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private static func extractUserText(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let contentArray = message["content"] as? [[String: Any]] {
            let texts = contentArray.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            return texts.joined(separator: "\n")
        }
        return ""
    }

    private static func extractToolInputSummary(_ input: Any?, toolName: String) -> String {
        guard let dict = input as? [String: Any] else { return "" }

        switch toolName.lowercased() {
        case "edit":
            let file = dict["file_path"] as? String ?? ""
            return file.isEmpty ? "edit" : "edit \(file)"
        case "write":
            let file = dict["file_path"] as? String ?? ""
            return file.isEmpty ? "write" : "write \(file)"
        case "read":
            let file = dict["file_path"] as? String ?? ""
            return file.isEmpty ? "read" : "read \(file)"
        case "bash":
            let cmd = dict["command"] as? String ?? ""
            return String(cmd.prefix(200))
        default:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
               let str = String(data: data, encoding: .utf8) {
                return String(str.prefix(200))
            }
            return ""
        }
    }
}

enum SummarizerError: Error, LocalizedError {
    case apiError(statusCode: Int, body: String)
    case parseError(String)
    case noTimestamp

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let body): "API Error \(code): \(body.prefix(500))"
        case .parseError(let msg): "Parse Error: \(msg)"
        case .noTimestamp: "無法判定資料時間，請確認來源格式"
        }
    }
}
