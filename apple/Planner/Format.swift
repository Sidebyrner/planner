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

    /// "today 17:00", "tomorrow 09:00", or "Fri 28 Nov, 17:00".
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(time(date))" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time(date))" }
        return dayTime(date)
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
