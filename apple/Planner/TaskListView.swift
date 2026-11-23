import PlannerKit
import SwiftUI

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    @State private var showDone = false

    var body: some View {
        List {
            Section {
                CaptureBar()
            }

            Section("Open") {
                if model.openTasks.isEmpty {
                    Text(model.state == nil ? "Loading…" : "Nothing open. Add a task above.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.openTasks) { task in
                    TaskRow(task: task, nextBlock: model.nextBlock(for: task))
                }
                .onDelete { offsets in
                    let tasks = offsets.map { model.openTasks[$0] }
                    Task { for task in tasks { await model.delete(task) } }
                }
            }

            if !model.doneTasks.isEmpty {
                Section(isExpanded: $showDone) {
                    ForEach(model.doneTasks) { task in
                        TaskRow(task: task, nextBlock: nil)
                    }
                } header: {
                    Text("Done (\(model.doneTasks.count))")
                }
            }
        }
        .navigationTitle("Tasks")
        .refreshable { await model.sync() }
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

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    let nextBlock: CalEvent?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                Task { await model.toggleDone(task) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                details
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { Task { await model.toggleDone(task) } }
            Button("Delete", role: .destructive) { Task { await model.delete(task) } }
        }
    }

    private var details: some View {
        HStack(spacing: 8) {
            if let due = task.dueAt {
                Label(Format.relative(due), systemImage: "flag")
                    .foregroundStyle(!task.isDone && due < Date() ? Color.red : Color.secondary)
            }
            Label(Format.duration(task.estimateMin), systemImage: "hourglass")
            if let priority = Format.priority(task.priority) {
                Text(priority)
                    .foregroundStyle(task.priority >= 3 ? Color.orange : Color.secondary)
            }
            if let block = nextBlock {
                Label(Format.relative(block.startAt), systemImage: "calendar")
                    .foregroundStyle(Color.accentColor)
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
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add a task or event, e.g. “Write report by Friday 2h”", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(save)
                    .disabled(saving)
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: save) {
                        Image(systemName: "plus.circle.fill").imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel("Add")
                }
            }
            if let preview, !trimmed.isEmpty {
                Text(Format.captured(preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
