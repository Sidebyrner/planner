import PlannerKit
import SwiftUI

/// Which tasks the list shows.
enum TaskFilter: Hashable {
    case all
    case none
    case project(String)
}

struct TaskListView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @AppStorage("tasks.mode") private var mode = TasksMode.list
    @State private var scope: TaskScope = .all
    @State private var filter: TaskFilter = .all
    @State private var openTask: PlannerTask?
    @State private var pickingProject = false
    @State private var showDone = false
    /// What's typed in the bottom bar: it filters the list and becomes a task on return.
    @State private var text = ""
    @FocusState private var searching: Bool
    @State private var justBooked: Booked?

    struct Booked: Equatable {
        let taskId: String
        let title: String
        let at: Date?
    }

    private func inProject(_ task: PlannerTask) -> Bool {
        switch filter {
        case .all: true
        case .none: task.projectId == nil
        case .project(let id): task.projectId == id
        }
    }

    /// The words to search for: what's typed, minus #project and @person tags.
    private var searchWords: [String] {
        text.lowercased().split(separator: " ").map(String.init).filter { !$0.hasPrefix("#") && !$0.hasPrefix("@") }
    }

    private func found(_ task: PlannerTask) -> Bool {
        let words = searchWords
        guard !words.isEmpty else { return true }
        let haystack = (task.title + " " + task.notes + " " + (task.waitingOn ?? "") + " " + task.checklist.map(\.text).joined(separator: " ")).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    private func inScope(_ task: PlannerTask, _ scope: TaskScope) -> Bool {
        switch scope {
        case .all: true
        case .today: [.overdue, .today].contains(model.group(for: task))
        case .unbooked: !task.isWaiting && task.waitingOn == nil && model.nextBlock(for: task) == nil
        case .waiting: task.waitingOn != nil
        }
    }

    var body: some View {
        let base = (model.openTasks + model.waitingTasks).filter { inProject($0) && found($0) }
        let counts = Dictionary(uniqueKeysWithValues: TaskScope.allCases.map { s in (s, base.filter { inScope($0, s) }.count) })
        let visible = base.filter { inScope($0, scope) }

        Group {
            if mode == .board {
                VStack(spacing: 0) {
                    header(counts: counts).padding(.horizontal, 16).padding(.top, 4)
                    BoardView(projectId: filter.projectId, embedded: true)
                        .id(filter)
                }
                .background(Color.pageBackground)
            } else {
                list(visible: visible, counts: counts)
            }
        }
        .navigationTitle("Tasks")
        // Room for the floating bar, so the last rows can scroll clear of it.
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 66) }
        // Drawn on top of the list (an inset alone let taps fall through to the rows below).
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let justBooked { bookedToast(justBooked) }
                TaskSearchBar(text: $text, focused: $searching, matches: visible.count)
            }
        }
        .animation(.planner, value: justBooked)
        .sheet(item: $openTask) { TaskDetailView(task: $0) }
        .sheet(isPresented: $pickingProject) { ProjectPicker(filter: $filter) }
        .sensoryFeedback(.selection, trigger: scope)
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button { Task { await model.sync() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .keyboardShortcut("r")
            }
            AddToolbar()
        }
        #endif
    }

    private func list(visible: [PlannerTask], counts: [TaskScope: Int]) -> some View {
        let groups = AppModel.TaskGroup.allCases.map { g in (g, visible.filter { model.group(for: $0) == g }) }.filter { !$0.1.isEmpty }
        let done = scope == .all ? model.doneTasks.filter { inProject($0) && found($0) } : []
        return List {
            Section {
                header(counts: counts)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if groups.isEmpty {
                Section {
                    Text(model.state == nil ? "Loading…" : !searchWords.isEmpty ? "Nothing matches. Press return to add it as a task." : emptyText)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups, id: \.0) { group, tasks in
                Section {
                    ForEach(tasks) { task in
                        PlanRow(task: task, showProject: filter == .all, onOpen: { openTask = task }) { at in
                            justBooked = Booked(taskId: task.id, title: task.title, at: at)
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                } header: {
                    HStack {
                        Text(group.rawValue).foregroundStyle(group == .overdue ? Color.red : Color.secondary)
                        Spacer()
                        Text("\(tasks.count)").monospacedDigit().contentTransition(.numericText())
                    }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                }
            }

            if !done.isEmpty {
                Section(isExpanded: Binding(get: { showDone || !searchWords.isEmpty }, set: { showDone = $0 })) {
                    ForEach(done.prefix(50)) { task in
                        TaskRow(task: task, nextBlock: nil, showProject: filter == .all, onOpen: { openTask = task })
                    }
                } header: {
                    Text("Done (\(done.count))").font(.subheadline.weight(.semibold)).textCase(nil)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .animation(.planner, value: visible.map(\.id))
        .animation(.planner, value: scope)
        .animation(.planner, value: filter)
        .refreshable { await model.sync() }
    }

    private var emptyText: String {
        switch scope {
        case .all: "Nothing open. Type below to add a task; #tag files it under a project."
        case .today: "Nothing due today."
        case .unbooked: "Everything open has time booked."
        case .waiting: "Not waiting on anyone."
        }
    }

    private func header(counts: [TaskScope: Int]) -> some View {
        VStack(spacing: 10) {
            ScopeBar(scope: $scope, counts: counts)
            HStack(spacing: 8) {
                projectButton
                Spacer(minLength: 4)
                ModeToggle(mode: $mode)
            }
        }
    }

    @ViewBuilder private var projectButton: some View {
        let project: Project? = filter.projectId.flatMap { model.project(id: $0) }
        HStack(spacing: 0) {
            Button { pickingProject = true } label: {
                HStack(spacing: 6) {
                    if let project {
                        Text(project.emoji.isEmpty ? "●" : project.emoji)
                        Text(project.name).fontWeight(.semibold).lineLimit(1)
                    } else if filter == .none {
                        Image(systemName: "tray")
                        Text("No project").fontWeight(.semibold)
                    } else {
                        Image(systemName: "square.grid.2x2")
                        Text("All projects")
                    }
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).opacity(0.6)
                }
                .padding(.leading, 12)
                .padding(.trailing, filter == .all ? 12 : 6)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            if filter != .all {
                Button { withAnimation(.planner) { filter = .all } } label: {
                    Image(systemName: "xmark.circle.fill").padding(.trailing, 10).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all projects")
            }
        }
        .font(.subheadline)
        .foregroundStyle(project != nil ? project!.color.color : Color.primary)
        .background((project?.color.color ?? Color.secondary).opacity(project != nil ? 0.16 : 0.1), in: Capsule())
        .overlay(Capsule().strokeBorder((project?.color.color ?? Color.secondary).opacity(0.3), lineWidth: 0.75))
        .accessibilityLabel(project.map { "Project: \($0.name)" } ?? "Choose a project")
    }

    private func bookedToast(_ booked: Booked) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(booked.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(booked.at.map { "Booked \(Format.relative($0))" } ?? "Booked the next free time").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") {
                justBooked = nil
                if let task = model.task(id: booked.taskId), let block = model.nextBlock(for: task) {
                    Task { await model.removeBlock(block) }
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: booked) {
            try? await Task.sleep(for: .seconds(6))
            if justBooked == booked { justBooked = nil }
        }
    }
}

enum TasksMode: String {
    case list, board
}

enum TaskScope: String, CaseIterable, Identifiable {
    case all = "All", today = "Today", unbooked = "Unbooked", waiting = "Waiting"
    var id: String { rawValue }
}

extension TaskFilter {
    var projectId: String? { if case .project(let id) = self { id } else { nil } }
}

/// Four fixed scopes with counts, in one row.
private struct ScopeBar: View {
    @Binding var scope: TaskScope
    let counts: [TaskScope: Int]
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TaskScope.allCases) { s in
                let on = scope == s
                Button { withAnimation(.planner) { scope = s } } label: {
                    VStack(spacing: 1) {
                        Text("\(counts[s] ?? 0)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(s == .today && (counts[s] ?? 0) > 0 && !on ? Color.red : Color.primary)
                            .contentTransition(.numericText())
                        Text(s.rawValue).font(.caption.weight(on ? .semibold : .medium)).foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.cardBackground)
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                                .matchedGeometryEffect(id: "scope", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.rawValue), \(counts[s] ?? 0)")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// List or Board.
private struct ModeToggle: View {
    @Binding var mode: TasksMode

    var body: some View {
        HStack(spacing: 2) {
            button(.list, "list.bullet", "List")
            button(.board, "rectangle.split.3x1", "Board")
        }
        .padding(3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func button(_ m: TasksMode, _ symbol: String, _ label: String) -> some View {
        Button { withAnimation(.planner) { mode = m } } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 30)
                .foregroundStyle(mode == m ? Color.primary : Color.secondary)
                .background(mode == m ? Color.cardBackground : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == m ? [.isButton, .isSelected] : .isButton)
    }
}

/// A task row that says what to do: the title, its project, one next step, and Book.
struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    var showProject = true
    var onOpen: () -> Void = {}
    var onBooked: (Date?) -> Void = { _ in }
    @State private var booking = false

    private var project: Project? { model.project(id: task.projectId) }
    private var bookable: Bool { !task.isDone && task.waitingOn == nil && model.nextBlock(for: task) == nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { Task { await model.toggleDone(task) } } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : task.isWaiting ? "hourglass.circle" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.isDone ? Color.green : project.tint.opacity(0.9))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: task.isDone)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable(scale: 0.8))
            .disabled(task.isWaiting)
            .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
            .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // A checklist step can be long, so it gets its own line under the project.
                    if case .step = model.nextStep(for: task) {
                        if showProject, let project { ProjectChip(project: project) }
                        nextStep.font(.subheadline)
                    } else {
                        HStack(spacing: 6) {
                            if showProject, let project { ProjectChip(project: project) }
                            nextStep
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if bookable { bookButton }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button { Task { await model.toggleDone(task) } } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await model.delete(task) } } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Mark as Done") { Task { await model.toggleDone(task) } }
            if bookable { Button("Book Next Free Time") { book() } }
            Button("Delete", role: .destructive) { Task { await model.delete(task) } }
        }
    }

    @ViewBuilder private var nextStep: some View {
        switch model.nextStep(for: task) {
        case .chase(let who):
            Label("Chase \(who)", systemImage: "arrow.uturn.left").foregroundStyle(.red).lineLimit(1)
        case let .waiting(who, check):
            Label(check.map { "\(who) · check \($0.formatted(.dateTime.weekday(.abbreviated)))" } ?? who, systemImage: "hourglass")
                .foregroundStyle(.secondary).lineLimit(1)
        case .step(let text):
            Label(text, systemImage: "arrow.turn.down.right").foregroundStyle(.primary.opacity(0.8)).lineLimit(2)
        case .booked(let at):
            Label(Format.relative(at), systemImage: "calendar").foregroundStyle(project.tint).lineLimit(1)
        case .takes(let minutes):
            Label("~\(Format.duration(minutes))", systemImage: "clock").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Today's first gap that fits, unless the project keeps its own hours: then the server picks.
    private func slot(_ minutes: Int) -> Date? {
        if let project, !project.windows.isEmpty || project.hostMatch != nil { return nil }
        return model.freeSlotToday(minutes: minutes)
    }

    private var bookButton: some View {
        let minutes = model.likelyMinutes(task)
        let slot = slot(minutes)
        return Button(action: book) {
            VStack(spacing: 0) {
                if booking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Book").font(.subheadline.weight(.bold))
                    Text(slot.map(Format.shortClock) ?? "next free").font(.caption2.weight(.semibold)).opacity(0.8)
                }
            }
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 62, minHeight: 44)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.75))
        }
        .buttonStyle(.pressable(scale: 0.9))
        .disabled(booking)
        .accessibilityLabel(slot.map { "Book \(Format.duration(minutes)) at \(Format.shortClock($0))" } ?? "Book the next free time")
    }

    private func book() {
        let minutes = model.likelyMinutes(task)
        let slot = slot(minutes)
        booking = true
        Task {
            // A guessed length becomes the task's estimate, so the server books the same.
            if minutes != task.estimateMin { _ = await model.update(task, TaskPatch(estimateMin: minutes)) }
            let ok: Bool
            if let slot {
                ok = await model.book(task, at: slot, minutes: minutes)
            } else {
                ok = await model.scheduleNextFree(task)
            }
            booking = false
            if ok { onBooked(slot ?? model.task(id: task.id).flatMap { model.nextBlock(for: $0)?.startAt }) }
        }
    }
}

/// Pick which project's tasks to show: big coloured rows that are easy to tell apart.
struct ProjectPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: TaskFilter
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "All projects", emoji: nil, symbol: "square.grid.2x2", tint: .accentColor, count: model.openTasks.count, on: filter == .all) { filter = .all }
                    row(title: "No project", emoji: nil, symbol: "tray", tint: .gray, count: model.openTasks.filter { $0.projectId == nil }.count, on: filter == .none) { filter = .none }
                }
                Section("Projects") {
                    ForEach(model.liveProjects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { p in
                        row(title: p.name, emoji: p.emoji, symbol: "folder.fill", tint: p.color.color,
                            count: model.openTasks.filter { $0.projectId == p.id }.count, on: filter == .project(p.id)) {
                            filter = .project(p.id)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a project")
            .navigationTitle("Show tasks from")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }

    private func row(title: String, emoji: String?, symbol: String, tint: Color, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let emoji, !emoji.isEmpty { Text(emoji).font(.title3) } else { Image(systemName: symbol).foregroundStyle(.white) }
                }
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                if on { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width && !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    let nextBlock: CalEvent?
    var showProject = true
    var onOpen: () -> Void = {}

    private var project: Project? { model.project(id: task.projectId) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if task.isWaiting {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
            } else {
                Button {
                    Task { await model.toggleDone(task) }
                } label: {
                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isDone ? Color.green : project.tint.opacity(0.85))
                        .imageScale(.large)
                        .fontWeight(.semibold)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: task.isDone)
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.8))
                .sensoryFeedback(.success, trigger: task.isDone) { _, done in done }
                .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(task.title)
                            .strikethrough(task.isDone)
                            .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                        if task.repeats {
                            Image(systemName: "repeat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(task.recurrence?.summary ?? "Repeats")
                        }
                    }
                    details
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if project != nil && !task.isDone {
                Rectangle().fill(project.tint).frame(width: 3).offset(x: -10)
            }
        }
        .contextMenu {
            Button("Open") { onOpen() }
            if !task.isWaiting {
                Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { Task { await model.toggleDone(task) } }
            }
            Button("Delete", role: .destructive) { Task { await model.delete(task) } }
        }
    }

    private var details: some View {
        HStack(spacing: 8) {
            if showProject, let project { ProjectChip(project: project) }
            if task.isWaiting {
                Text([task.waitingOn.map { "Waiting on \($0)" }, task.followUpAt.map { "follow up \(Format.relative($0))" }].compactMap { $0 }.joined(separator: " · "))
            } else if let who = task.waitingOn, !task.isDone {
                Label("Follow up with \(who)", systemImage: "arrow.uturn.left").foregroundStyle(.red)
            }
            if !task.isWaiting {
                if let due = task.dueAt {
                    Label(Format.relative(due), systemImage: "flag")
                        .foregroundStyle(!task.isDone && due < Date() ? Color.red : Color.secondary)
                }
                Label(Format.duration(task.estimateMin), systemImage: "hourglass")
            }
            if let progress = task.checklistProgress {
                Label(progress, systemImage: "checklist")
            }
            if !task.links.isEmpty {
                Label("\(task.links.count)", systemImage: "link")
                    .accessibilityLabel("\(task.links.count) link\(task.links.count == 1 ? "" : "s")")
            }
            if let priority = Format.priority(task.priority) {
                Text(priority).foregroundStyle(task.priority >= 3 ? Color.orange : Color.secondary)
            }
            if let block = nextBlock {
                Label(Format.relative(block.startAt), systemImage: "calendar").foregroundStyle(project.tint)
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

/// Type a task or event in plain language. The server shows how it reads it before saving.
struct CaptureBar: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    /// On the Tasks page the field also filters the list.
    var findsToo = true
    @State private var preview: Captured?
    @State private var saving = false
    @State private var showVoice = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if findsToo {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                TextField(findsToo ? "Find or add a task… #project @person" : "Add a task… #project @person", text: $text)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit(save)
                    .disabled(saving)
                if saving {
                    ProgressView().controlSize(.small)
                } else if trimmed.isEmpty {
                    Button { showVoice = true } label: {
                        Image(systemName: "mic.circle.fill").imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Speak a task")
                } else {
                    Button(action: save) {
                        Image(systemName: "plus.circle.fill").imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Add")
                }
            }
            if let preview, !trimmed.isEmpty {
                Text((findsToo ? "Return to add: " : "") + Format.captured(preview, projectName: model.project(id: preview.projectId)?.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .sheet(isPresented: $showVoice) { VoiceCaptureView() }
        .task(id: trimmed) {
            guard !trimmed.isEmpty else {
                preview = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            preview = await model.preview(trimmed)
        }
    }

    private func save() {
        let line = trimmed
        guard !line.isEmpty, !saving else { return }
        saving = true
        Task {
            if await model.capture(line) {
                text = ""
                preview = nil
            }
            saving = false
            focused = true
        }
    }
}

/// The add field on its own, keeping its own text (used in Wrap Up).
struct StandaloneCaptureBar: View {
    @State private var text = ""
    var body: some View { CaptureBar(text: $text, findsToo: false) }
}
