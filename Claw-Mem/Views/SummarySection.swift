import SwiftUI

struct SummarySection: View {
    let summary: SummaryInfo?
    let isAllProjects: Bool
    let isGenerating: Bool
    let streamingText: String
    let error: String?
    @Binding var userNotes: String
    let onGenerate: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. Manual notes — now at the top, visually prominent
            if !isAllProjects {
                NotesEditor(text: $userNotes)
            }

            // 2. AI summary section header + actions
            HStack(alignment: .center) {
                Label("AI 摘要", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))

                if let summary {
                    summaryBadge(for: summary.status)
                }

                Spacer()

                if let summary, summary.status == .fresh || summary.status == .stale {
                    Button {
                        onCopy()
                    } label: {
                        Label("複製給 Claude", systemImage: "doc.on.clipboard")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !isAllProjects {
                    Button(action: onGenerate) {
                        if isGenerating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("生成中…")
                                    .font(.callout)
                            }
                        } else {
                            Label(buttonTitle, systemImage: buttonIcon)
                                .font(.callout)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isGenerating)
                }
            }

            // 3. Streaming preview
            if isGenerating && !streamingText.isEmpty {
                StreamingCard(text: streamingText)
            }

            // 4. Summary content
            if isGenerating && streamingText.isEmpty {
                HintCard(icon: "network", text: "正在連線至 AI…")
            } else if isAllProjects {
                HintCard(
                    icon: "arrow.up.left",
                    text: "請選擇單一專案以產生摘要"
                )
            } else if let error {
                ErrorCard(message: error)
            } else if let summary {
                if summary.status == .stale {
                    StaleWarningBanner()
                }

                if let content = summary.content {
                    SummaryContentView(content: content)
                } else if summary.status == .failed {
                    ErrorCard(
                        message: summary.errorMessage ?? "摘要資料損壞，請重新產生"
                    )
                } else if summary.status == .notGenerated {
                    HintCard(
                        icon: "sparkles",
                        text: "按下「產生摘要」開始分析今日工作紀錄"
                    )
                } else {
                    ErrorCard(
                        message: "摘要資料解析失敗，請重新產生"
                    )
                }
            } else {
                HintCard(
                    icon: "sparkles",
                    text: "按下「產生摘要」開始分析今日工作紀錄"
                )
            }
        }
    }

    @ViewBuilder
    private func summaryBadge(for status: SummaryStatus) -> some View {
        switch status {
        case .fresh:
            Text("新鮮")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green, in: Capsule())
        case .stale:
            Text("舊")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange, in: Capsule())
        default:
            EmptyView()
        }
    }

    private var buttonTitle: String {
        guard let summary else { return "產生摘要" }
        switch summary.status {
        case .notGenerated: return "產生摘要"
        case .stale: return "重新產生"
        case .failed: return "重試"
        case .fresh: return "重新產生"
        }
    }

    private var buttonIcon: String {
        guard let summary else { return "sparkles" }
        switch summary.status {
        case .failed: return "arrow.clockwise"
        case .stale: return "arrow.clockwise"
        default: return "sparkles"
        }
    }
}

// MARK: - Sub-components

private struct NotesEditor: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("手動備註", systemImage: "note.text")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if !text.isEmpty {
                    Text("\(text.count) 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.callout)
                .focused($isFocused)
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isFocused ? Color.orange.opacity(0.5) : Color.orange.opacity(0.18),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !isFocused {
                        Text("補充 AI 摘要未涵蓋的細節，會一起複製給 Claude…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct StreamingCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("AI 生成中…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
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
}

private struct HintCard: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
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

private struct StaleWarningBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
            Text("資料已更新，建議重新產生")
                .font(.callout)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Summary Content

struct SummaryContentView: View {
    let content: SummaryContent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CollapsibleCard(title: "工作概述", icon: "doc.text") {
                Text(content.overview)
                    .font(.body)
                    .lineSpacing(3)
            }

            if !content.completed.isEmpty {
                CollapsibleCard(title: "完成事項", icon: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.completed, id: \.self) { item in
                            Label(item, systemImage: "checkmark")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            if !content.filesModified.isEmpty {
                CollapsibleCard(title: "修改檔案", icon: "doc.badge.gearshape") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.filesModified, id: \.path) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(Color.accentColor)
                                Text(file.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !content.problems.isEmpty {
                CollapsibleCard(title: "問題與解法", icon: "ladybug") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(content.problems, id: \.description) { prob in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(prob.description)
                                    .font(.callout.weight(.medium))
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(prob.solution)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !content.unfinished.isEmpty || !content.nextSteps.isEmpty {
                CollapsibleCard(title: "未完成 / 下一步", icon: "arrow.forward.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.unfinished, id: \.self) { item in
                            Label(item, systemImage: "circle")
                                .font(.callout)
                        }
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

struct CollapsibleCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 2)
            }
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
