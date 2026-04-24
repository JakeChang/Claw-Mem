import SwiftUI

/// Sheet presented when user clicks "細節" on a day row. Loads the day's
/// messages + tool events lazily and reuses the existing ConversationSection
/// for rendering.
struct ConversationModal: View {
    let localDate: String
    let project: String

    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [MessageInfo] = []
    @State private var toolEvents: [ToolEventInfo] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                Spacer()
                ProgressView("載入中…")
                    .controlSize(.small)
                Spacer()
            } else if messages.isEmpty && toolEvents.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "沒有紀錄",
                    systemImage: "tray",
                    description: Text("此日此專案尚無對話或工具事件")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ConversationSection(
                            messages: messages,
                            toolEvents: toolEvents
                        )
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .task(id: "\(localDate)#\(project)") {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(localDate)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !messages.isEmpty || !toolEvents.isEmpty {
                        Text("· \(messages.count) 則 · \(toolEvents.count) 個工具事件")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button("關閉") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        isLoading = true
        async let m = coordinator.fetchMessages(localDate: localDate, project: project)
        async let t = coordinator.fetchToolEvents(localDate: localDate, project: project)
        let (fetchedM, fetchedT) = await (m, t)
        messages = fetchedM
        toolEvents = fetchedT
        isLoading = false
    }
}
