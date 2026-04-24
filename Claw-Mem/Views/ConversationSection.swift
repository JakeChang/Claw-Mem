import SwiftUI

struct TimelineItem: Identifiable {
    let id: UUID
    let timestamp: Date
    let kind: TimelineKind
    let preview: String
    let fullContent: String?
    let toolInputPreview: String?
    let toolResultPreview: String?
    let timeString: String
}

enum TimelineKind: Hashable {
    case user
    case assistant
    case toolEvent(ToolKind, String)
    case toolResult
    case system

    var icon: String {
        switch self {
        case .user: "person.fill"
        case .assistant: "brain"
        case .toolEvent(let kind, _):
            switch kind {
            case .read: "doc.text"
            case .edit, .write: "pencil.line"
            case .bash: "terminal"
            case .search: "magnifyingglass"
            case .other: "wrench"
            }
        case .toolResult: "wrench"
        case .system: "gear"
        }
    }

    var tint: Color {
        switch self {
        case .user: .blue
        case .assistant: .purple
        case .toolEvent(let kind, _):
            switch kind {
            case .read: .gray
            case .edit, .write: .orange
            case .bash: .green
            case .search: .cyan
            case .other: .gray
            }
        case .toolResult: .gray
        case .system: .secondary
        }
    }

    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .user: "User"
        case .assistant: "Assistant"
        case .toolEvent(_, let name): name
        case .toolResult: "Result"
        case .system: "System"
        }
    }
}

struct ConversationSection: View {
    let messages: [MessageInfo]
    let toolEvents: [ToolEventInfo]

    @State private var expandedItemId: UUID?
    @State private var cachedItems: [TimelineItem] = []
    @State private var lastMessageCount = 0
    @State private var lastToolEventCount = 0
    @State private var rebuildTask: Task<Void, Never>?

    nonisolated private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("對話紀錄", systemImage: "text.bubble")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(cachedItems.count) 筆")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if cachedItems.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .foregroundStyle(.secondary)
                    Text("尚無紀錄")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(cachedItems) { item in
                        TimelineRow(
                            item: item,
                            isExpanded: expandedItemId == item.id,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedItemId = expandedItemId == item.id ? nil : item.id
                                }
                            }
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { rebuildIfNeeded() }
        .onChange(of: messages.count) { rebuildIfNeeded() }
        .onChange(of: toolEvents.count) { rebuildIfNeeded() }
    }

    private func rebuildIfNeeded() {
        let mc = messages.count
        let tc = toolEvents.count
        guard mc != lastMessageCount || tc != lastToolEventCount else { return }
        lastMessageCount = mc
        lastToolEventCount = tc

        // Snapshot arrays for the off-main worker — mutating them on main
        // while the task runs would be a data race.
        let msgs = messages
        let tools = toolEvents
        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .userInitiated) {
            let built = Self.buildTimeline(messages: msgs, toolEvents: tools)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.cachedItems = built
            }
        }
    }

    nonisolated static func buildTimeline(
        messages: [MessageInfo],
        toolEvents: [ToolEventInfo]
    ) -> [TimelineItem] {
        let fmt = Self.timeFormatter
        var items: [TimelineItem] = []
        items.reserveCapacity(messages.count + toolEvents.count)

        for msg in messages {
            items.append(TimelineItem(
                id: msg.id,
                timestamp: msg.timestamp,
                kind: Self.mapKind(msg.type),
                preview: String((msg.textContent ?? "").prefix(80)),
                fullContent: msg.textContent,
                toolInputPreview: nil,
                toolResultPreview: msg.type == .toolResult ? msg.textContent : nil,
                timeString: fmt.string(from: msg.timestamp)
            ))
        }

        for tool in toolEvents {
            let preview = "\(tool.toolName) \(tool.inputPreview?.prefix(50) ?? "")"
            items.append(TimelineItem(
                id: tool.id,
                timestamp: tool.timestamp,
                kind: .toolEvent(tool.toolKind, tool.toolName),
                preview: String(preview.prefix(80)),
                fullContent: nil,
                toolInputPreview: tool.inputPreview,
                toolResultPreview: tool.resultPreview,
                timeString: fmt.string(from: tool.timestamp)
            ))
        }

        items.sort { $0.timestamp > $1.timestamp }
        return items
    }

    nonisolated private static func mapKind(_ type: MessageType) -> TimelineKind {
        switch type {
        case .user: .user
        case .assistant: .assistant
        case .toolResult: .toolResult
        case .system: .system
        }
    }
}

// MARK: - Timeline Row

private let kPreviewLimit = 500
private let kFullLimit = 3000

private struct TimelineRow: View {
    let item: TimelineItem
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var showFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    // Icon
                    Image(systemName: item.kind.icon)
                        .font(.caption)
                        .foregroundStyle(item.kind.tint)
                        .frame(width: 24, height: 24)
                        .background(item.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    // Time
                    Text(item.timeString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 36, alignment: .leading)

                    // Preview
                    Text(item.preview)
                        .lineLimit(1)
                        .font(.callout)
                        .foregroundStyle(item.kind.isSystem ? .tertiary : .primary)

                    Spacer()

                    // Tag
                    Text(item.kind.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isExpanded ? Color.primary.opacity(0.03) : .clear)

            if isExpanded {
                expandedContent
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.leading, 34)
                    .background(Color.primary.opacity(0.03))
            }
        }
        .background(Color.primary.opacity(0.02))
        .onChange(of: isExpanded) {
            if !isExpanded { showFull = false }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let full = item.fullContent, !full.isEmpty {
                let limit = showFull ? kFullLimit : kPreviewLimit
                let isTruncated = full.count > limit

                Text(isTruncated ? String(full.prefix(limit)) + "…" : full)
                    .font(.callout)
                    .lineSpacing(2)
                    .foregroundStyle(item.kind.isSystem ? .secondary : .primary)

                if full.count > kPreviewLimit {
                    Button {
                        showFull.toggle()
                    } label: {
                        Label(
                            showFull ? "收合" : "顯示更多（\(full.count) 字）",
                            systemImage: showFull ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            if let input = item.toolInputPreview {
                CodeBlock(label: "Input", text: String(input.prefix(kPreviewLimit)))
            }
            if let result = item.toolResultPreview {
                CodeBlock(label: "Result", text: String(result.prefix(kPreviewLimit)))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CodeBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
