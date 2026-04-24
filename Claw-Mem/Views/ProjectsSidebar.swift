import SwiftUI

/// Left column — flat list of every project across all dates, with
/// aggregate stats per project. Selecting one drives the middle column
/// (calendar + per-day list) and right column (single-day summary/notes).
struct ProjectsSidebar: View {
    @Environment(IngestCoordinator.self) private var coordinator
    @Binding var selectedProject: String?
    @Binding var filterStart: String?
    @Binding var filterEnd: String?

    @State private var searchText: String = ""
    @State private var showDateFilter = false

    private func inRange(_ date: String) -> Bool {
        if let s = filterStart, date < s { return false }
        if let e = filterEnd, date > e { return false }
        return true
    }

    private var projects: [ProjectSummary] {
        var byName: [String: ProjectSummary.Builder] = [:]

        for (key, count) in coordinator.messageCountByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            let name = String(parts[1])
            byName[name, default: ProjectSummary.Builder(name: name)]
                .add(date: date, messageCount: count)
        }

        for summaryKey in coordinator.summaryKeySet {
            let parts = summaryKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            let name = String(parts[1])
            byName[name]?.summaryCount += 1
        }

        for (key, seconds) in coordinator.workHoursByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            let name = String(parts[1])
            byName[name, default: ProjectSummary.Builder(name: name)].totalWorkSeconds += seconds
        }

        return byName.values
            .map { $0.finalized() }
            .sorted { lhs, rhs in
                if lhs.lastActiveDate != rhs.lastActiveDate {
                    return lhs.lastActiveDate > rhs.lastActiveDate
                }
                return lhs.name < rhs.name
            }
    }

    private var filtered: [ProjectSummary] {
        guard !searchText.isEmpty else { return projects }
        let q = searchText.lowercased()
        return projects.filter { $0.name.lowercased().contains(q) }
    }

    private var isFiltered: Bool {
        filterStart != nil || filterEnd != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            dateFilterBar
            Divider()

            if projects.isEmpty {
                Spacer()
                ContentUnavailableView("尚無專案", systemImage: "folder")
                    .controlSize(.small)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { project in
                            ProjectCardRow(
                                project: project,
                                isSelected: selectedProject == project.name
                            )
                            .onTapGesture { selectedProject = project.name }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("搜尋專案…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var dateFilterBar: some View {
        VStack(spacing: 0) {
            // Toggle row
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showDateFilter.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.caption)
                        Text("日期篩選")
                            .font(.caption)
                        if isFiltered {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                        Spacer()
                        Image(systemName: showDateFilter ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(isFiltered ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if showDateFilter {
                dateFilterContent
            }
        }
    }

    private var dateFilterContent: some View {
        VStack(spacing: 8) {
            // Presets
            HStack(spacing: 6) {
                presetButton("7 天", days: 7)
                presetButton("30 天", days: 30)
                presetButton("90 天", days: 90)
                Spacer()
                if isFiltered {
                    Button {
                        filterStart = nil
                        filterEnd = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除篩選")
                }
            }

            // Custom range
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow {
                    Text("從")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    DatePicker(
                        "",
                        selection: startDateBinding,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
                GridRow {
                    Text("到")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    DatePicker(
                        "",
                        selection: endDateBinding,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func presetButton(_ title: String, days: Int) -> some View {
        let isActive = filterStart == dateToString(
            Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date())!
        )
        return Button(title) {
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: end)!
            filterStart = dateToString(start)
            filterEnd = dateToString(end)
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isActive ? .accentColor : nil)
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { stringToDate(filterStart) ?? Calendar.current.date(byAdding: .month, value: -1, to: Date())! },
            set: { filterStart = dateToString($0) }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { stringToDate(filterEnd) ?? Date() },
            set: { filterEnd = dateToString($0) }
        )
    }

    private func dateToString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func stringToDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

// MARK: - Project card row

private struct ProjectCardRow: View {
    let project: ProjectSummary
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.callout.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if project.summaryCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("\(project.summaryCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 8) {
                Label("\(formatCount(project.messageCount))", systemImage: "bubble.left")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Label("\(project.activeDays) 天", systemImage: "calendar")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if project.totalWorkSeconds > 0 {
                    Label(formatDuration(project.totalWorkSeconds), systemImage: "clock")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text("最後 \(formatDate(project.lastActiveDate))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBg, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .help(project.name)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var rowBg: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private func formatDate(_ s: String) -> String {
        // "2026-04-17" -> "04/17"
        let parts = s.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : s
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }
}

// MARK: - Project summary model

struct ProjectSummary: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let messageCount: Int
    let activeDays: Int
    let summaryCount: Int
    let lastActiveDate: String
    let totalWorkSeconds: TimeInterval

    struct Builder {
        let name: String
        var messageCount: Int = 0
        var activeDates: Set<String> = []
        var summaryCount: Int = 0
        var lastActiveDate: String = ""
        var totalWorkSeconds: TimeInterval = 0

        mutating func add(date: String, messageCount: Int) {
            self.messageCount += messageCount
            activeDates.insert(date)
            if date > lastActiveDate { lastActiveDate = date }
        }

        func finalized() -> ProjectSummary {
            ProjectSummary(
                name: name,
                messageCount: messageCount,
                activeDays: activeDates.count,
                summaryCount: summaryCount,
                lastActiveDate: lastActiveDate,
                totalWorkSeconds: totalWorkSeconds
            )
        }
    }
}
