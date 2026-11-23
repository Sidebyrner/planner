import Foundation
import PlannerKit

enum Format {
    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// Short enough for a list row: "Today 5 PM", "Tomorrow 9:30 AM", "Fri 5 PM", "Dec 3, 5 PM".
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let clock = shortClock(date)
        if calendar.isDateInToday(date) { return "Today \(clock)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(clock)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(clock)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 99
        if (0..<7).contains(days) { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(clock)"
    }

    /// "09:00" → "9 AM" (or "09:00" on a 24-hour device).
    static func clock(_ hm: String) -> String {
        let parts = hm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else { return hm }
        return shortClock(date)
    }

    /// "5 PM" on the hour, "5:30 PM" otherwise (24-hour devices get "17" / "17:30").
    static func shortClock(_ date: Date) -> String {
        Calendar.current.component(.minute, from: date) == 0
            ? date.formatted(.dateTime.hour())
            : date.formatted(.dateTime.hour().minute())
    }

    /// [1,2,3,4,5] → "Mon–Fri"; [6,7] → "Sat–Sun"; otherwise "Mon, Wed, Fri".
    static func weekdays(_ days: [Int]) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let sorted = Array(Set(days)).sorted().filter { (1...7).contains($0) }
        guard let first = sorted.first, let last = sorted.last else { return "No days" }
        if sorted.count == 7 { return "Every day" }
        if sorted.count > 2, sorted == Array(first...last) { return "\(names[first - 1])–\(names[last - 1])" }
        return sorted.map { names[$0 - 1] }.joined(separator: ", ")
    }

    static func priority(_ value: Int) -> String? {
        switch value {
        case 3...: "High"
        case ...1: "Low"
        default: nil
        }
    }

    /// One line describing how the server read a capture.
    static func captured(_ c: Captured, projectName: String? = nil) -> String {
        let project = c.newProject.map { "new project #\($0)" } ?? projectName
        switch c.kind {
        case .event:
            guard let start = c.startAt, let end = c.endAt else { return "Event: \(c.title)" }
            return ["Event · \(c.title)", project, "\(dayTime(start))–\(time(end))"].compactMap { $0 }.joined(separator: " · ")
        case .task:
            if let who = c.waitingOn {
                return ["Waiting on \(who) · \(c.title)", project, c.followUpAt.map { "follow up \(relative($0))" }].compactMap { $0 }.joined(separator: " · ")
            }
            var parts = ["Task · \(c.title)"]
            if let project { parts.append(project) }
            if let due = c.dueAt { parts.append("due \(relative(due))") }
            if let estimate = c.estimateMin { parts.append(duration(estimate)) }
            if let priority = priority(c.priority) { parts.append("\(priority.lowercased()) priority") }
            return parts.joined(separator: " · ")
        }
    }
}
