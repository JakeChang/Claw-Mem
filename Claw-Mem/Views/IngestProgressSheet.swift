import SwiftUI

/// Modal shown while a manual ingest pass is running. Displays the ingest
/// progress (current / total files) and lets the user dismiss the sheet
/// once the pass completes.
struct IngestProgressSheet: View {
    @Environment(IngestCoordinator.self) private var coordinator
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
        .interactiveDismissDisabled(coordinator.isIngesting)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("同步紀錄")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var subtitle: String {
        if coordinator.isIngesting {
            return "正在從 Claude Code 讀取新紀錄"
        }
        return "已完成"
    }

    @ViewBuilder
    private var progressBody: some View {
        if coordinator.isIngesting {
            VStack(alignment: .leading, spacing: 10) {
                if coordinator.ingestTotal > 0 {
                    ProgressView(
                        value: Double(coordinator.ingestProgress),
                        total: Double(coordinator.ingestTotal)
                    )
                    .progressViewStyle(.linear)
                    .tint(.accentColor)

                    HStack {
                        Text("處理中")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(coordinator.ingestProgress) / \(coordinator.ingestTotal)")
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("掃描中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(completionText)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var completionText: String {
        if let time = coordinator.lastIngestTime {
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
            .disabled(coordinator.isIngesting)
        }
    }
}
