import SwiftUI

// MARK: - Menu bar label (shown in the menu bar itself)

struct MenuBarLabel: View {
    let coordinator: IngestCoordinator

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var todayStats: (projects: Int, messages: Int) {
        let today = todayKey
        var projects = Set<String>()
        var messages = 0
        for (key, count) in coordinator.messageCountByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == today else { continue }
            projects.insert(String(parts[1]))
            messages += count
        }
        return (projects.count, messages)
    }

    var body: some View {
        let stats = todayStats
        HStack(spacing: 3) {
            Image(systemName: "brain.head.profile")
            if stats.messages > 0 {
                Text("\(stats.projects)P \(formatCount(stats.messages))M")
                    .monospacedDigit()
            }
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - Menu bar dropdown (window style)

struct MenuBarView: View {
    @Environment(IngestCoordinator.self) private var coordinator
    @State private var isHoveringOpen = false
    @State private var isHoveringQuit = false
    @State private var isHoveringRefresh = false

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private var todayProjects: [(name: String, messages: Int, workSeconds: TimeInterval)] {
        let today = todayKey
        var byName: [String: (messages: Int, work: TimeInterval)] = [:]

        for (key, count) in coordinator.messageCountByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == today else { continue }
            let name = String(parts[1])
            byName[name, default: (0, 0)].messages += count
        }

        for (key, seconds) in coordinator.workHoursByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == today else { continue }
            let name = String(parts[1])
            byName[name, default: (0, 0)].work += seconds
        }

        return byName.map { (name: $0.key, messages: $0.value.messages, workSeconds: $0.value.work) }
            .sorted { $0.messages > $1.messages }
    }

    private var totalMessages: Int {
        todayProjects.reduce(0) { $0 + $1.messages }
    }

    private var totalWork: TimeInterval {
        todayProjects.reduce(0) { $0 + $1.workSeconds }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("今日工作")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formatDateFull(todayKey))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Button {
                    coordinator.runIngest()
                } label: {
                    Group {
                        if coordinator.isIngesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isHoveringRefresh ? Color.accentColor : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isIngesting)
                .onHover { isHoveringRefresh = $0 }
                .help(coordinator.isIngesting ? "匯入中…" : "立即更新")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if todayProjects.isEmpty {
                // Empty state
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 24))
                        .foregroundStyle(.quaternary)
                    Text("今天尚無工作紀錄")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // Stats bar
                HStack(spacing: 0) {
                    statPill(icon: "folder.fill", value: "\(todayProjects.count)", label: "專案", color: .blue)
                    statPill(icon: "bubble.left.fill", value: "\(totalMessages)", label: "紀錄", color: .indigo)
                    if totalWork > 0 {
                        statPill(icon: "clock.fill", value: formatDuration(totalWork), label: "工時", color: .orange)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

                // Divider
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)

                // Project list
                VStack(spacing: 2) {
                    ForEach(todayProjects, id: \.name) { project in
                        projectRow(project)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }

            // Divider
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            // Footer buttons
            HStack(spacing: 8) {
                footerButton(
                    title: "開啟 Claw-Mem",
                    icon: "macwindow",
                    isHovered: $isHoveringOpen
                ) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows
                        .first { $0.canBecomeMain }?
                        .makeKeyAndOrderFront(nil)
                }

                footerButton(
                    title: "結束",
                    icon: "power",
                    isHovered: $isHoveringQuit
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }

    // MARK: - Components

    private func statPill(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 2)
    }

    private func projectRow(_ project: (name: String, messages: Int, workSeconds: TimeInterval)) -> some View {
        HStack(spacing: 8) {
            // Progress bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3, height: 20)

            Text(project.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text("\(project.messages)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)

            if project.workSeconds > 0 {
                Text(formatDuration(project.workSeconds))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private func footerButton(
        title: String,
        icon: String,
        isHovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                isHovered.wrappedValue ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered.wrappedValue = $0 }
    }

    // MARK: - Formatting

    private func formatDateFull(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return s }
        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_TW")
        out.dateFormat = "MM/dd（E）"
        return out.string(from: d)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
