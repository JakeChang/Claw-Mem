import Foundation
import CryptoKit

nonisolated struct ParsedRawEvent: Sendable {
    let dedupeKey: String
    let sourceFilePath: String
    let byteOffset: Int64
    let rawJSON: String
    let lineHash: String
    let eventTimestampUTC: Date?
    let eventTimestampLocal: Date?
    let sessionId: String?
    let project: String?
    let localDate: String?
    let parseStatus: ParseStatus
}

nonisolated struct ParsedMessage: Sendable {
    let sessionId: String
    let project: String
    let localDate: String
    let type: MessageType
    let role: String?
    let textContent: String?
    let timestamp: Date
}

nonisolated struct ParsedToolEvent: Sendable {
    let sessionId: String
    let project: String
    let localDate: String
    let toolCallId: String?
    let toolName: String
    let toolKind: ToolKind
    let inputPreview: String?
    let timestamp: Date
}

nonisolated struct ParsedToolResult: Sendable {
    let toolCallId: String
    let resultPreview: String?
}

nonisolated struct NormalizedOutput: Sendable {
    let messages: [ParsedMessage]
    let toolEvents: [ParsedToolEvent]
    let toolResults: [ParsedToolResult]
}

nonisolated struct Parser: Sendable {
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ str: String) -> Date? {
        isoFormatter.date(from: str) ?? isoFormatterNoFraction.date(from: str)
    }

    /// Thread-safe alternative to DateFormatter for "yyyy-MM-dd" formatting.
    static func localDate(from utc: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: utc)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    /// Stable hash using SHA256 (unlike hashValue which changes across app launches).
    static func stableHash(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func parseRawEvent(
        line: String,
        sourceFilePath: String,
        byteOffset: Int64,
        fallbackSessionId: String,
        fallbackProject: String
    ) -> (ParsedRawEvent, IngestErrorKind?) {
        let hash = stableHash(line)
        let dedupeKey = "\(sourceFilePath)#\(byteOffset)"

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (ParsedRawEvent(
                dedupeKey: dedupeKey,
                sourceFilePath: sourceFilePath,
                byteOffset: byteOffset,
                rawJSON: line,
                lineHash: hash,
                eventTimestampUTC: nil,
                eventTimestampLocal: nil,
                sessionId: fallbackSessionId,
                project: fallbackProject,
                localDate: nil,
                parseStatus: .failed
            ), .invalidJSON)
        }

        let timestampStr = json["timestamp"] as? String
        let utcDate = timestampStr.flatMap { parseTimestamp($0) }
        let localDateStr = utcDate.map { localDate(from: $0) }
        let localTimestamp = utcDate

        let sessionId = (json["sessionId"] as? String) ?? fallbackSessionId
        let project = fallbackProject

        let eventType = json["type"] as? String ?? "unknown"
        let parseStatus: ParseStatus
        switch eventType {
        case "user", "assistant", "system":
            parseStatus = .parsed
        case "file-history-snapshot", "queue-operation", "last-prompt":
            parseStatus = .skipped
        default:
            parseStatus = .skipped
        }

        return (ParsedRawEvent(
            dedupeKey: dedupeKey,
            sourceFilePath: sourceFilePath,
            byteOffset: byteOffset,
            rawJSON: line,
            lineHash: hash,
            eventTimestampUTC: utcDate,
            eventTimestampLocal: localTimestamp,
            sessionId: sessionId,
            project: project,
            localDate: localDateStr,
            parseStatus: parseStatus
        ), nil)
    }

    static func normalize(
        line: String,
        sessionId: String,
        project: String,
        timestamp: Date,
        localDateStr: String
    ) -> NormalizedOutput? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let eventType = json["type"] as? String ?? "unknown"
        var messages: [ParsedMessage] = []
        var toolEvents: [ParsedToolEvent] = []
        var toolResults: [ParsedToolResult] = []

        switch eventType {
        case "user":
            guard let message = json["message"] as? [String: Any] else { return nil }
            let content = message["content"]

            if let text = content as? String {
                messages.append(ParsedMessage(
                    sessionId: sessionId,
                    project: project,
                    localDate: localDateStr,
                    type: .user,
                    role: "user",
                    textContent: text,
                    timestamp: timestamp
                ))
            } else if let contentArray = content as? [[String: Any]] {
                var userTexts: [String] = []
                for block in contentArray {
                    let blockType = block["type"] as? String
                    if blockType == "text", let text = block["text"] as? String {
                        userTexts.append(text)
                    } else if blockType == "tool_result" {
                        let toolUseId = block["tool_use_id"] as? String
                        var resultText: String?
                        if let resultContent = block["content"] as? [[String: Any]] {
                            let texts = resultContent.compactMap { $0["text"] as? String }
                            if !texts.isEmpty {
                                resultText = texts.joined(separator: "\n").prefix(1000).description
                            }
                        } else if let resultContent = block["content"] as? String {
                            resultText = String(resultContent.prefix(1000))
                        }

                        if let toolId = toolUseId {
                            toolResults.append(ParsedToolResult(
                                toolCallId: toolId,
                                resultPreview: resultText
                            ))
                        }

                        messages.append(ParsedMessage(
                            sessionId: sessionId,
                            project: project,
                            localDate: localDateStr,
                            type: .toolResult,
                            role: "user",
                            textContent: resultText,
                            timestamp: timestamp
                        ))
                    }
                }
                if !userTexts.isEmpty {
                    messages.append(ParsedMessage(
                        sessionId: sessionId,
                        project: project,
                        localDate: localDateStr,
                        type: .user,
                        role: "user",
                        textContent: userTexts.joined(separator: "\n\n"),
                        timestamp: timestamp
                    ))
                }
            }

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let contentArray = message["content"] as? [[String: Any]] else { return nil }

            var textParts: [String] = []
            for block in contentArray {
                let blockType = block["type"] as? String
                if blockType == "text", let text = block["text"] as? String {
                    textParts.append(text)
                } else if blockType == "tool_use" {
                    let toolName = block["name"] as? String ?? "unknown"
                    let toolCallId = block["id"] as? String
                    let inputPreview = extractInputPreview(block["input"])

                    toolEvents.append(ParsedToolEvent(
                        sessionId: sessionId,
                        project: project,
                        localDate: localDateStr,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        toolKind: classifyTool(toolName),
                        inputPreview: inputPreview,
                        timestamp: timestamp
                    ))
                }
            }

            if !textParts.isEmpty {
                messages.append(ParsedMessage(
                    sessionId: sessionId,
                    project: project,
                    localDate: localDateStr,
                    type: .assistant,
                    role: "assistant",
                    textContent: textParts.joined(separator: "\n\n"),
                    timestamp: timestamp
                ))
            }

        case "system":
            let subtype = json["subtype"] as? String
            if subtype != "turn_duration" {
                messages.append(ParsedMessage(
                    sessionId: sessionId,
                    project: project,
                    localDate: localDateStr,
                    type: .system,
                    role: "system",
                    textContent: subtype ?? "system event",
                    timestamp: timestamp
                ))
            }

        default:
            return nil
        }

        if messages.isEmpty && toolEvents.isEmpty && toolResults.isEmpty {
            return nil
        }
        return NormalizedOutput(messages: messages, toolEvents: toolEvents, toolResults: toolResults)
    }

    private static func classifyTool(_ name: String) -> ToolKind {
        let lower = name.lowercased()
        if lower == "read" { return .read }
        if lower == "edit" { return .edit }
        if lower == "write" { return .write }
        if lower == "bash" { return .bash }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") { return .search }
        return .other
    }

    private static func extractInputPreview(_ input: Any?) -> String? {
        guard let input = input else { return nil }

        if let dict = input as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return String(str.prefix(1000))
            }
        }
        if let str = input as? String {
            return String(str.prefix(1000))
        }
        return nil
    }
}
