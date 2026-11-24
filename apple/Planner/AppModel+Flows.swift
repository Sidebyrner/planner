import Foundation
import PlannerKit

/// What the redesigned Today screen, the guided workflows and the task board read and do.
extension AppModel {
    // MARK: Blocks

    /// Record how a task block went. Missed work comes back with fresh time proposed.
    @discardableResult
    func mark(_ block: CalEvent, _ outcome: BlockOutcome) async -> BlockMarkResult? {
        var result: BlockMarkResult?
        await perform { result = try await $0.markBlock(id: block.id, outcome) }
        return result
    }

    /// Task blocks that have ended in the last `days` days, still have open work and nobody has marked.
    func blocksToReview(days: Int = 2, now: Date = Date()) -> [CalEvent] {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        return (state?.events ?? [])
            .filter { $0.isTaskBlock && $0.outcome == nil && $0.endAt <= now && $0.endAt > from }
            .filter { tasks(for: $0).contains { $0.status == .todo } }
            .sorted { $0.startAt < $1.startAt }
    }

    /// Task blocks on `day`, in order.
    func blocks(on day: Date) -> [CalEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (state?.events ?? []).filter { $0.isTaskBlock && $0.startAt < end && $0.endAt > start }.sorted { $0.startAt < $1.startAt }
    }

    // MARK: Planning

    /// Blocks for these tasks only, without booking anything.
    func propose(taskIds: [String]) async -> ScheduleProposal? {
        guard let api = engine?.api else { return nil }
        do {
            return try await api.proposeSchedule(taskIds: taskIds)
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    /// Books the first slot the scheduler finds for `task`.
    @discardableResult
    func scheduleNextFree(_ task: PlannerTask) async -> Bool {
        guard let proposal = await propose(taskIds: [task.id]), let first = proposal.blocks.first else {
            actionError = "No free time left in the planning window for \(task.title)."
            return false
        }
        return await perform { _ = try await $0.applySchedule([BlockBooking(first)]) }
    }

    @discardableResult
    func createTask(_ draft: TaskDraft) async -> PlannerTask? {
        var created: PlannerTask?
        await perform { created = try await $0.createTask(draft) }
        return created
    }

    /// Make the block you're in run longer.
    func extend(_ block: CalEvent, minutes: Int) async {
        guard !block.isReadOnly else { return }
        await perform { _ = try await $0.updateEvent(id: block.id, EventPatch(endAt: block.endAt.addingTimeInterval(Double(minutes) * 60))) }
    }

    /// The first unchecked step across a block's tasks: "Step 2 of 5: tape the trim".
    func nextStep(in block: CalEvent) -> (task: PlannerTask, item: ChecklistItem, number: Int, of: Int)? {
        for task in tasks(for: block) where !task.isDone {
            if let i = task.checklist.firstIndex(where: { !$0.done }) {
                return (task, task.checklist[i], i + 1, task.checklist.count)
            }
        }
        return nil
    }

    /// Open tasks that are best done first: overdue or due soonest, then high priority.
    var topCandidates: [PlannerTask] {
        openTasks.sorted { a, b in
            let da = a.dueAt ?? .distantFuture, db = b.dueAt ?? .distantFuture
            if da != db { return da < db }
            return a.priority > b.priority
        }
    }

    /// Open tasks due before the end of `day` that aren't finished.
    func due(by day: Date) -> [PlannerTask] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day)) ?? day
        return openTasks.filter { ($0.dueAt ?? .distantFuture) < end }
    }

    /// Move a task's due date to the same time on another day (default: tomorrow).
    func pushDue(_ task: PlannerTask, days: Int = 1) async {
        let base = max(task.dueAt ?? Date(), Calendar.current.startOfDay(for: Date()))
        let next = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
        await update(task, TaskPatch(dueAt: .some(next)))
    }

    // MARK: Today: chores and bills

    /// Repeating tasks due by the end of today (chores, bills), overdue first.
    var choresDue: [PlannerTask] {
        due(by: Date()).filter(\.repeats).sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    /// Everything else due by the end of today.
    var otherDueToday: [PlannerTask] {
        due(by: Date()).filter { !$0.repeats && $0.waitingOn == nil }
    }

    // MARK: Today: the window you're in

    /// The free stretch you're in, or the stretch of a project's own time (your shift).
    struct Window {
        enum Kind { case free, hosted(Project) }
        var kind: Kind
        var start: Date
        var end: Date
        /// What it runs up to ("Mr J's shift"), when there is something.
        var until: CalEvent?
        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    }

    /// A project whose time this event is (its hostMatch is in the title), like the shift for Mr J's.
    func hostProject(for event: CalEvent) -> Project? {
        guard !event.isTaskBlock else { return nil }
        let title = event.title.lowercased()
        return liveProjects.first { p in
            guard let match = p.hostMatch?.trimmingCharacters(in: .whitespaces).lowercased(), !match.isEmpty else { return false }
            return title.contains(match)
        }
    }

    /// Where you are right now: inside a project's own time, or free until the next thing.
    func currentWindow(now: Date = Date()) -> Window? {
        let events = todayEvents.filter { !$0.ignored }
        if let current = events.last(where: { $0.startAt <= now && $0.endAt > now }) {
            if let project = hostProject(for: current) {
                return Window(kind: .hosted(project), start: now, end: current.endAt, until: current)
            }
            return nil
        }
        let next = events.first { $0.startAt > now }
        let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
        let end = min(next?.startAt ?? endOfDay, endOfDay)
        guard end.timeIntervalSince(now) >= 10 * 60 else { return nil }
        return Window(kind: .free, start: now, end: end, until: next)
    }

    /// Open tasks that fit in `minutes`, optionally only one project's, most urgent first.
    func fits(minutes: Int, projectId: String? = nil, limit: Int = 3) -> [PlannerTask] {
        openTasks
            .filter { projectId == nil || $0.projectId == projectId }
            .map { ($0, remainingMinutes($0)) }
            .filter { $0.1 > 0 && $0.1 <= minutes }
            .sorted { a, b in
                let da = a.0.dueAt ?? .distantFuture, db = b.0.dueAt ?? .distantFuture
                return da != db ? da < db : a.0.priority > b.0.priority
            }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: Follow-ups by person

    struct Person: Identifiable {
        var name: String
        var contact: Contact?
        /// Past their follow-up date: chase now.
        var due: [PlannerTask]
        /// Still waiting, follow-up later.
        var pending: [PlannerTask]
        var id: String { name.lowercased() }
        /// Emailed back on any of these.
        var hasReply: Bool { due.contains(where: \.hasReply) }
    }

    var people: [Person] {
        var byName: [String: Person] = [:]
        let now = Date()
        for task in state?.tasks ?? [] where !task.isDone {
            guard let who = task.waitingOn?.trimmingCharacters(in: .whitespaces), !who.isEmpty else { continue }
            var person = byName[who.lowercased()] ?? Person(name: who, contact: nil, due: [], pending: [])
            person.contact = person.contact ?? task.contact
            // A reply needs a look now, whatever the follow-up date says.
            let isDue = task.hasReply || task.status == .todo || (task.followUpAt.map { $0 <= now } ?? false)
            if isDue { person.due.append(task) } else { person.pending.append(task) }
            byName[who.lowercased()] = person
        }
        return byName.values.map { p in
            var p = p
            p.due.sort { ($0.hasReply ? 0 : 1) < ($1.hasReply ? 0 : 1) }
            return p
        }.sorted { a, b in
            if a.hasReply != b.hasReply { return a.hasReply }
            return a.due.count != b.due.count ? a.due.count > b.due.count : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Chased them: keep waiting and come back in `days` days at 9:00.
    func snooze(_ task: PlannerTask, days: Int) async {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: Date())) ?? Date()
        let at = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        await update(task, TaskPatch(status: .waiting, followUpAt: .some(at)))
    }

    /// They came through: the follow-up is finished.
    func gotIt(_ task: PlannerTask) async {
        await update(task, TaskPatch(status: .done))
    }

    // MARK: Board

    enum BoardColumn: String, CaseIterable, Identifiable {
        case todo = "To do", scheduled = "Scheduled", waiting = "Waiting", done = "Done"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .todo: "circle"
            case .scheduled: "calendar"
            case .waiting: "hourglass"
            case .done: "checkmark.circle.fill"
            }
        }
    }

    func column(for task: PlannerTask) -> BoardColumn {
        switch task.status {
        case .done: .done
        case .waiting: .waiting
        case .todo: nextBlock(for: task) != nil ? .scheduled : .todo
        }
    }

    /// Tasks in a column. Done shows the last week; upcoming repeats stay hidden.
    func board(_ column: BoardColumn, projectId: String? = nil) -> [PlannerTask] {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let all = (state?.tasks ?? []).filter { !$0.isUpcoming() && (projectId == nil || $0.projectId == projectId) }
        switch column {
        case .done:
            return all.filter { $0.isDone && ($0.completedAt ?? $0.createdAt) > weekAgo }
                .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        case .waiting:
            return all.filter(\.isWaiting).sorted { ($0.followUpAt ?? .distantFuture) < ($1.followUpAt ?? .distantFuture) }
        case .todo, .scheduled:
            return topCandidates.filter { (projectId == nil || $0.projectId == projectId) && self.column(for: $0) == column }
        }
    }

    /// Drop a task in another column. Waiting needs someone to wait on.
    func move(_ task: PlannerTask, to column: BoardColumn, waitingOn: String? = nil) async {
        guard column != self.column(for: task) else { return }
        switch column {
        case .done:
            await update(task, TaskPatch(status: .done))
        case .waiting:
            let who = (waitingOn ?? task.waitingOn ?? "").trimmingCharacters(in: .whitespaces)
            guard !who.isEmpty else { return }
            await update(task, TaskPatch(status: .waiting, waitingOn: .some(who)))
        case .todo:
            if task.status != .todo {
                await update(task, TaskPatch(status: .todo))
            } else if let block = nextBlock(for: task), !block.isBatch {
                await removeBlock(block)
            }
        case .scheduled:
            if task.status != .todo { await update(task, TaskPatch(status: .todo)) }
            await scheduleNextFree(task)
        }
    }

    // MARK: Week

    /// Tasks finished since Monday, by project.
    func finishedThisWeek(now: Date = Date()) -> [(project: Project?, tasks: [PlannerTask])] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let done = (state?.tasks ?? []).filter { $0.isDone && ($0.completedAt ?? .distantPast) >= weekStart }
        let groups = Dictionary(grouping: done) { $0.projectId ?? "" }
        return groups.map { (project(id: $0.key.isEmpty ? nil : $0.key), $0.value) }
            .sorted { $0.tasks.count > $1.tasks.count }
    }

    var overdue: [PlannerTask] {
        let now = Date()
        return openTasks.filter { ($0.dueAt ?? .distantFuture) < now }
    }

    // MARK: Projects

    /// How a project is doing, for its card and its page. `nil` project means unfiled tasks.
    struct ProjectSummary {
        var overdue: [PlannerTask]
        var scheduled: [PlannerTask]
        /// Open, not overdue, with nothing booked.
        var unscheduled: [PlannerTask]
        var waiting: [PlannerTask]
        var doneThisWeek: [PlannerTask]
        var dueThisWeek: Int
        /// Estimated minutes not yet covered by a block.
        var minutesLeft: Int

        var open: Int { overdue.count + scheduled.count + unscheduled.count }
        /// Scheduled first, then the most urgent unscheduled task.
        var nextUp: PlannerTask? { overdue.first ?? scheduled.first ?? unscheduled.first }
        var needsAttention: Bool { !overdue.isEmpty || (scheduled.isEmpty && !unscheduled.isEmpty) }
        /// Share of this week's work that's done (finished this week vs still open).
        var progress: Double {
            let total = doneThisWeek.count + open
            return total == 0 ? 0 : Double(doneThisWeek.count) / Double(total)
        }
    }

    func summary(for project: Project?, now: Date = Date()) -> ProjectSummary {
        let id = project?.id
        let mine = topCandidates.filter { $0.projectId == id }
        let overdue = mine.filter { ($0.dueAt ?? .distantFuture) < now }
        let rest = mine.filter { ($0.dueAt ?? .distantFuture) >= now }
        let scheduled = rest.filter { nextBlock(for: $0) != nil }
            .sorted { (nextBlock(for: $0)?.startAt ?? .distantFuture) < (nextBlock(for: $1)?.startAt ?? .distantFuture) }
        let unscheduled = rest.filter { nextBlock(for: $0) == nil }
        let weekEnd = now.addingTimeInterval(7 * 86_400)
        return ProjectSummary(
            overdue: overdue,
            scheduled: scheduled,
            unscheduled: unscheduled,
            waiting: waitingTasks.filter { $0.projectId == id },
            doneThisWeek: finishedThisWeek(now: now).first { $0.project?.id == id }?.tasks ?? [],
            dueThisWeek: rest.filter { ($0.dueAt ?? .distantFuture) < weekEnd }.count,
            minutesLeft: mine.reduce(0) { $0 + remainingMinutes($1, now: now) }
        )
    }

    /// Projects with something wrong (overdue, or work with nothing booked) first.
    var projectsByAttention: [(project: Project, summary: ProjectSummary)] {
        let all = liveProjects.map { ($0, summary(for: $0)) }
        return all.filter { $0.1.needsAttention } + all.filter { !$0.1.needsAttention }
    }
}
