import Foundation

// Mirrors src/shared/types.ts. Keep the two in step.

public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case todo, done
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

    public var isDone: Bool { status == .done }
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

    public var isTaskBlock: Bool { taskId != nil }
    public var isReadOnly: Bool { source == .device }
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
}

public struct ProposedBlock: Codable, Identifiable, Hashable, Sendable {
    public var taskId: String
    public var title: String
    public var startAt: Date
    public var endAt: Date
    /// True when the block ends after the task's due time.
    public var late: Bool

    public var id: String { "\(taskId)@\(PlannerJSON.format(startAt))" }
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
}

public struct CaptureResult: Codable, Hashable, Sendable {
    public var parsed: Captured
    public var task: PlannerTask?
    public var event: CalEvent?
}

public struct GoogleStatus: Codable, Hashable, Sendable {
    public var configured: Bool
    public var connected: Bool
    public var lastSyncAt: Date?
    public var error: String?
}

public struct AppState: Codable, Hashable, Sendable {
    public var tasks: [PlannerTask]
    public var events: [CalEvent]
    public var settings: Settings
    public var google: GoogleStatus
}

// MARK: - Request bodies

public struct TaskDraft: Encodable, Hashable, Sendable {
    public var title: String
    public var notes: String?
    public var priority: Int?
    public var estimateMin: Int?
    public var dueAt: Date?

    public init(title: String, notes: String? = nil, priority: Int? = nil, estimateMin: Int? = nil, dueAt: Date? = nil) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.estimateMin = estimateMin
        self.dueAt = dueAt
    }
}

/// Only the fields that are set are sent. `dueAt: .some(nil)` clears the due date.
public struct TaskPatch: Encodable, Hashable, Sendable {
    public var title: String?
    public var notes: String?
    public var status: TaskStatus?
    public var priority: Int?
    public var estimateMin: Int?
    public var dueAt: Date??

    public init(title: String? = nil, notes: String? = nil, status: TaskStatus? = nil, priority: Int? = nil, estimateMin: Int? = nil, dueAt: Date?? = nil) {
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.estimateMin = estimateMin
        self.dueAt = dueAt
    }

    private enum CodingKeys: String, CodingKey { case title, notes, status, priority, estimateMin, dueAt }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(estimateMin, forKey: .estimateMin)
        switch dueAt {
        case .none: break
        case .some(.none): try c.encodeNil(forKey: .dueAt)
        case .some(.some(let date)): try c.encode(date, forKey: .dueAt)
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

    public init(title: String, notes: String? = nil, startAt: Date, endAt: Date, allDay: Bool? = nil, taskId: String? = nil) {
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.taskId = taskId
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

    public init(timezone: String? = nil, timezoneConfirmed: Bool? = nil, workStart: String? = nil, workEnd: String? = nil, workDays: [Int]? = nil, maxBlockMin: Int? = nil, horizonDays: Int? = nil) {
        self.timezone = timezone
        self.timezoneConfirmed = timezoneConfirmed
        self.workStart = workStart
        self.workEnd = workEnd
        self.workDays = workDays
        self.maxBlockMin = maxBlockMin
        self.horizonDays = horizonDays
    }
}

/// One block to book, from a `ProposedBlock` the user accepted.
public struct BlockBooking: Encodable, Hashable, Sendable {
    public var taskId: String
    public var startAt: Date
    public var endAt: Date

    public init(taskId: String, startAt: Date, endAt: Date) {
        self.taskId = taskId
        self.startAt = startAt
        self.endAt = endAt
    }

    public init(_ block: ProposedBlock) {
        self.init(taskId: block.taskId, startAt: block.startAt, endAt: block.endAt)
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
