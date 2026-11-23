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
            SharedCredentials.serverURL = serverURL
            rebuildEngine()
        }
    }

    var token: String {
        didSet {
            SharedCredentials.token = token
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
        var storedToken = SharedCredentials.token ?? ""
        // Keep the shared copy of the address current for Siri and the widget.
        if let saved = UserDefaults.standard.string(forKey: Keys.server), SharedCredentials.serverURL != saved {
            SharedCredentials.serverURL = saved
        }
        #if DEBUG
        // Simulator screenshots: an unsigned build can't read the Keychain item saved by a signed one,
        // so allow the token from the launch environment. Compiled out of release builds.
        if storedToken.isEmpty, let injected = ProcessInfo.processInfo.environment["PLANNER_DEVICE_TOKEN"], !injected.isEmpty {
            storedToken = injected
        }
        #endif
        self.token = storedToken
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
            // A server nobody has confirmed a time zone on plans in UTC. Adopt this device's,
            // the same way the web app does on first visit.
            if let settings = report.state?.settings, !settings.timezoneConfirmed {
                _ = try? await engine.api.updateSettings(SettingsPatch(timezone: TimeZone.current.identifier, timezoneConfirmed: true))
                if let fresh = try? await engine.api.state() { self.state = fresh }
            }
            rejectedMoves = report.rejected
            lastSyncAt = Date()
            await refreshReminders(requestPermission: false)
            syncError = nil
            suggestedServer = nil
        } catch PlannerAPIError.notPlanner {
            syncError = PlannerAPIError.notPlanner.localizedDescription
            if suggestedServer == nil { suggestedServer = await alternativeServer() }
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
        // Waiting tasks have their own list. A repeating task in its lead time (a bill not due
        // for weeks) stays out of sight.
        (state?.tasks ?? []).filter { $0.status == .todo && !$0.isUpcoming() }.sorted { a, b in
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

    // MARK: Connection

    /// Set when the saved address answers but isn't the Planner app and the :8443 address is.
    private(set) var suggestedServer: String?

    var serverHost: String? {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host()
    }

    func useSuggestedServer() {
        guard let suggestion = suggestedServer else { return }
        serverURL = suggestion
        suggestedServer = nil
        Task { await sync() }
    }

    /// Checks the address and token, fixing a missing :8443 on the way. Returns a problem to show, or nil.
    func connect() async -> String? {
        guard let api = engine?.api else { return "Enter an https:// address and the device token." }
        do {
            guard try await api.health() else { return "The server answered but isn't healthy." }
            _ = try await api.state()
        } catch PlannerAPIError.notPlanner {
            if let fixed = await alternativeServer() {
                serverURL = fixed
                suggestedServer = nil
                return await connect()
            }
            return PlannerAPIError.notPlanner.localizedDescription
        } catch {
            return error.localizedDescription
        }
        await start()
        return nil
    }

    /// With Tailscale Funnel, :443 serves only /mcp and the app is on :8443. Try that.
    private func alternativeServer() async -> String? {
        guard var parts = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)), parts.port == nil else { return nil }
        parts.port = 8443
        parts.path = ""
        guard let url = parts.url else { return nil }
        let probe = PlannerAPI(baseURL: url, token: token)
        return (try? await probe.health()) == true ? url.absoluteString : nil
    }

    // MARK: Projects

    /// The project an event belongs to: its own, or for a mirrored event the project whose
    /// host text it contains or whose name it starts with ("Mr J's shift" → Mr J's).
    func projectFor(_ event: CalEvent) -> Project? {
        if let p = project(id: event.projectId) { return p }
        guard event.source != .local else { return nil }
        let title = event.title.lowercased()
        return liveProjects.first { p in
            if let match = p.hostMatch?.lowercased(), !match.isEmpty, title.contains(match) { return true }
            return title.hasPrefix(p.name.lowercased())
        }
    }

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

    // MARK: Today: gaps, quick add, swipe actions

    struct Gap: Identifiable, Hashable {
        let start: Date
        let end: Date
        var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
        var id: Date { start }
    }

    /// Free stretches of at least `minMinutes` between now and the end of today's waking hours
    /// (07:00 to the later of 22:00 and your working-hours end). All-day events don't count.
    func todayGaps(minMinutes: Int = 30, now: Date = Date()) -> [Gap] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let workEndHour = state?.settings.workEnd.split(separator: ":").first.flatMap { Int($0) } ?? 17
        let windowStart = max(now, calendar.date(bySettingHour: 7, minute: 0, second: 0, of: dayStart) ?? now)
        let windowEnd = calendar.date(bySettingHour: min(max(22, workEndHour), 23), minute: 59, second: 0, of: dayStart) ?? now
        guard windowEnd > windowStart else { return [] }

        // Round the first gap up to the next 5 minutes so "now" isn't 4:47.
        let snap = 5 * 60.0
        var cursor = Date(timeIntervalSinceReferenceDate: (windowStart.timeIntervalSinceReferenceDate / snap).rounded(.up) * snap)
        var gaps: [Gap] = []
        let busy = (state?.events ?? []).filter { !$0.allDay && $0.endAt > cursor && $0.startAt < windowEnd }.sorted { $0.startAt < $1.startAt }
        for event in busy {
            if event.startAt > cursor { gaps.append(Gap(start: cursor, end: min(event.startAt, windowEnd))) }
            cursor = max(cursor, event.endAt)
        }
        if cursor < windowEnd { gaps.append(Gap(start: cursor, end: windowEnd)) }
        return gaps.filter { $0.minutes >= minMinutes }
    }

    /// Minutes of a task not yet covered by a future block (a Quick block covers its tasks entirely).
    func remainingMinutes(_ task: PlannerTask, now: Date = Date()) -> Int {
        let future = (state?.events ?? []).filter { $0.endAt > now }
        if future.contains(where: { $0.taskIds.contains(task.id) }) { return 0 }
        let booked = future.filter { $0.taskId == task.id }.reduce(0.0) { $0 + $1.endAt.timeIntervalSince(max($1.startAt, now)) / 60 }
        return max(0, task.estimateMin - Int(booked))
    }

    /// Open tasks that fit in a gap, most urgent first.
    func suggestions(for gap: Gap, limit: Int = 2) -> [PlannerTask] {
        openTasks
            .map { ($0, remainingMinutes($0)) }
            .filter { $0.1 > 0 && $0.1 <= gap.minutes }
            .sorted { a, b in
                let da = a.0.dueAt ?? .distantFuture, db = b.0.dueAt ?? .distantFuture
                return da != db ? da < db : a.0.priority > b.0.priority
            }
            .prefix(limit)
            .map(\.0)
    }

    /// Books a block for an existing task.
    @discardableResult
    func book(_ task: PlannerTask, at start: Date, minutes: Int) async -> Bool {
        await perform { _ = try await $0.applySchedule([BlockBooking(taskId: task.id, startAt: start, endAt: start.addingTimeInterval(Double(minutes) * 60))]) }
    }

    /// New task with its block in one go.
    @discardableResult
    func addTaskBlock(title: String, projectId: String?, at start: Date, minutes: Int) async -> Bool {
        await perform { api in
            let task = try await api.createTask(TaskDraft(title: title, estimateMin: max(5, minutes), projectId: projectId))
            _ = try await api.applySchedule([BlockBooking(taskId: task.id, startAt: start, endAt: start.addingTimeInterval(Double(minutes) * 60))])
        }
    }

    @discardableResult
    func addEvent(title: String, projectId: String?, at start: Date, minutes: Int) async -> Bool {
        await perform { _ = try await $0.createEvent(EventDraft(title: title, startAt: start, endAt: start.addingTimeInterval(Double(minutes) * 60), projectId: projectId)) }
    }

    func push(_ event: CalEvent, minutes: Int) async {
        await move(event, to: event.startAt.addingTimeInterval(Double(minutes) * 60))
    }

    func moveToTomorrow(_ event: CalEvent) async {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: event.startAt) else { return }
        await move(event, to: tomorrow)
    }

    /// Marks every task in a block done (which also gives back their remaining time).
    func completeTasks(in event: CalEvent) async {
        let ids = event.allTaskIds
        await perform { api in
            for id in ids { _ = try await api.updateTask(id: id, TaskPatch(status: .done)) }
        }
    }

    // MARK: Plan the rest of today

    /// Proposed blocks that start before midnight, shown inline on Today.
    var todayProposal: [ProposedBlock] = []

    func planRestOfToday() async {
        guard let api = engine?.api else { return }
        do {
            let proposal = try await api.proposeSchedule()
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            todayProposal = proposal.blocks.filter { $0.startAt < end }
            if todayProposal.isEmpty {
                actionError = proposal.blocks.isEmpty
                    ? "Nothing to plan: every open task already has time booked."
                    : "No free working time left today. The next slot Planner found is \(Format.relative(proposal.blocks[0].startAt))."
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func bookToday(_ blocks: [ProposedBlock]) async {
        let ids = Set(blocks.map(\.id))
        if await perform({ _ = try await $0.applySchedule(blocks.map(BlockBooking.init)) }) {
            todayProposal.removeAll { ids.contains($0.id) }
        }
    }

    func skipToday(_ block: ProposedBlock) {
        todayProposal.removeAll { $0.id == block.id }
    }

    // MARK: Voice

    /// Saves a spoken (or typed) line and returns what was created, for the confirmation and Undo.
    func captureForVoice(_ text: String) async -> CaptureResult? {
        guard let api = engine?.api else {
            actionError = "Connect Planner to your server first."
            return nil
        }
        do {
            let result = try await api.capture(text)
            await sync()
            return result
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func undo(_ result: CaptureResult) async {
        await perform { api in
            if let task = result.task { try await api.deleteTask(id: task.id) }
            if let event = result.event { try await api.deleteEvent(id: event.id) }
            // A #tag that created a project just now: remove it again (it has no other tasks yet).
            if let project = result.project { _ = try? await api.removeProject(id: project.id) }
        }
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
