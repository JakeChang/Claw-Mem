import SwiftUI

struct IngestStatusView: View {
    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(SyncService.self) private var syncService

    @State private var showErrors = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            // During an active sync, replace the "last ingest time" pill
                // with the sync progress pill so the toolbar stays compact.
            if syncService.isSyncing && syncService.syncTotal > 0 {
                syncProgressPill
            } else {
                statusPill
            }
            if coordinator.hasErrors { errorPill }
            HStack(spacing: 4) {
                refreshButton
                if syncService.isEnabled { syncButton }
            }
        }
        .padding(.horizontal, 4)
    }

    private var syncProgressPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(syncService.syncProgress)/\(syncService.syncTotal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .help("同步中 \(syncService.syncProgress)/\(syncService.syncTotal)")
    }

    // MARK: - Pills

    @ViewBuilder
    private var statusPill: some View {
        if coordinator.isIngesting {
            HStack(spacing: 8) {
                if coordinator.ingestTotal > 0 {
                    ProgressView(
                        value: Double(coordinator.ingestProgress),
                        total: Double(coordinator.ingestTotal)
                    )
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 80)
                    Text("\(coordinator.ingestProgress)/\(coordinator.ingestTotal)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text("匯入中…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08), in: Capsule())
        } else if let time = coordinator.lastIngestTime {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green.opacity(0.7))
                    .frame(width: 6, height: 6)
                Text(Self.timeFormatter.string(from: time))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .help("上次匯入：\(Self.timeFormatter.string(from: time))")
        }
    }

    private var errorPill: some View {
        Button {
            showErrors.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("\(coordinator.errorCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showErrors) {
            ErrorListPopover(errors: coordinator.recentErrors)
                .frame(width: 420, height: 320)
        }
        .help("\(coordinator.errorCount) 個匯入錯誤")
    }

    private var refreshButton: some View {
        Button {
            coordinator.runIngest()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(coordinator.isIngesting ? "排入下一次掃描" : "立即更新")
    }

    private var syncButton: some View {
        Button {
            Task { await syncService.syncNow() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(syncIconColor)
                .opacity(syncService.isSyncing ? 0.3 : 1)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(syncService.isSyncing)
        .help(syncHelpText)
    }

    private var syncIconColor: Color {
        if syncService.lastError != nil { return .red }
        return .secondary
    }

    private var syncHelpText: String {
        if syncService.isSyncing { return "同步中…" }
        if let err = syncService.lastError { return "同步失敗：\(err)" }
        if let t = syncService.lastSyncTime {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "上次同步 \(f.string(from: t))"
        }
        return "點擊立刻同步"
    }
}

private struct ErrorListPopover: View {
    let errors: [IngestErrorInfo]
    @Environment(IngestCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Ingest 錯誤", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Spacer()
                Text("\(errors.count) 筆")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !errors.isEmpty {
                    Button("清除全部") {
                        Task {
                            await coordinator.clearIngestErrors()
                            dismiss()
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            if errors.isEmpty {
                ContentUnavailableView("沒有錯誤", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(errors, id: \.createdAt) { error in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: error.sourceFilePath).lastPathComponent)
                            .font(.callout.weight(.medium))
                        HStack(spacing: 6) {
                            Text(error.errorKind.rawValue)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                            Text(error.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(error.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }
}
