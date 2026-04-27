import SwiftUI

/// Modal shown while a manual sync pass is running. Displays the sync
/// progress (current / total buckets) and lets the user dismiss the sheet
/// once the pass completes.
struct SyncProgressSheet: View {
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            progressBody
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled(syncService.isSyncing)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("備份資料")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if syncService.isSyncing {
            return "正在與同步資料夾互相備份"
        }
        if syncService.lastError != nil {
            return "發生錯誤"
        }
        return "已完成"
    }

    @ViewBuilder
    private var progressBody: some View {
        if syncService.isSyncing {
            VStack(alignment: .leading, spacing: 10) {
                if syncService.syncTotal > 0 {
                    ProgressView(
                        value: Double(syncService.syncProgress),
                        total: Double(syncService.syncTotal)
                    )
                    .progressViewStyle(.linear)
                    .tint(.accentColor)

                    HStack {
                        Text("處理中")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(syncService.syncProgress) / \(syncService.syncTotal)")
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("規劃中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if let err = syncService.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(completionText)
                        .font(.callout)
                }
                if syncService.lastImportedCount > 0 {
                    Text("匯入 \(syncService.lastImportedCount) 筆紀錄")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var completionText: String {
        if let time = syncService.lastSyncTime {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            return "已完成 · \(f.string(from: time))"
        }
        return "已完成"
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("關閉") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(syncService.isSyncing)
        }
    }
}
