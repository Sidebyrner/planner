import PlannerKit
import SwiftUI

/// The repeat rule as the form edits it. `rule` is what gets saved.
struct RepeatDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case never, daily, weekly, monthly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Never"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }
        var unit: String {
            switch self {
            case .never, .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            }
        }
    }

    var kind: Kind
    var interval: Int
    /// ISO weekdays, 1 = Monday.
    var weekdays: [Int]
    var monthDay: Int
    var leadTimeDays: Int

    /// Starts from the task's rule, or from its due date for sensible defaults.
    init(_ rule: Recurrence?, due: Date?) {
        let cal = Calendar(identifier: .gregorian)
        let anchor = due ?? Date()
        let isoWeekday = (cal.component(.weekday, from: anchor) + 5) % 7 + 1 // Sun = 1 -> 7, Mon = 2 -> 1
        kind = rule.map { Kind(rawValue: $0.freq.rawValue) ?? .never } ?? .never
        interval = max(rule?.interval ?? 1, 1)
        weekdays = (rule?.byDay ?? [isoWeekday]).sorted()
        monthDay = rule?.byMonthDay?.first ?? cal.component(.day, from: anchor)
        leadTimeDays = rule?.leadTimeDays ?? 0
    }

    var rule: Recurrence? {
        let lead = leadTimeDays > 0 ? leadTimeDays : nil
        let every = interval > 1 ? interval : nil
        switch kind {
        case .never: return nil
        case .daily: return Recurrence(freq: .daily, interval: every, leadTimeDays: lead)
        case .weekly: return Recurrence(freq: .weekly, interval: every, byDay: weekdays.isEmpty ? nil : weekdays, leadTimeDays: lead)
        case .monthly: return Recurrence(freq: .monthly, interval: every, byMonthDay: [monthDay], leadTimeDays: lead)
        }
    }
}

/// Repeat settings for a task: how often, which days, and how early the next one shows up.
struct RepeatSection: View {
    @Binding var rule: RepeatDraft
    let hasDue: Bool

    var body: some View {
        Section {
            Picker("Repeat", selection: $rule.kind) {
                ForEach(RepeatDraft.Kind.allCases) { Text($0.title).tag($0) }
            }
            if rule.kind != .never {
                Stepper(
                    rule.interval == 1 ? "Every \(rule.kind.unit)" : "Every \(rule.interval) \(rule.kind.unit)s",
                    value: $rule.interval, in: 1...52
                )
                if rule.kind == .weekly {
                    WeekdayPicker(days: $rule.weekdays)
                }
                if rule.kind == .monthly {
                    Stepper("On the \(Self.ordinal(rule.monthDay))", value: $rule.monthDay, in: 1...31)
                }
                Stepper(
                    rule.leadTimeDays == 0 ? "Show it right away" : "Show \(rule.leadTimeDays) day\(rule.leadTimeDays == 1 ? "" : "s") before it's due",
                    value: $rule.leadTimeDays, in: 0...30
                )
            }
        } header: {
            Text("Repeat")
        } footer: {
            if rule.kind != .never {
                Text(hasDue
                     ? "When you finish it, the next one is created. \(rule.rule?.summary ?? "")."
                     : "Give it a due date so the repeats line up; without one, the next is counted from when you finish.")
            }
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }
}

/// Email, call or text the person a task is waiting on.
struct ContactButtons: View {
    let name: String
    let email: String
    let phone: String
    var subject: String = ""

    private func url(_ s: String) -> URL? { URL(string: s) }
    private var cleanPhone: String { phone.filter { $0.isNumber || $0 == "+" } }
    private var mail: URL? {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = e
        if !subject.isEmpty { c.queryItems = [URLQueryItem(name: "subject", value: subject)] }
        return c.url
    }

    var body: some View {
        if mail != nil || !cleanPhone.isEmpty {
            HStack(spacing: 12) {
                if let mail {
                    Link(destination: mail) { Label("Email", systemImage: "envelope") }
                }
                if !cleanPhone.isEmpty, let call = url("tel:\(cleanPhone)") {
                    Link(destination: call) { Label("Call", systemImage: "phone") }
                }
                if !cleanPhone.isEmpty, let text = url("sms:\(cleanPhone)") {
                    Link(destination: text) { Label("Message", systemImage: "message") }
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name.isEmpty ? "Contact" : "Contact \(name)")
        }
    }
}

enum TaskLinkIcon {
    static func name(for url: URL) -> String {
        switch url.scheme?.lowercased() {
        case "mailto": return "envelope"
        case "tel": return "phone"
        default:
            let host = url.host()?.lowercased() ?? ""
            if host.contains("mail.google") { return "envelope" }
            if host.contains("docs.google") || host.contains("claude.ai") || host.contains("notion") { return "doc.text" }
            return "link"
        }
    }
}
