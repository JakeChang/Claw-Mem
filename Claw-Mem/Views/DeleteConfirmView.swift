import SwiftUI

/// Confirm-and-execute view for purging a single (date, project) bucket.
/// Loads stats + safely-deletable JSONL files asynchronously so the sheet
/// can show concrete numbers before the user commits.
struct DeleteConfirmView: View {
    let localDate: String
    let project: String
    /// Called when the sheet should dismiss. Passes `true` if a deletion
    /// actually ran (so the caller can clear a selection pointing at the
    /// deleted bucket).
    let onDone: (Bool) -> Void

    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(SyncService.self) private var syncService
    @Environment(AppSettings.self) private var settings

    @State private var stats: DeleteStats?
    @State private var safeFiles: [SafeDeleteFile] = []
    @State private var alsoDeleteJSONL = false
    @State private var isLoading = true
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            bodyContent
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 420)
        .task {
            async let s = coordinator.getDeleteStats(localDate: localDate, project: project)
            async let f = coordinator.getSafelyDeletableSourceFiles(localDate: localDate, project: project)
            stats = await s
            safeFiles = await f
            isLoading = false
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("刪除此日紀錄").font(.title3.weight(.semibold))
                Text("\(localDate) · \(project)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if isLoading {
            HStack {
                ProgressView().controlSize(.small)
                Text("計算中…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else if let stats {
            statsList(stats)
            if !safeFiles.isEmpty {
                jsonlToggle
            }
        }
    }

    private func statsList(_ s: DeleteStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("將刪除：")
                .font(.callout.weight(.medium))
            Group {
                if s.messages > 0 || s.toolEvents > 0 {
                    bullet("\(s.messages) 則訊息、\(s.toolEvents) 個工具事件")
                }
                if s.summaries > 0 {
                    bullet("\(s.summaries) 篇 AI 摘要")
                }
                if s.notes > 0 {
                    bullet("手動備註")
                }
                if s.rawEvents > 0 {
                    bullet("\(s.rawEvents) 筆原始事件索引")
                        .foregroundStyle(.tertiary)
                }
                if s.messages == 0 && s.toolEvents == 0
                    && s.summaries == 0 && s.notes == 0 && s.rawEvents == 0 {
                    bullet("沒有可刪除的資料")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var jsonlToggle: some View {
        let totalSize = safeFiles.reduce(Int64(0)) { $0 + $1.fileSize }
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $alsoDeleteJSONL) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("同時刪除 Claude Code 原始檔案")
                        .font(.callout)
                    Text("\(safeFiles.count) 個 session 檔 · \(formatSize(totalSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("刪除後無法用 claude --resume 回到此 session")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack {
            Button("取消") { onDone(false) }
                .keyboardShortcut(.cancelAction)
                .disabled(isDeleting)

            Spacer()

            if isDeleting {
                ProgressView().controlSize(.small)
            }

            Button(role: .destructive) {
                Task { await performDelete() }
            } label: {
                Text("刪除").frame(minWidth: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
            .disabled(isDeleting || stats == nil)
        }
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.tertiary)
            Text(text)
        }
        .font(.callout)
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        _ = await coordinator.deleteDateProject(
            localDate: localDate,
            project: project,
            deviceID: settings.deviceID,
            alsoDeleteJSONL: alsoDeleteJSONL
        )
        // Push the tombstone out so the other device sees it promptly.
        syncService.scheduleSync(delay: .milliseconds(300))
        onDone(true)
    }
}
