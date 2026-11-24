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
    @State private var showDone = false
    @State private var filter: TaskFilter = .all
    @State private var openTask: PlannerTask?
    /// What's typed in the bottom bar: it filters the list and becomes a task on return.
    @State private var text = ""

    private func matches(_ task: PlannerTask) -> Bool {
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
        let haystack = (task.title + " " + task.notes + " " + (task.waitingOn ?? "")).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    var body: some View {
        let open = model.openTasks.filter { matches($0) && found($0) }
        let waiting = model.waitingTasks.filter { matches($0) && found($0) }
        let done = model.doneTasks.filter { matches($0) && found($0) }
        let searching = !searchWords.isEmpty

        List {
            if !model.liveProjects.isEmpty {
                Section {
                    ProjectFilterBar(filter: $filter)
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                }
            }

            Section {
                if open.isEmpty {
                    Text(model.state == nil ? "Loading…" : searching ? "No open tasks match. Press return to add it." : "Nothing open. Add a task below; #tag files it under a project.")
                        .foregroundStyle(.secondary)
                }
                ForEach(open) { task in
                    TaskRow(task: task, nextBlock: model.nextBlock(for: task), showProject: filter == .all, onOpen: { openTask = task })
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                }
                .onDelete { offsets in
                    let tasks = offsets.map { open[$0] }
                    Task { for task in tasks { await model.delete(task) } }
                }
            } header: {
                Text(searching ? "Open · \(open.count) match\(open.count == 1 ? "" : "es")" : "Open")
                    .contentTransition(.numericText())
            }

            if !waiting.isEmpty {
                Section("Waiting on others (\(waiting.count))") {
                    ForEach(waiting) { task in
                        TaskRow(task: task, nextBlock: nil, showProject: filter == .all, onOpen: { openTask = task })
                    }
                }
            }

            if !done.isEmpty {
                Section(isExpanded: Binding(get: { showDone || searching }, set: { showDone = $0 })) {
                    ForEach(done.prefix(50)) { task in
                        TaskRow(task: task, nextBlock: nil, showProject: filter == .all, onOpen: { openTask = task })
                    }
                } header: {
                    Text("Done (\(done.count))")
                }
            }
        }
        .animation(.planner, value: open.map(\.id))
        .animation(.planner, value: filter)
        .navigationTitle("Tasks")
        .refreshable { await model.sync() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureBar(text: $text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
        .sheet(item: $openTask) { task in
            TaskDetailView(task: task)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.sync() }
                } label: {
                    if model.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(model.isSyncing)
                .keyboardShortcut("r")
            }
            ToolbarItem {
                Button { router.open(.flow(.board)) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                    .help("See every task by status")
            }
            AddToolbar()
        }
    }
}

/// Project tags that wrap onto as many lines as they need, so none hide off to the side.
struct ProjectFilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: TaskFilter
    @State private var expanded = false
    private let collapsedCount = 7

    var body: some View {
        let projects = model.liveProjects
        let shown = expanded || projects.count <= collapsedCount + 1 ? projects : Array(projects.prefix(collapsedCount))
        FlowLayout(spacing: 8) {
            pill("All", tint: .accentColor, on: filter == .all) { filter = .all }
            ForEach(shown) { project in
                let count = model.openTasks.filter { $0.projectId == project.id }.count
                pill(count > 0 ? "\(project.label) \(count)" : project.label, tint: project.color.color, on: filter == .project(project.id)) {
                    filter = .project(project.id)
                }
            }
            pill("No project", tint: .gray, on: filter == .none) { filter = .none }
            if projects.count > collapsedCount + 1 {
                pill(expanded ? "Less" : "More (\(projects.count - collapsedCount))", tint: .secondary, on: false) {
                    withAnimation(.planner) { expanded.toggle() }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func pill(_ title: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : tint.opacity(0.35), lineWidth: 0.75))
        }
        .buttonStyle(.pressable(scale: 0.94))
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
