import SwiftUI

/// Middle column — after a project is picked on the left, show a month
/// calendar with active days highlighted, plus a scrollable list of the
/// project's active dates. Clicking "查看細節" opens the conversation
/// modal for that day.
struct ProjectDetailView: View {
    let project: String
    @Binding var selectedDate: String?
    var filterStart: String?
    var filterEnd: String?

    @Environment(IngestCoordinator.self) private var coordinator

    @State private var displayedMonth: Date = Date()
    @State private var modalTarget: ConversationTarget?
    @State private var deleteTarget: ConversationTarget?

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "yyyy 年 MM 月"
        return f
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func inRange(_ date: String) -> Bool {
        if let s = filterStart, date < s { return false }
        if let e = filterEnd, date > e { return false }
        return true
    }

    /// Dates across all months where this project has activity.
    private var activeDates: Set<String> {
        var set = Set<String>()
        for (key, _) in coordinator.messageCountByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[1]) == project else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            set.insert(date)
        }
        for summaryKey in coordinator.summaryKeySet {
            let parts = summaryKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[1]) == project else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            set.insert(date)
        }
        return set
    }

    /// Sorted desc list of dates with activity for the picked project.
    private var sortedDates: [String] {
        activeDates.sorted(by: >)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            calendarSection
            Divider().padding(.top, 6)
            dayList
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        .sheet(item: $modalTarget) { target in
            ConversationModal(localDate: target.date, project: target.project)
        }
        .sheet(item: $deleteTarget) { target in
            DeleteConfirmView(localDate: target.date, project: target.project) { didDelete in
                let deletedKey = target.date
                deleteTarget = nil
                if didDelete && selectedDate == deletedKey {
                    selectedDate = nil
                }
            }
        }
    }

    // MARK: - Sections

    /// Total work hours across all dates for this project.
    private var totalWorkSeconds: TimeInterval {
        var total: TimeInterval = 0
        for (key, seconds) in coordinator.workHoursByDateProject {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[1]) == project else { continue }
            let date = String(parts[0])
            guard inRange(date) else { continue }
            total += seconds
        }
        return total
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(project)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    selectedDate = projectSummaryDate
                } label: {
                    Label("專案總摘要", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("\(sortedDates.count) 天活躍")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if totalWorkSeconds > 0 {
                    Label(formatTotalDuration(totalWorkSeconds), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func formatTotalDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "共 \(h)h \(m)m"
        }
        return "共 \(m)m"
    }

    private var calendarSection: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                Text(Self.monthFormatter.string(from: displayedMonth))
                    .font(.callout.weight(.semibold))
                Spacer()

                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = calendarDays()
            let active = activeDates
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                spacing: 3
            ) {
                ForEach(days, id: \.id) { day in
                    let key = day.dateKey
                    let hasActivity = key.map { active.contains($0) } ?? false
                    CalendarDayCell(
                        day: day,
                        isSelected: key == selectedDate,
                        hasActivity: hasActivity,
                        isToday: key == todayKey
                    )
                    .onTapGesture {
                        if let key, hasActivity {
                            selectedDate = key
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private var dayList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(sortedDates, id: \.self) { date in
                    DayRow(
                        date: date,
                        project: project,
                        messageCount: coordinator.messageCountByDateProject["\(date)#\(project)"] ?? 0,
                        workSeconds: coordinator.workHoursByDateProject["\(date)#\(project)"] ?? 0,
                        hasSummary: coordinator.summaryKeySet.contains("\(date)#\(project)"),
                        isSelected: selectedDate == date,
                        onSelect: { selectedDate = date },
                        onViewDetail: {
                            modalTarget = ConversationTarget(date: date, project: project)
                        },
                        onDelete: {
                            deleteTarget = ConversationTarget(date: date, project: project)
                        }
                    )
                }
            }
            .padding(10)
        }
    }

    // MARK: - Helpers

    private var todayKey: String {
        Self.dayKeyFormatter.string(from: Date())
    }

    private func shiftMonth(_ delta: Int) {
        if let new = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = new
        }
    }

    private func calendarDays() -> [CalendarDay] {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = cal.date(from: components),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }
        let firstWeekday = cal.component(.weekday, from: firstOfMonth)
        let offset = (firstWeekday + 5) % 7

        var days: [CalendarDay] = []
        for i in 0..<offset {
            days.append(CalendarDay(id: "empty-\(i)", dayNumber: 0, dateKey: nil))
        }
        for day in range {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else { continue }
            let key = Self.dayKeyFormatter.string(from: date)
            days.append(CalendarDay(id: key, dayNumber: day, dateKey: key))
        }
        return days
    }
}

// MARK: - Day row

private struct DayRow: View {
    let date: String
    let project: String
    let messageCount: Int
    let workSeconds: TimeInterval
    let hasSummary: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onViewDetail: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(formatDate(date))
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    if hasSummary {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 8) {
                    Text("💬 \(messageCount) 則")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if workSeconds > 0 {
                        Label(formatDuration(workSeconds), systemImage: "clock")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button("細節") { onViewDetail() }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .opacity(isHovered || isSelected ? 1 : 0.6)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("刪除此日紀錄")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(rowBg, in: RoundedRectangle(cornerRadius: 7))
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .contextMenu {
            Button("開啟細節") { onViewDetail() }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("刪除此日紀錄…", systemImage: "trash")
            }
        }
    }

    private var rowBg: Color {
        if isSelected { return Color.accentColor.opacity(0.1) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    private func formatDate(_ s: String) -> String {
        let parts = s.split(separator: "-")
        guard parts.count == 3 else { return s }
        return "\(parts[1])/\(parts[2])（\(weekday(s))）"
    }

    private func weekday(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return "?" }
        let idx = Calendar(identifier: .gregorian).component(.weekday, from: d)
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return names[idx - 1]
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

// MARK: - Calendar day cell (shared-ish, duplicated small style)

private struct CalendarDayCell: View {
    let day: CalendarDay
    let isSelected: Bool
    let hasActivity: Bool
    let isToday: Bool

    var body: some View {
        ZStack {
            if day.dayNumber > 0 {
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
                Text("\(day.dayNumber)")
                    .font(.caption.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(foregroundColor)
            }
        }
        .frame(height: 22)
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor }
        if isToday { return Color.accentColor.opacity(0.15) }
        if hasActivity { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var foregroundColor: Color {
        if isSelected { return .white }
        if hasActivity { return .primary }
        return .gray.opacity(0.4)
    }
}

// MARK: - Modal target

struct ConversationTarget: Identifiable, Hashable {
    var id: String { "\(date)#\(project)" }
    let date: String
    let project: String
}

// MARK: - Calendar day (shared data type)

struct CalendarDay: Identifiable {
    let id: String
    let dayNumber: Int
    let dateKey: String?
}
