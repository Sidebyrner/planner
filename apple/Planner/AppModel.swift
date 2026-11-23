import Foundation
import Observation
import PlannerKit

/// Everything the views show and do. Talks to the server through PlannerKit.
@Observable
@MainActor
final class AppModel {
    private enum Keys {
        static let server = "serverURL"
        static let busyCalendars = "busyCalendarIDs"
        static let tokenAccount = "deviceToken"
        static let calendarBridge = "isCalendarBridge"
        static let reminders = "remindersEnabled"
    }

    /// Local notifications at block start and follow-up time.
    var remindersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remindersEnabled, forKey: Keys.reminders)
            Task { await refreshReminders(requestPermission: remindersEnabled) }
        }
    }

    /// The Mac is the bridge by default; the iPhone uses the server only.
    #if os(macOS)
    private static let bridgeByDefault = true
    #else
    private static let bridgeByDefault = false
    #endif

    /// Whether this device mirrors busy time and writes the Planner calendar. See SyncEngine.Options.
    var isCalendarBridge: Bool {
        didSet {
            UserDefaults.standard.set(isCalendarBridge, forKey: Keys.calendarBridge)
            rebuildEngine()
        }
    }

    // MARK: Configuration

    var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: Keys.server)
            rebuildEngine()
        }
    }

    var token: String {
        didSet {
            Keychain.write(token.isEmpty ? nil : token, account: Keys.tokenAccount)
            rebuildEngine()
        }
    }

    /// Calendars that count as busy time. nil = all of them (except Planner's own).
    var busyCalendarIDs: Set<String>? {
        didSet {
            UserDefaults.standard.set(busyCalendarIDs.map { Array($0) }, forKey: Keys.busyCalendars)
            rebuildEngine()
        }
    }

    var isConfigured: Bool { engine != nil }

    // MARK: What the UI shows

    private(set) var state: AppState?
    var proposal: ScheduleProposal?
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    /// Why the last sync failed; the UI keeps showing the saved state.
    private(set) var syncError: String?
    /// A user action that failed. Shown as an alert.
    var actionError: String?
    private(set) var rejectedMoves: [DeviceSyncResult.Rejection] = []
    private(set) var calendarAccess = false
    private(set) var calendars: [CalendarInfo] = []
    private(set) var plannerCalendarID: String?

    // MARK: Plumbing

    let calendarStore: CalendarStore
    private let cache: PlannerCache
    private var engine: SyncEngine?
    private var started = false

    init(calendarStore: CalendarStore? = nil, cache: PlannerCache? = nil) {
        self.calendarStore = calendarStore ?? EventKitCalendarStore()
        self.cache = cache
            ?? (try? PlannerCache.standard())
            ?? PlannerCache(directory: FileManager.default.temporaryDirectory.appending(path: "Planner"))
        self.serverURL = UserDefaults.standard.string(forKey: Keys.server) ?? ""
        self.token = Keychain.read(account: Keys.tokenAccount) ?? ""
        self.busyCalendarIDs = (UserDefaults.standard.array(forKey: Keys.busyCalendars) as? [String]).map(Set.init)
        self.isCalendarBridge = UserDefaults.standard.object(forKey: Keys.calendarBridge) as? Bool ?? Self.bridgeByDefault
        self.remindersEnabled = UserDefaults.standard.bool(forKey: Keys.reminders)
        rebuildEngine()
        state = self.cache.loadState()
        refreshCalendarInfo()
    }

    private func rebuildEngine() {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil,
              !token.isEmpty
        else {
            engine = nil
            return
        }
        engine = SyncEngine(
            api: PlannerAPI(baseURL: url, token: token),
            calendar: calendarStore,
            cache: cache,
            options: .init(isCalendarBridge: isCalendarBridge, busyCalendarIDs: busyCalendarIDs)
        )
    }

    private func refreshCalendarInfo() {
        calendarAccess = calendarStore.hasAccess
        calendars = calendarAccess ? calendarStore.calendars() : []
        plannerCalendarID = calendarAccess ? (try? calendarStore.plannerCalendarID(create: false)) ?? nil : nil
    }

    // MARK: Sync

    func start() async {
        if !started {
            started = true
            if calendarStore is EventKitCalendarStore, isCalendarBridge, !calendarStore.hasAccess, isConfigured {
                _ = try? await calendarStore.requestAccess()
            }
        }
        await sync()
    }

    func sync() async {
        guard let engine else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let report = try await engine.sync()
            if let state = report.state { self.state = state }
            rejectedMoves = report.rejected
            lastSyncAt = Date()
            await refreshReminders(requestPermission: false)
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
        refreshCalendarInfo()
    }

    /// Apple Calendar changed. Our own writes also land here, so skip the echo
    /// that arrives right after a sync.
    func calendarChanged() {
        guard !isSyncing, Date().timeIntervalSince(lastSyncAt ?? .distantPast) > 5 else { return }
        Task { await sync() }
    }

    func requestCalendarAccess() async {
        do {
            _ = try await calendarStore.requestAccess()
        } catch {
            actionError = error.localizedDescription
        }
        refreshCalendarInfo()
        await sync()
    }

    func testConnection() async -> String {
        guard let api = engine?.api else { return "Add the server address and device token first." }
        do {
            guard try await api.health() else { return "The server answered but is not healthy." }
            let state = try await api.state()
            return "Connected. \(state.tasks.filter { !$0.isDone }.count) open tasks."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Actions

    /// Runs `work` against the server, then syncs so the calendar follows.
    @discardableResult
    private func perform(_ work: (PlannerAPI) async throws -> Void) async -> Bool {
        guard let api = engine?.api else {
            actionError = "Add the server address and device token in Settings."
            return false
        }
        do {
            try await work(api)
            await sync()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func preview(_ text: String) async -> Captured? {
        try? await engine?.api.previewCapture(text)
    }

    func capture(_ text: String) async -> Bool {
        await perform { _ = try await $0.capture(text) }
    }

    func toggleDone(_ task: PlannerTask) async {
        await perform { _ = try await $0.updateTask(id: task.id, TaskPatch(status: task.isDone ? .todo : .done)) }
    }

    func delete(_ task: PlannerTask) async {
        await perform { try await $0.deleteTask(id: task.id) }
    }

    func removeBlock(_ event: CalEvent) async {
        await perform { try await $0.deleteEvent(id: event.id) }
    }

    func plan() async {
        guard let api = engine?.api else { return }
        do {
            let proposal = try await api.proposeSchedule()
            if proposal.blocks.isEmpty {
                self.proposal = nil
                actionError = proposal.unscheduled.isEmpty
                    ? "Nothing to plan: every open task already has time booked."
                    : "No free time left in the planning window for: \(proposal.unscheduled.map(\.title).joined(separator: ", "))."
            } else {
                self.proposal = proposal
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func book(_ blocks: [ProposedBlock]) async {
        guard !blocks.isEmpty else { return }
        let ids = Set(blocks.map(\.id))
        if await perform({ _ = try await $0.applySchedule(blocks.map(BlockBooking.init)) }) {
            discard(where: { ids.contains($0.id) })
        }
    }

    func discard(_ block: ProposedBlock) {
        discard(where: { $0.id == block.id })
    }

    func discardProposal() {
        proposal = nil
    }

    private func discard(where shouldRemove: (ProposedBlock) -> Bool) {
        proposal?.blocks.removeAll(where: shouldRemove)
        if proposal?.blocks.isEmpty == true { proposal = nil }
    }

    func saveSettings(_ patch: SettingsPatch) async {
        await perform { _ = try await $0.updateSettings(patch) }
    }

    // MARK: Derived

    var openTasks: [PlannerTask] {
        (state?.tasks ?? []).filter { !$0.isDone }.sorted { a, b in
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.priority != b.priority ? a.priority > b.priority : a.createdAt < b.createdAt
            }
        }
    }

    var doneTasks: [PlannerTask] {
        (state?.tasks ?? []).filter(\.isDone).sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    func nextBlock(for task: PlannerTask) -> CalEvent? {
        let now = Date()
        return state?.events.filter { $0.taskId == task.id && $0.endAt > now }.min { $0.startAt < $1.startAt }
    }

    func task(id: String?) -> PlannerTask? {
        guard let id else { return nil }
        return state?.tasks.first { $0.id == id }
    }

    // MARK: Projects

    var projects: [Project] { (state?.projects ?? []).sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) } }
    var liveProjects: [Project] { projects.filter { !$0.archived } }

    func project(id: String?) -> Project? {
        guard let id else { return nil }
        return state?.projects.first { $0.id == id }
    }

    @discardableResult
    func saveProject(id: String?, _ patch: ProjectPatch) async -> Bool {
        await perform { api in
            if let id { _ = try await api.updateProject(id: id, patch) } else { _ = try await api.createProject(patch) }
        }
    }

    func removeProject(_ project: Project) async {
        await perform { _ = try await $0.removeProject(id: project.id) }
    }

    // MARK: Task edits

    @discardableResult
    func update(_ task: PlannerTask, _ patch: TaskPatch) async -> Bool {
        await perform { _ = try await $0.updateTask(id: task.id, patch) }
    }

    func toggleStep(_ item: ChecklistItem, of task: PlannerTask) async {
        let checklist = task.checklist.map { $0.id == item.id ? ChecklistItem(id: $0.id, text: $0.text, done: !$0.done) : $0 }
        await update(task, TaskPatch(checklist: checklist))
    }

    /// Move a Planner event or block to a new start, keeping its length.
    func move(_ event: CalEvent, to start: Date) async {
        guard !event.isReadOnly else { return }
        let length = event.endAt.timeIntervalSince(event.startAt)
        await perform { _ = try await $0.updateEvent(id: event.id, EventPatch(startAt: start, endAt: start.addingTimeInterval(length))) }
    }

    var waitingTasks: [PlannerTask] {
        (state?.tasks ?? []).filter(\.isWaiting).sorted { ($0.followUpAt ?? .distantFuture) < ($1.followUpAt ?? .distantFuture) }
    }

    func tasks(for event: CalEvent) -> [PlannerTask] {
        event.allTaskIds.compactMap { task(id: $0) }
    }

    // MARK: Today

    /// Today's timed events and blocks, in order.
    var todayEvents: [CalEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (state?.events ?? []).filter { !$0.allDay && $0.startAt < end && $0.endAt > start }.sorted { $0.startAt < $1.startAt }
    }

    var currentEvent: CalEvent? {
        let now = Date()
        return todayEvents.last { $0.startAt <= now && $0.endAt > now }
    }

    var nextEvent: CalEvent? {
        let now = Date()
        return todayEvents.first { $0.startAt > now } ?? (state?.events ?? []).filter { !$0.allDay && $0.startAt > now }.min { $0.startAt < $1.startAt }
    }

    var dueToday: [PlannerTask] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return openTasks.filter { ($0.dueAt ?? .distantFuture) < end }
    }

    var followUpsDue: [PlannerTask] { openTasks.filter { $0.waitingOn != nil } }

    // MARK: Reminders

    func refreshReminders(requestPermission: Bool) async {
        guard remindersEnabled, let state else {
            await Reminders.clear()
            return
        }
        if requestPermission, !(await Reminders.requestPermission()) {
            actionError = "Notifications are turned off for Planner. Allow them in System Settings to get reminders."
            return
        }
        await Reminders.schedule(events: state.events, tasks: state.tasks, projects: state.projects)
    }
}
