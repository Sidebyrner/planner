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
            options: .init(busyCalendarIDs: busyCalendarIDs)
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
            if calendarStore is EventKitCalendarStore, !calendarStore.hasAccess, isConfigured {
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
}
