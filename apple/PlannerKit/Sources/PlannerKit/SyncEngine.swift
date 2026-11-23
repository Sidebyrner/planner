import Foundation

/// Keeps the device calendar and the Planner server in step:
///
/// 1. Mirror the busy calendars to the server (`PUT /api/device/events`) so the
///    scheduler plans around real events.
/// 2. Report task blocks the user moved or deleted in the Planner calendar.
/// 3. Make the Planner calendar match the blocks the server returns.
/// 4. Fetch and cache the full state for the UI.
///
/// The server is the source of truth for task blocks: if it rejects a move,
/// the block goes back to where the server has it.
@MainActor
public final class SyncEngine {
    public struct Options: Sendable {
        /// Whether this device is the calendar bridge: it mirrors busy time to the
        /// server and writes Planner events into the Planner calendar. Only one
        /// device should be, or the server's mirror flips between devices and a
        /// shared (iCloud) Planner calendar gets duplicate events.
        public var isCalendarBridge: Bool
        public var pastDays: Int
        public var futureDays: Int
        /// Calendars that count as busy time. nil = every calendar except Planner's.
        public var busyCalendarIDs: Set<String>?

        public init(isCalendarBridge: Bool = true, pastDays: Int = 14, futureDays: Int = 60, busyCalendarIDs: Set<String>? = nil) {
            self.isCalendarBridge = isCalendarBridge
            self.pastDays = pastDays
            self.futureDays = futureDays
            self.busyCalendarIDs = busyCalendarIDs
        }
    }

    public struct Report: Sendable {
        /// False when there was no calendar access, so only state was fetched.
        public var calendarSynced = false
        public var uploaded = 0
        public var blockChangesSent = 0
        public var blocksWritten = 0
        public var blocksRemoved = 0
        public var rejected: [DeviceSyncResult.Rejection] = []
        public var state: AppState?
    }

    // Server limits from src/server/device.ts.
    static let maxEvents = 5000
    static let maxBlockChanges = 1000

    public var api: PlannerAPI
    public var options: Options
    public let calendar: CalendarStore
    public let cache: PlannerCache
    var now: () -> Date

    public private(set) var ledger: BlockLedger
    private var inFlight: Task<Report, Error>?

    public init(api: PlannerAPI, calendar: CalendarStore, cache: PlannerCache, options: Options = Options(), now: @escaping () -> Date = Date.init) {
        self.api = api
        self.calendar = calendar
        self.cache = cache
        self.options = options
        self.now = now
        self.ledger = cache.loadLedger()
    }

    /// The last state saved to disk, for showing something before the first sync.
    public func cachedState() -> AppState? {
        cache.loadState()
    }

    /// Runs one sync. Calls made while a sync is running share its result.
    @discardableResult
    public func sync() async throws -> Report {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await self.performSync() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync() async throws -> Report {
        var report = Report()

        // Without calendar access, never send an empty mirror: it would wipe the
        // server's copy of this device's events.
        if options.isCalendarBridge, calendar.hasAccess, let plannerID = try calendar.plannerCalendarID(create: true) {
            let start = now()
            let from = start.addingTimeInterval(-Double(options.pastDays) * 86_400)
            let to = start.addingTimeInterval(Double(options.futureDays) * 86_400)

            let busyIDs = (options.busyCalendarIDs ?? Set(calendar.calendars().map(\.id))).subtracting([plannerID])
            let mirrored = calendar.events(from: from, to: to, in: busyIDs)
                .filter { $0.calendarID != plannerID && $0.end > $0.start }
                .sorted { $0.start < $1.start }
                .prefix(Self.maxEvents)
                .map(MirroredEvent.init)
            let changes = Array(blockChanges().prefix(Self.maxBlockChanges))

            let result = try await api.syncDevice(DeviceSyncRequest(from: from, to: to, events: Array(mirrored), blockChanges: changes))
            report.calendarSynced = true
            report.uploaded = mirrored.count
            report.blockChangesSent = changes.count
            report.rejected = result.rejected

            let (written, removed) = try applyBlocks(result.blocks, plannerID: plannerID, from: from, to: to)
            report.blocksWritten = written
            report.blocksRemoved = removed
            try cache.saveLedger(ledger)
        }

        let state = try await api.state()
        try? cache.saveState(state)
        report.state = state
        return report
    }

    /// Blocks the user moved or deleted in the Planner calendar since the last sync.
    func blockChanges() -> [BlockChange] {
        ledger.entries.sorted { $0.key < $1.key }.compactMap { blockID, entry in
            guard let device = calendar.event(withIdentifier: entry.deviceID) else {
                return .deleted(id: blockID)
            }
            if !sameTime(device.start, entry.start) || !sameTime(device.end, entry.end) {
                return .moved(id: blockID, startAt: device.start, endAt: device.end)
            }
            return nil
        }
    }

    /// Makes the Planner calendar match the server's blocks for [from, to).
    private func applyBlocks(_ blocks: [CalEvent], plannerID: String, from: Date, to: Date) throws -> (written: Int, removed: Int) {
        var written = 0
        var removed = 0
        let returned = Set(blocks.map(\.id))

        for block in blocks {
            let entry = ledger.entries[block.id]
            let existing = entry.flatMap { calendar.event(withIdentifier: $0.deviceID) }
            if let existing, existing.calendarID == plannerID, existing.title == block.title, existing.allDay == block.allDay,
               sameTime(existing.start, block.startAt), sameTime(existing.end, block.endAt) {
                ledger.entries[block.id] = .init(deviceID: existing.identifier, start: block.startAt, end: block.endAt)
                continue
            }
            let deviceID = try calendar.saveBlock(
                identifier: existing?.identifier,
                title: block.title,
                notes: block.isTaskBlock ? "Booked by Planner." : block.notes,
                start: block.startAt,
                end: block.endAt,
                allDay: block.allDay,
                in: plannerID
            )
            ledger.entries[block.id] = .init(deviceID: deviceID, start: block.startAt, end: block.endAt)
            written += 1
        }

        // Blocks in the window the server no longer has: deleted in Planner, or
        // by an agent, or their task was finished early.
        for (blockID, entry) in ledger.entries where !returned.contains(blockID) && entry.start < to && entry.end > from {
            try calendar.removeEvent(withIdentifier: entry.deviceID)
            ledger.entries[blockID] = nil
            removed += 1
        }
        // Forget blocks that have scrolled out of the past end of the window.
        ledger.entries = ledger.entries.filter { $0.value.end > from }
        return (written, removed)
    }

    private func sameTime(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) < 1
    }
}

extension MirroredEvent {
    init(_ event: DeviceEvent) {
        let notes = event.notes.map { String($0.prefix(5000)) }
        self.init(
            externalId: String(event.occurrenceID.prefix(500)),
            title: String(event.title.prefix(500)),
            notes: notes?.isEmpty == true ? nil : notes,
            startAt: event.start,
            endAt: event.end,
            allDay: event.allDay
        )
    }
}
