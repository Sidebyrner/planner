import PlannerKit
import SwiftUI

/// Which tasks the list shows.
enum TaskFilter: Hashable {
    case all
    case none
    case project(String)
}

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var showDone = false
    @State private var filter: TaskFilter = .all
    @State private var openTask: PlannerTask?

    private func matches(_ task: PlannerTask) -> Bool {
        switch filter {
        case .all: true
        case .none: task.projectId == nil
        case .project(let id): task.projectId == id
        }
    }

    var body: some View {
        let open = model.openTasks.filter(matches)
        let waiting = model.waitingTasks.filter(matches)
        let done = model.doneTasks.filter(matches)

        List {
            Section {
                CaptureBar()
            }

            if !model.liveProjects.isEmpty {
                Section {
                    ProjectFilterBar(filter: $filter)
                }
            }

            Section("Open") {
                if open.isEmpty {
                    Text(model.state == nil ? "Loading…" : "Nothing open. Add a task above; #tag files it under a project.")
                        .foregroundStyle(.secondary)
                }
                ForEach(open) { task in
                    TaskRow(task: task, nextBlock: model.nextBlock(for: task), showProject: filter == .all, onOpen: { openTask = task })
                }
                .onDelete { offsets in
                    let tasks = offsets.map { open[$0] }
                    Task { for task in tasks { await model.delete(task) } }
                }
            }

            if !waiting.isEmpty {
                Section("Waiting on others (\(waiting.count))") {
                    ForEach(waiting) { task in
                        TaskRow(task: task, nextBlock: nil, showProject: filter == .all, onOpen: { openTask = task })
                    }
                }
            }

            if !done.isEmpty {
                Section(isExpanded: $showDone) {
                    ForEach(done.prefix(50)) { task in
                        TaskRow(task: task, nextBlock: nil, showProject: filter == .all, onOpen: { openTask = task })
                    }
                } header: {
                    Text("Done (\(done.count))")
                }
            }
        }
        .navigationTitle("Tasks")
        .refreshable { await model.sync() }
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
        }
    }
}

struct ProjectFilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: TaskFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill("All", tint: .accentColor, on: filter == .all) { filter = .all }
                ForEach(model.liveProjects) { project in
                    let count = model.openTasks.filter { $0.projectId == project.id }.count
                    pill(count > 0 ? "\(project.label) \(count)" : project.label, tint: project.color.color, on: filter == .project(project.id)) {
                        filter = .project(project.id)
                    }
                }
                pill("No project", tint: .gray, on: filter == .none) { filter = .none }
            }
            .padding(.vertical, 2)
        }
    }

    private func pill(_ title: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(on ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(on ? tint : .primary)
                .background(on ? tint.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? tint : .clear))
        }
        .buttonStyle(.plain)
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
                        .foregroundStyle(task.isDone ? Color.accentColor : project.tint.opacity(0.8))
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
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
    @State private var text = ""
    @State private var preview: Captured?
    @State private var saving = false
    @State private var showVoice = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add a task… #project @person", text: $text)
                    .textFieldStyle(.plain)
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
                Text(Format.captured(preview, projectName: model.project(id: preview.projectId)?.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
