import AppIntents
import Foundation
import PlannerKit

// Siri and Shortcuts. Each intent talks to the server directly with the saved address and
// Keychain token, so it works without the app on screen. App Intents need no Siri entitlement.

enum PlannerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSetUp

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp: "Open Planner and connect it to your server first."
        }
    }
}

enum IntentClient {
    static func api() throws -> PlannerAPI {
        guard let raw = SharedCredentials.serverURL,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.host() != nil,
              let token = SharedCredentials.token, !token.isEmpty
        else { throw PlannerIntentError.notSetUp }
        return PlannerAPI(baseURL: url, token: token)
    }

    static func openTasks() async throws -> [PlannerTask] {
        try await api().state().tasks.filter { $0.status == .todo && !$0.isUpcoming() }
    }

    /// What Siri says after a capture.
    static func describe(_ r: CaptureResult, projects: [Project]) -> String {
        let projectName = (r.task?.projectId ?? r.event?.projectId).flatMap { id in projects.first { $0.id == id }?.name }
            ?? r.project?.name
        let in_ = projectName.map { " in \($0)" } ?? ""
        if let event = r.event {
            return "Added “\(event.title)”\(in_), \(Format.relative(event.startAt))."
        }
        guard let task = r.task else { return "Added it." }
        if task.isWaiting, let who = task.waitingOn {
            let when = task.followUpAt.map { " I'll bring it back \(Format.relative($0))." } ?? ""
            return "Added “\(task.title)”\(in_), waiting on \(who).\(when)"
        }
        let due = task.dueAt.map { ", due \(Format.relative($0))" } ?? ""
        return "Added “\(task.title)”\(in_)\(due)."
    }

    /// "“A” at 3 PM, “B” at 5 PM and “C” at 6 PM"
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

// MARK: - Add

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Planner"
    static var description = IntentDescription("Adds a task or event, read like the capture bar: dates, times, durations, #project and @person.")

    @Parameter(title: "What", requestValueDialog: "What should I add?")
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Planner") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = try IntentClient.api()
        let result = try await api.capture(text)
        let projects = (try? await api.projects()) ?? []
        return .result(dialog: "\(IntentClient.describe(result, projects: projects))")
    }
}

// MARK: - What's next

struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next"
    static var description = IntentDescription("Says what you're doing now and what's next on your calendar.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await IntentClient.api().state()
        let now = Date()
        let timed = state.events.filter { !$0.allDay }.sorted { $0.startAt < $1.startAt }
        let current = timed.last { $0.startAt <= now && $0.endAt > now }
        let next = timed.first { $0.startAt > now }

        var parts: [String] = []
        if let current {
            parts.append("You're in “\(current.title)” until \(Format.time(current.endAt)).")
        }
        if let next {
            let minutes = Int(next.startAt.timeIntervalSince(now) / 60)
            let when = minutes < 90 ? "in \(Format.duration(max(minutes, 1)))" : Format.relative(next.startAt)
            parts.append("\(current == nil ? "Next" : "After that") is “\(next.title)” \(when).")
        }
        if parts.isEmpty { parts.append("Nothing else is on your calendar.") }
        return .result(dialog: "\(parts.joined(separator: " "))")
    }
}

// MARK: - Plan my day

struct PlanDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Plan My Day"
    static var description = IntentDescription("Books time today for open tasks, the same way Plan does in the app, and tells you what it booked.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = try IntentClient.api()
        let proposal = try await api.proposeSchedule()
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let today = proposal.blocks.filter { $0.startAt < endOfDay }
        guard !today.isEmpty else {
            let more = proposal.blocks.first.map { " The next free slot I found is \(Format.relative($0.startAt))." } ?? ""
            return .result(dialog: "There's no free time left today for your open tasks.\(more)")
        }
        _ = try await api.applySchedule(today.map(BlockBooking.init))
        let names = today.map { "“\($0.title)” at \(Format.time($0.startAt))" }
        return .result(dialog: "Booked \(today.count == 1 ? "one block" : "\(today.count) blocks"): \(IntentClient.list(names)).")
    }
}

// MARK: - Complete

struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = TaskQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct TaskQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        try await IntentClient.openTasks().filter { identifiers.contains($0.id) }.map { TaskEntity(id: $0.id, title: $0.title) }
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        try await IntentClient.openTasks()
            .filter { $0.title.localizedCaseInsensitiveContains(string) }
            .map { TaskEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        try await IntentClient.openTasks().prefix(30).map { TaskEntity(id: $0.id, title: $0.title) }
    }
}

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Task Done"
    static var description = IntentDescription("Completes an open task and gives back any time booked for it.")

    @Parameter(title: "Task", requestValueDialog: "Which task?")
    var task: TaskEntity

    static var parameterSummary: some ParameterSummary { Summary("Mark \(\.$task) done") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentClient.api().updateTask(id: task.id, TaskPatch(status: .done))
        return .result(dialog: "Done: “\(task.title)”.")
    }
}

// MARK: - Waiting on

struct WaitingOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Who Am I Waiting On"
    static var description = IntentDescription("Lists what other people owe you, and follow-ups that are due.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tasks = try await IntentClient.api().state().tasks
        let due = tasks.filter { $0.status == .todo && $0.waitingOn != nil }
        let waiting = tasks.filter(\.isWaiting).sorted { ($0.followUpAt ?? .distantFuture) < ($1.followUpAt ?? .distantFuture) }

        var parts: [String] = []
        if !due.isEmpty {
            parts.append("Time to follow up with \(IntentClient.list(due.map { "\($0.waitingOn ?? "someone") about “\($0.title)”" })).")
        }
        if !waiting.isEmpty {
            let items = waiting.prefix(5).map { t in
                "\(t.waitingOn ?? "someone") on “\(t.title)”" + (t.followUpAt.map { ", \(Format.relative($0))" } ?? "")
            }
            parts.append("You're waiting on \(IntentClient.list(Array(items))).")
        }
        if parts.isEmpty { parts.append("You're not waiting on anyone.") }
        return .result(dialog: "\(parts.joined(separator: " "))")
    }
}

// MARK: - Phrases

struct PlannerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: ["Add a task in \(.applicationName)", "Add to \(.applicationName)", "New \(.applicationName) task"],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: WhatsNextIntent(),
            phrases: ["What's next in \(.applicationName)", "What's next on \(.applicationName)"],
            shortTitle: "What's Next",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: PlanDayIntent(),
            phrases: ["Plan my day in \(.applicationName)", "Plan my day with \(.applicationName)"],
            shortTitle: "Plan My Day",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: ["Mark a task done in \(.applicationName)", "Complete a task in \(.applicationName)"],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: WaitingOnIntent(),
            phrases: ["Who am I waiting on in \(.applicationName)", "What am I waiting on in \(.applicationName)"],
            shortTitle: "Waiting On",
            systemImageName: "hourglass"
        )
    }
}
