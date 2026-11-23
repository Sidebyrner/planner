import Foundation

/// One event (or one occurrence of a recurring event) on the device.
public struct DeviceEvent: Hashable, Sendable {
    /// The calendar's id for the event. Shared by every occurrence of a recurring event.
    public var identifier: String
    public var calendarID: String
    public var title: String
    public var notes: String?
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var isRecurring: Bool

    public init(identifier: String, calendarID: String, title: String, notes: String? = nil, start: Date, end: Date, allDay: Bool = false, isRecurring: Bool = false) {
        self.identifier = identifier
        self.calendarID = calendarID
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.allDay = allDay
        self.isRecurring = isRecurring
    }

    /// Unique per occurrence, as the server's `externalId` requires.
    public var occurrenceID: String {
        isRecurring ? "\(identifier)@\(PlannerJSON.format(start))" : identifier
    }
}

public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// The account it belongs to, e.g. "iCloud" or a Google address.
    public var source: String

    public init(id: String, title: String, source: String) {
        self.id = id
        self.title = title
        self.source = source
    }
}

public enum CalendarStoreError: Error, LocalizedError {
    case noAccess
    case noWritableSource
    case calendarMissing

    public var errorDescription: String? {
        switch self {
        case .noAccess: "Planner does not have access to your calendars."
        case .noWritableSource: "There is no calendar account Planner can add its calendar to."
        case .calendarMissing: "The Planner calendar is missing."
        }
    }
}

/// The calendars on this device, as the sync engine needs them.
@MainActor
public protocol CalendarStore: AnyObject {
    var hasAccess: Bool { get }
    func requestAccess() async throws -> Bool
    func calendars() -> [CalendarInfo]
    /// The calendar Planner writes task blocks into. Created when missing and `create` is true.
    func plannerCalendarID(create: Bool) throws -> String?
    /// Events overlapping [from, to) in the given calendars (all calendars when nil).
    func events(from: Date, to: Date, in calendarIDs: Set<String>?) -> [DeviceEvent]
    func event(withIdentifier identifier: String) -> DeviceEvent?
    /// Creates the event, or updates it when `identifier` names an existing one. Returns its identifier.
    func saveBlock(identifier: String?, title: String, notes: String, start: Date, end: Date, allDay: Bool, in calendarID: String) throws -> String
    func removeEvent(withIdentifier identifier: String) throws
}

extension CalendarStore {
    /// A timed (not all-day) event.
    public func saveBlock(identifier: String?, title: String, notes: String, start: Date, end: Date, in calendarID: String) throws -> String {
        try saveBlock(identifier: identifier, title: title, notes: notes, start: start, end: end, allDay: false, in: calendarID)
    }
}

// MARK: - In memory, for tests and SwiftUI previews

@MainActor
public final class InMemoryCalendarStore: CalendarStore {
    public var access: Bool
    public var calendarList: [CalendarInfo]
    public var items: [DeviceEvent]
    public var plannerID: String?

    public init(access: Bool = true, calendars: [CalendarInfo] = [], items: [DeviceEvent] = []) {
        self.access = access
        self.calendarList = calendars
        self.items = items
    }

    public var hasAccess: Bool { access }

    public func requestAccess() async throws -> Bool { access }

    public func calendars() -> [CalendarInfo] { calendarList }

    public func plannerCalendarID(create: Bool) throws -> String? {
        if plannerID == nil, create {
            let id = "planner-calendar"
            calendarList.append(CalendarInfo(id: id, title: "Planner", source: "On My Device"))
            plannerID = id
        }
        return plannerID
    }

    public func events(from: Date, to: Date, in calendarIDs: Set<String>?) -> [DeviceEvent] {
        items.filter { e in
            e.start < to && e.end > from && (calendarIDs?.contains(e.calendarID) ?? true)
        }
    }

    public func event(withIdentifier identifier: String) -> DeviceEvent? {
        items.first { $0.identifier == identifier }
    }

    public func saveBlock(identifier: String?, title: String, notes: String, start: Date, end: Date, allDay: Bool, in calendarID: String) throws -> String {
        let event = DeviceEvent(identifier: identifier ?? UUID().uuidString, calendarID: calendarID, title: title, notes: notes, start: start, end: end, allDay: allDay)
        if let index = items.firstIndex(where: { $0.identifier == event.identifier }) {
            items[index] = event
        } else {
            items.append(event)
        }
        return event.identifier
    }

    public func removeEvent(withIdentifier identifier: String) throws {
        items.removeAll { $0.identifier == identifier }
    }
}

// MARK: - EventKit

#if canImport(EventKit)
import EventKit

/// The real calendars, via EventKit. Needs NSCalendarsFullAccessUsageDescription in the app's Info.plist.
@MainActor
public final class EventKitCalendarStore: CalendarStore {
    public static let plannerCalendarTitle = "Planner"
    private static let plannerCalendarKey = "PlannerKit.plannerCalendarID"

    public let eventStore = EKEventStore()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    public func calendars() -> [CalendarInfo] {
        eventStore.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "")
        }
    }

    public func plannerCalendarID(create: Bool) throws -> String? {
        guard hasAccess else { throw CalendarStoreError.noAccess }
        if let id = defaults.string(forKey: Self.plannerCalendarKey), eventStore.calendar(withIdentifier: id) != nil {
            return id
        }
        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == Self.plannerCalendarTitle && $0.allowsContentModifications }) {
            defaults.set(existing.calendarIdentifier, forKey: Self.plannerCalendarKey)
            return existing.calendarIdentifier
        }
        guard create else { return nil }

        // iCloud first, so the calendar shows up on every device. Some accounts
        // (Google, Exchange) don't let apps add calendars, so try each in turn
        // and fall back to a calendar on this device.
        let sources = eventStore.sources
        var candidates = sources.filter { $0.sourceType == .calDAV && $0.title == "iCloud" }
        if let preferred = eventStore.defaultCalendarForNewEvents?.source { candidates.append(preferred) }
        candidates += sources.filter { $0.sourceType == .local }

        var tried = Set<String>()
        var lastError: Error = CalendarStoreError.noWritableSource
        for source in candidates where tried.insert(source.sourceIdentifier).inserted {
            let calendar = EKCalendar(for: .event, eventStore: eventStore)
            calendar.title = Self.plannerCalendarTitle
            calendar.source = source
            do {
                try eventStore.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: Self.plannerCalendarKey)
                return calendar.calendarIdentifier
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func events(from: Date, to: Date, in calendarIDs: Set<String>?) -> [DeviceEvent] {
        guard hasAccess else { return [] }
        var calendars: [EKCalendar]?
        if let calendarIDs {
            calendars = eventStore.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return eventStore.events(matching: predicate).map(DeviceEvent.init)
    }

    public func event(withIdentifier identifier: String) -> DeviceEvent? {
        eventStore.event(withIdentifier: identifier).map(DeviceEvent.init)
    }

    public func saveBlock(identifier: String?, title: String, notes: String, start: Date, end: Date, allDay: Bool, in calendarID: String) throws -> String {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else { throw CalendarStoreError.calendarMissing }
        let event = identifier.flatMap { eventStore.event(withIdentifier: $0) } ?? EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        try eventStore.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw CalendarStoreError.calendarMissing }
        return id
    }

    public func removeEvent(withIdentifier identifier: String) throws {
        guard let event = eventStore.event(withIdentifier: identifier) else { return }
        try eventStore.remove(event, span: .thisEvent, commit: true)
    }
}

extension DeviceEvent {
    init(_ event: EKEvent) {
        self.init(
            identifier: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            title: event.title ?? "",
            notes: event.notes,
            start: event.startDate,
            end: event.endDate,
            allDay: event.isAllDay,
            isRecurring: event.hasRecurrenceRules || event.isDetached
        )
    }
}
#endif
