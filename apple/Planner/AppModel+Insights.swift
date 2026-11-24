import Foundation
import PlannerKit

/// What got done in a week, worked out from the synced tasks and blocks (no server call).
struct WeekInsights {
    struct Day: Identifiable {
        var date: Date
        var count: Int
        var id: Date { date }
    }

    struct ProjectRow: Identifiable {
        var project: Project?
        var count: Int
        var minutes: Int
        var kept: Int
        var missed: Int
        var id: String { project?.id ?? "none" }
    }

    var weekStart: Date
    var days: [Day]
    var total: Int
    var lastWeekTotal: Int
    var minutesDone: Int
    var byProject: [ProjectRow]
    var blocksKept: Int
    var blocksMissed: Int
    /// Finished with a due date set, and how many of those were on time.
    var withDue: Int
    var onTime: Int
    var carriedOver: Int
    var streak: Int

    var busiestDay: Day? { days.filter { $0.count > 0 }.max { $0.count < $1.count } }
    var keptRate: Double? { blocksKept + blocksMissed == 0 ? nil : Double(blocksKept) / Double(blocksKept + blocksMissed) }
    var onTimeRate: Double? { withDue == 0 ? nil : Double(onTime) / Double(withDue) }
    var change: Int { total - lastWeekTotal }

    /// One or two things worth acting on, plainly worded.
    var worthNoticing: [String] {
        var out: [String] = []
        if let worst = byProject.filter({ $0.missed >= 2 && $0.missed > $0.kept }).max(by: { $0.missed < $1.missed }) {
            let name = worst.project?.name ?? "unfiled work"
            out.append("You missed \(worst.missed) of \(worst.missed + worst.kept) blocks for \(name). Give it its own hours, or shorter blocks?")
        }
        if let rate = onTimeRate, withDue >= 3, rate < 0.6 {
            out.append("Only \(Int(rate * 100))% of tasks with a due date were done on time. Plan My Day each morning puts due work first.")
        }
        if carriedOver >= 3 {
            out.append("\(carriedOver) tasks are overdue going into next week. Clear or move them in the next step.")
        }
        if let busiest = busiestDay, total >= 5, Double(busiest.count) / Double(total) >= 0.5 {
            out.append("Half your week's work landed on \(busiest.date.formatted(.dateTime.weekday(.wide))). Spreading it out could ease the crunch.")
        }
        if out.isEmpty && total > lastWeekTotal && lastWeekTotal > 0 {
            out.append("Up \(change) on last week. Keep the rhythm going.")
        }
        return Array(out.prefix(2))
    }
}

extension AppModel {
    /// Monday–Sunday around `date`, in the device's time zone.
    private var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    func insights(weekOf date: Date = Date()) -> WeekInsights {
        let calendar = isoCalendar
        let week = calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
        let lastWeek = DateInterval(start: week.start.addingTimeInterval(-7 * 86_400), end: week.start)
        let tasks = state?.tasks ?? []
        let done = tasks.filter { $0.isDone && $0.completedAt.map { week.contains($0) } == true }

        let days = (0..<7).map { i -> WeekInsights.Day in
            let day = calendar.date(byAdding: .day, value: i, to: week.start) ?? week.start
            let count = done.filter { calendar.isDate($0.completedAt!, inSameDayAs: day) }.count
            return WeekInsights.Day(date: day, count: count)
        }

        let blocks = (state?.events ?? []).filter { $0.isTaskBlock && week.contains($0.startAt) && $0.outcome != nil }
        var rows: [String: WeekInsights.ProjectRow] = [:]
        for task in done {
            let key = task.projectId ?? ""
            var row = rows[key] ?? WeekInsights.ProjectRow(project: project(id: task.projectId), count: 0, minutes: 0, kept: 0, missed: 0)
            row.count += 1
            row.minutes += task.estimateMin
            rows[key] = row
        }
        for block in blocks {
            let key = block.projectId ?? ""
            var row = rows[key] ?? WeekInsights.ProjectRow(project: project(id: block.projectId), count: 0, minutes: 0, kept: 0, missed: 0)
            if block.outcome == .done { row.kept += 1 } else { row.missed += 1 }
            rows[key] = row
        }

        let withDue = done.filter { $0.dueAt != nil }
        return WeekInsights(
            weekStart: week.start,
            days: days,
            total: done.count,
            lastWeekTotal: tasks.filter { $0.isDone && $0.completedAt.map { lastWeek.contains($0) } == true }.count,
            minutesDone: done.reduce(0) { $0 + $1.estimateMin },
            byProject: rows.values.sorted { ($0.count, $0.minutes) > ($1.count, $1.minutes) },
            blocksKept: blocks.filter { $0.outcome == .done }.count,
            blocksMissed: blocks.filter { $0.outcome == .missed }.count,
            withDue: withDue.count,
            onTime: withDue.filter { $0.completedAt! <= $0.dueAt! }.count,
            carriedOver: overdue.count,
            streak: streak()
        )
    }

    /// Days in a row, ending today (or yesterday if nothing's done yet today), with something done.
    func streak(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let doneDays = Set((state?.tasks ?? []).compactMap { $0.isDone ? $0.completedAt.map { calendar.startOfDay(for: $0) } : nil })
        var day = calendar.startOfDay(for: now)
        if !doneDays.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while doneDays.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }
}
