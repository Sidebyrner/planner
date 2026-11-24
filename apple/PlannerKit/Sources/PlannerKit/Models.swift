import Foundation

// Mirrors src/shared/types.ts. Keep the two in step.

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    /// Open and schedulable.
    case todo
    /// On someone else; never scheduled, comes back to todo at followUpAt.
    case waiting
    case done

    /// A status this build doesn't know reads as todo rather than failing the whole state.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskStatus(rawValue: raw) ?? .todo
    }
}

public struct ChecklistItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var done: Bool

    public init(id: String = UUID().uuidString, text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// What a task or project depends on: an email thread, a doc, a contract.
/// Named `TaskLink` so it doesn't clash with SwiftUI's `Link`.
public struct TaskLink: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var url: String

    public var id: String { "\(label)|\(url)" }
    /// Only schemes the server accepts and the app can open.
    public var destination: URL? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), ["https", "http", "mailto", "tel"].contains(scheme) else { return nil }
        return u
    }

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }

    /// Turns what someone typed into a link: adds https:// to a bare domain, mailto: to an email address.
    public static func normalized(label: String, url raw: String) -> TaskLink? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if !url.contains(":") {
            url = url.contains("@") && !url.contains("/") ? "mailto:\(url)" : "https://\(url)"
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = TaskLink(label: name.isEmpty ? (URL(string: url)?.host() ?? url) : name, url: url)
        return link.destination == nil ? nil : link
    }
}

/// Who a waiting task is on, and how to reach them.
public struct Contact: Codable, Hashable, Sendable {
    public var name: String
    public var email: String?
    public var phone: String?

    public init(name: String, email: String? = nil, phone: String? = nil) {
        self.name = name
        self.email = email
        self.phone = phone
    }
}

/// How a task repeats. Completing one instance makes the server create the next.
public struct Recurrence: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly
    }

    public var freq: Frequency
    /// Every n days / weeks / months. nil = 1.
    public var interval: Int?
    /// ISO weekdays (1 = Monday) for weekly repeats.
    public var byDay: [Int]?
    /// Days of the month for monthly repeats; 31 means the month's last day when shorter.
    public var byMonthDay: [Int]?
    /// Keep the next one hidden until this many days before it's due.
    public var leadTimeDays: Int?

    public init(freq: Frequency, interval: Int? = nil, byDay: [Int]? = nil, byMonthDay: [Int]? = nil, leadTimeDays: Int? = nil) {
        self.freq = freq
        self.interval = interval
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.leadTimeDays = leadTimeDays
    }

    /// "Every week on Tue, Fri", "Monthly on the 15th · shows 3 days before".
    public var summary: String {
        let n = max(interval ?? 1, 1)
        var text: String
        switch freq {
        case .daily: text = n == 1 ? "Every day" : "Every \(n) days"
        case .weekly:
            text = n == 1 ? "Every week" : "Every \(n) weeks"
            if let days = byDay, !days.isEmpty {
                let names = Calendar(identifier: .gregorian).shortWeekdaySymbols // Sun = 0
                text += " on " + days.sorted().map { names[$0 % 7] }.joined(separator: ", ")
            }
        case .monthly:
            text = n == 1 ? "Monthly" : "Every \(n) months"
            if let days = byMonthDay, !days.isEmpty {
                text += " on the " + days.sorted().map(Self.ordinal).joined(separator: " and ")
            }
        }
        if let lead = leadTimeDays, lead > 0 {
            text += " · shows \(lead) day\(lead == 1 ? "" : "s") before"
        }
        return text
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }
}

/// A task. Named `PlannerTask` because `Task` is Swift's concurrency type.
public struct PlannerTask: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var status: TaskStatus
    /// 1 = low, 2 = normal, 3 = high
    public var priority: Int
    public var estimateMin: Int
    public var dueAt: Date?
    public var createdAt: Date
    public var completedAt: Date?
    public var projectId: String? = nil
    public var checklist: [ChecklistItem] = []
    /// Who it's waiting on; still set after a follow-up comes back to todo.
    public var waitingOn: String? = nil
    public var followUpAt: Date? = nil
    public var links: [TaskLink] = []
    public var contact: Contact? = nil
    /// Where it came from ("gmail", "claude", "manual"), set by agents.
    public var source: String? = nil
    public var externalRef: String? = nil
    public var recurrence: Recurrence? = nil
    /// Shared by every instance of a repeating task.
    public var seriesId: String? = nil
    /// A repeating task stays out of sight until this time (its lead time).
    public var showFrom: Date? = nil
    /// When the current wait (or the last chase) began. Set by the server.
    public var waitingSince: Date? = nil
    /// When the person emailed back, found by the server through Gmail.
    public var repliedAt: Date? = nil
    /// The start of that email.
    public var replySnippet: String? = nil

    public var isDone: Bool { status == .done }
    public var repeats: Bool { recurrence != nil }
    /// Not shown yet: a repeating task still waiting for its lead time.
    public func isUpcoming(now: Date = Date()) -> Bool { showFrom.map { $0 > now } ?? false }
    public var isWaiting: Bool { status == .waiting }
    /// They emailed back since the wait began.
    public var hasReply: Bool { repliedAt != nil && !isDone }
    public var checklistProgress: String? {
        checklist.isEmpty ? nil : "\(checklist.filter(\.done).count)/\(checklist.count)"
    }
}

extension PlannerTask {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, status, priority, estimateMin, dueAt, createdAt, completedAt, projectId, checklist, waitingOn, followUpAt
        case links, contact, source, externalRef, recurrence, seriesId, showFrom
        case waitingSince, repliedAt, replySnippet
    }

    /// Fields added later are optional, so a cache or server from before them still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        status = try c.decode(TaskStatus.self, forKey: .status)
        priority = try c.decode(Int.self, forKey: .priority)
        estimateMin = try c.decode(Int.self, forKey: .estimateMin)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist) ?? []
        waitingOn = try c.decodeIfPresent(String.self, forKey: .waitingOn)
        followUpAt = try c.decodeIfPresent(Date.self, forKey: .followUpAt)
        links = try c.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
        contact = try c.decodeIfPresent(Contact.self, forKey: .contact)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        externalRef = try c.decodeIfPresent(String.self, forKey: .externalRef)
        // A repeat rule this build can't read is dropped rather than failing the whole state.
        recurrence = try? c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        showFrom = try c.decodeIfPresent(Date.self, forKey: .showFrom)
        waitingSince = try c.decodeIfPresent(Date.self, forKey: .waitingSince)
        repliedAt = try c.decodeIfPresent(Date.self, forKey: .repliedAt)
        replySnippet = try c.decodeIfPresent(String.self, forKey: .replySnippet)
    }
}

public enum ProjectColor: String, Codable, Sendable, CaseIterable {
    case amber, teal, indigo, rose, green, violet, orange, slate

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProjectColor(rawValue: raw) ?? .slate
    }
}

/// A weekly window, e.g. weekdays 06:45–08:15, in the user's timezone.
public struct TimeWindow: Codable, Hashable, Sendable {
    /// ISO weekdays, 1 = Monday … 7 = Sunday
    public var days: [Int]
    public var start: String
    public var end: String

    public init(days: [Int], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Used as #tag in capture.
    public var tag: String
    public var color: ProjectColor
    public var emoji: String
    public var archived: Bool
    public var sortOrder: Int
    /// When its tasks may be scheduled. Empty = working hours.
    public var windows: [TimeWindow]
    public var windowStrict: Bool
    /// Calendar events whose title contains this become time for this project.
    public var hostMatch: String?
    public var links: [TaskLink] = []

    public var label: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, tag, color, emoji, archived, sortOrder, windows, windowStrict, hostMatch, links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tag = try c.decode(String.self, forKey: .tag)
        color = try c.decode(ProjectColor.self, forKey: .color)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        windows = try c.decodeIfPresent([TimeWindow].self, forKey: .windows) ?? []
        windowStrict = try c.decodeIfPresent(Bool.self, forKey: .windowStrict) ?? false
        hostMatch = try c.decodeIfPresent(String.self, forKey: .hostMatch)
        links = try c.decodeIfPresent([TaskLink].self, forKey: .links) ?? []
    }
}

public enum EventSource: String, Codable, Sendable {
    /// Created in Planner (including task blocks).
    case local
    /// Pulled from Google Calendar by the server.
    case google
    /// Mirrored from the calendars on a Mac or iPhone. Read-only on the server.
    case device
}

public struct CalEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
    /// Set when this event is a time block reserved for a task.
    public var taskId: String?
    public var googleId: String?
    public var externalId: String?
    public var source: EventSource
    /// Its own project, or its task's project for task blocks.
    public var projectId: String? = nil
    /// Tasks sharing a Quick block. Empty otherwise.
    public var taskIds: [String] = []
    /// The scheduler leaves this event out (set with ignore_event).
    public var ignored: Bool = false
    /// For a finished task block: whether the work happened.
    public var outcome: BlockOutcome? = nil

    /// A block reserved for one task, or a Quick block for several.
    public var isTaskBlock: Bool { taskId != nil || !taskIds.isEmpty }
    public var isBatch: Bool { !taskIds.isEmpty }
    public var isReadOnly: Bool { source == .device }
    /// Every task this block is for.
    public var allTaskIds: [String] { taskId.map { [$0] } ?? taskIds }
}

extension CalEvent {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, startAt, endAt, allDay, taskId, googleId, externalId, source, projectId, taskIds, ignored, outcome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decode(Date.self, forKey: .endAt)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        googleId = try c.decodeIfPresent(String.self, forKey: .googleId)
        externalId = try c.decodeIfPresent(String.self, forKey: .externalId)
        source = try c.decode(EventSource.self, forKey: .source)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        taskIds = try c.decodeIfPresent([String].self, forKey: .taskIds) ?? []
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        outcome = try? c.decodeIfPresent(BlockOutcome.self, forKey: .outcome)
    }
}

public enum BlockOutcome: String, Codable, Sendable {
    case done, missed
}

/// What marking a block returned: the block, its tasks as they are now, and new time
/// proposed for missed work.
public struct BlockMarkResult: Decodable, Sendable {
    public var block: CalEvent
    public var tasks: [PlannerTask]
    public var replan: ScheduleProposal?
}

public struct Settings: Codable, Hashable, Sendable {
    /// IANA zone used for working hours and for reading typed dates.
    public var timezone: String
    public var timezoneConfirmed: Bool
    /// "09:00"
    public var workStart: String
    /// "17:00"
    public var workEnd: String
    /// ISO weekdays, 1 = Monday … 7 = Sunday
    public var workDays: [Int]
    public var maxBlockMin: Int
    public var horizonDays: Int
    /// Minutes kept free around long fixed events. 0 = off.
    public var bufferMin: Int = 0
    public var bufferMinEventMin: Int = 120
}

extension Settings {
    private enum CodingKeys: String, CodingKey {
        case timezone, timezoneConfirmed, workStart, workEnd, workDays, maxBlockMin, horizonDays, bufferMin, bufferMinEventMin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timezone = try c.decode(String.self, forKey: .timezone)
        timezoneConfirmed = try c.decodeIfPresent(Bool.self, forKey: .timezoneConfirmed) ?? false
        workStart = try c.decode(String.self, forKey: .workStart)
        workEnd = try c.decode(String.self, forKey: .workEnd)
        workDays = try c.decode([Int].self, forKey: .workDays)
        maxBlockMin = try c.decode(Int.self, forKey: .maxBlockMin)
        horizonDays = try c.decode(Int.self, forKey: .horizonDays)
        bufferMin = try c.decodeIfPresent(Int.self, forKey: .bufferMin) ?? 0
        bufferMinEventMin = try c.decodeIfPresent(Int.self, forKey: .bufferMinEventMin) ?? 120
    }
}

public struct ProposedBlock: Codable, Identifiable, Hashable, Sendable {
    /// The task, or the first task of a Quick batch.
    public var taskId: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    /// True when the block ends after the task's due time.
    public var late: Bool
    /// Every task in a Quick batch; nil for a single task.
    public var taskIds: [String]? = nil
    public var projectId: String? = nil
    /// The project's own hours were full, so working hours were used.
    public var outsideWindow: Bool? = nil

    public var id: String { "\(taskId)@\(PlannerJSON.format(startAt))" }
    public var isBatch: Bool { (taskIds?.count ?? 0) > 1 }
}

public struct ScheduleProposal: Codable, Hashable, Sendable {
    public struct Unscheduled: Codable, Hashable, Sendable {
        public var taskId: String
        public var title: String
        public var remainingMin: Int
    }

    public var blocks: [ProposedBlock]
    /// Tasks that did not fit inside the planning horizon.
    public var unscheduled: [Unscheduled]
}

public struct FreeSlot: Codable, Hashable, Sendable {
    public var startAt: Date
    public var endAt: Date
    public var minutes: Int
}

public struct Captured: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case task, event }

    public var kind: Kind
    public var title: String
    public var priority: Int
    public var estimateMin: Int?
    public var dueAt: Date?
    public var startAt: Date?
    public var endAt: Date?
    /// The #tag as typed.
    public var projectTag: String? = nil
    public var projectId: String? = nil
    /// The tag matched no project; one is created on save.
    public var newProject: String? = nil
    /// "@Sam …" makes a waiting-on task.
    public var waitingOn: String? = nil
    public var followUpAt: Date? = nil
}

public struct CaptureResult: Codable, Hashable, Sendable {
    public var parsed: Captured
    public var task: PlannerTask?
    public var event: CalEvent?
    public var project: Project?
}

public struct GoogleStatus: Codable, Hashable, Sendable {
    public var configured: Bool
    public var connected: Bool
    public var lastSyncAt: Date?
    public var error: String?
}

public struct GmailStatus: Codable, Hashable, Sendable {
    public var configured: Bool
    public var connected: Bool
    public var lastCheckAt: Date?
    public var error: String?
    /// Connected with permission to send, so replies can go from the app.
    public var canReply: Bool? = nil
}

public struct AppState: Codable, Hashable, Sendable {
    public var tasks: [PlannerTask]
    public var events: [CalEvent]
    public var settings: Settings
    public var google: GoogleStatus
    public var projects: [Project] = []
    public var gmail: GmailStatus? = nil
}

extension AppState {
    private enum CodingKeys: String, CodingKey { case tasks, events, settings, google, projects, gmail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([PlannerTask].self, forKey: .tasks)
        events = try c.decode([CalEvent].self, forKey: .events)
        settings = try c.decode(Settings.self, forKey: .settings)
        google = try c.decode(GoogleStatus.self, forKey: .google)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        gmail = try? c.decodeIfPresent(GmailStatus.self, forKey: .gmail)
    }
}

// MARK: - Inbox (Gmail)

public struct InboxThread: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var subject: String
    public var snippet: String
    public var lastAt: Date
    public var unread: Bool
    public var messageCount: Int
}

/// Everyone who's emailed you lately, with their threads, like a Messages list.
public struct InboxPerson: Codable, Hashable, Sendable, Identifiable {
    public var email: String
    public var name: String
    public var lastAt: Date
    public var unread: Int
    public var threads: [InboxThread]
    /// Open tasks with this person as their contact.
    public var taskIds: [String]
    public var id: String { email.lowercased() }
}

public struct InboxAddress: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
}

public struct InboxMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var from: InboxAddress
    public var fromMe: Bool
    public var at: Date
    public var text: String
}

public struct InboxConversation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var subject: String
    public var messages: [InboxMessage]
}

// MARK: - Request bodies

public struct TaskDraft: Encodable, Hashable, Sendable {
    public var title: String
    public var notes: String?
    public var priority: Int?
    public var estimateMin: Int?
    public var dueAt: Date?
    public var projectId: String?
    public var links: [TaskLink]?
    public var recurrence: Recurrence?

    public init(
        title: String, notes: String? = nil, priority: Int? = nil, estimateMin: Int? = nil, dueAt: Date? = nil, projectId: String? = nil,
        links: [TaskLink]? = nil, recurrence: Recurrence? = nil
    ) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.estimateMin = estimateMin
        self.dueAt = dueAt
        self.projectId = projectId
        self.links = links
        self.recurrence = recurrence
    }
}

/// Only the fields that are set are sent. A double optional set to `.some(nil)` clears that field.
public struct TaskPatch: Encodable, Hashable, Sendable {
    public var title: String?
    public var notes: String?
    public var status: TaskStatus?
    public var priority: Int?
    public var estimateMin: Int?
    public var dueAt: Date??
    public var projectId: String??
    public var checklist: [ChecklistItem]?
    public var waitingOn: String??
    public var followUpAt: Date??
    public var links: [TaskLink]?
    public var contact: Contact??
    public var recurrence: Recurrence??

    public init(
        title: String? = nil, notes: String? = nil, status: TaskStatus? = nil, priority: Int? = nil, estimateMin: Int? = nil,
        dueAt: Date?? = nil, projectId: String?? = nil, checklist: [ChecklistItem]? = nil, waitingOn: String?? = nil, followUpAt: Date?? = nil,
        links: [TaskLink]? = nil, contact: Contact?? = nil, recurrence: Recurrence?? = nil
    ) {
        self.links = links
        self.contact = contact
        self.recurrence = recurrence
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.estimateMin = estimateMin
        self.dueAt = dueAt
        self.projectId = projectId
        self.checklist = checklist
        self.waitingOn = waitingOn
        self.followUpAt = followUpAt
    }

    private enum CodingKeys: String, CodingKey {
        case title, notes, status, priority, estimateMin, dueAt, projectId, checklist, waitingOn, followUpAt, links, contact, recurrence
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(estimateMin, forKey: .estimateMin)
        try c.encodeIfPresent(checklist, forKey: .checklist)
        try Self.encode(dueAt, .dueAt, &c)
        try Self.encode(projectId, .projectId, &c)
        try Self.encode(waitingOn, .waitingOn, &c)
        try Self.encode(followUpAt, .followUpAt, &c)
        try c.encodeIfPresent(links, forKey: .links)
        try Self.encode(contact, .contact, &c)
        try Self.encode(recurrence, .recurrence, &c)
    }

    private static func encode<T: Encodable>(_ value: T??, _ key: CodingKeys, _ c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch value {
        case .none: break
        case .some(.none): try c.encodeNil(forKey: key)
        case .some(.some(let v)): try c.encode(v, forKey: key)
        }
    }
}

/// Fields for creating or changing a project. Only set fields are sent.
public struct ProjectPatch: Encodable, Hashable, Sendable {
    public var name: String?
    public var tag: String?
    public var color: ProjectColor?
    public var emoji: String?
    public var archived: Bool?
    public var windows: [TimeWindow]?
    public var windowStrict: Bool?
    public var hostMatch: String??

    public init(
        name: String? = nil, tag: String? = nil, color: ProjectColor? = nil, emoji: String? = nil, archived: Bool? = nil,
        windows: [TimeWindow]? = nil, windowStrict: Bool? = nil, hostMatch: String?? = nil
    ) {
        self.name = name
        self.tag = tag
        self.color = color
        self.emoji = emoji
        self.archived = archived
        self.windows = windows
        self.windowStrict = windowStrict
        self.hostMatch = hostMatch
    }

    private enum CodingKeys: String, CodingKey { case name, tag, color, emoji, archived, windows, windowStrict, hostMatch }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeIfPresent(windows, forKey: .windows)
        try c.encodeIfPresent(windowStrict, forKey: .windowStrict)
        switch hostMatch {
        case .none: break
        case .some(.none): try c.encodeNil(forKey: .hostMatch)
        case .some(.some(let v)): try c.encode(v, forKey: .hostMatch)
        }
    }
}

public struct EventDraft: Encodable, Hashable, Sendable {
    public var title: String
    public var notes: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool?
    public var taskId: String?
    public var projectId: String?

    public init(title: String, notes: String? = nil, startAt: Date, endAt: Date, allDay: Bool? = nil, taskId: String? = nil, projectId: String? = nil) {
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.taskId = taskId
        self.projectId = projectId
    }
}

public struct EventPatch: Encodable, Hashable, Sendable {
    public var title: String?
    public var notes: String?
    public var startAt: Date?
    public var endAt: Date?
    public var allDay: Bool?

    public init(title: String? = nil, notes: String? = nil, startAt: Date? = nil, endAt: Date? = nil, allDay: Bool? = nil) {
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
    }
}

public struct SettingsPatch: Encodable, Hashable, Sendable {
    public var timezone: String?
    public var timezoneConfirmed: Bool?
    public var workStart: String?
    public var workEnd: String?
    public var workDays: [Int]?
    public var maxBlockMin: Int?
    public var horizonDays: Int?
    public var bufferMin: Int?
    public var bufferMinEventMin: Int?

    public init(
        timezone: String? = nil, timezoneConfirmed: Bool? = nil, workStart: String? = nil, workEnd: String? = nil, workDays: [Int]? = nil,
        maxBlockMin: Int? = nil, horizonDays: Int? = nil, bufferMin: Int? = nil, bufferMinEventMin: Int? = nil
    ) {
        self.timezone = timezone
        self.timezoneConfirmed = timezoneConfirmed
        self.workStart = workStart
        self.workEnd = workEnd
        self.workDays = workDays
        self.maxBlockMin = maxBlockMin
        self.horizonDays = horizonDays
        self.bufferMin = bufferMin
        self.bufferMinEventMin = bufferMinEventMin
    }
}

/// One block to book, from a `ProposedBlock` the user accepted.
public struct BlockBooking: Encodable, Hashable, Sendable {
    public var taskId: String
    /// Set for a Quick block shared by several short tasks.
    public var taskIds: [String]?
    public var startAt: Date
    public var endAt: Date

    public init(taskId: String, taskIds: [String]? = nil, startAt: Date, endAt: Date) {
        self.taskId = taskId
        self.taskIds = taskIds
        self.startAt = startAt
        self.endAt = endAt
    }

    public init(_ block: ProposedBlock) {
        self.init(taskId: block.taskId, taskIds: block.taskIds, startAt: block.startAt, endAt: block.endAt)
    }
}

// MARK: - Device sync (PUT /api/device/events, see src/server/device.ts)

public struct MirroredEvent: Encodable, Hashable, Sendable {
    public var externalId: String
    public var title: String
    public var notes: String?
    public var startAt: Date
    public var endAt: Date
    public var allDay: Bool
}

public enum BlockChange: Encodable, Hashable, Sendable {
    case moved(id: String, startAt: Date, endAt: Date)
    case deleted(id: String)

    public var id: String {
        switch self {
        case .moved(let id, _, _), .deleted(let id): id
        }
    }

    private enum CodingKeys: String, CodingKey { case id, startAt, endAt, deleted }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .moved(id, startAt, endAt):
            try c.encode(id, forKey: .id)
            try c.encode(startAt, forKey: .startAt)
            try c.encode(endAt, forKey: .endAt)
        case let .deleted(id):
            try c.encode(id, forKey: .id)
            try c.encode(true, forKey: .deleted)
        }
    }
}

public struct DeviceSyncRequest: Encodable, Hashable, Sendable {
    public var from: Date
    public var to: Date
    public var events: [MirroredEvent]
    public var blockChanges: [BlockChange]
}

public struct DeviceSyncResult: Decodable, Hashable, Sendable {
    public struct Rejection: Decodable, Hashable, Sendable {
        public var id: String
        public var reason: String
    }

    public var upserted: Int
    public var removed: Int
    /// Task blocks in the window as the server now has them.
    public var blocks: [CalEvent]
    public var rejected: [Rejection]
}
