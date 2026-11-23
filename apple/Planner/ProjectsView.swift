import PlannerKit
import SwiftUI

/// List of projects, with add and edit.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Project?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.liveProjects) { project in
                    Button { editing = project } label: {
                        HStack {
                            Circle().fill(project.color.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.label)
                                Text(summary(project)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("#\(project.tag)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    adding = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            } footer: {
                Text("Type #tag in the capture bar to file a task under a project. A project can have its own hours for scheduling.")
            }

            let archived = model.projects.filter(\.archived)
            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { project in
                        HStack {
                            Text(project.label).foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore") { Task { await model.saveProject(id: project.id, ProjectPatch(archived: false)) } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .sheet(isPresented: $adding) { ProjectEditor(project: nil) }
    }

    private func summary(_ p: Project) -> String {
        let open = model.openTasks.filter { $0.projectId == p.id }.count
        let hours = p.windows.isEmpty && p.hostMatch == nil ? "working hours" : "own hours"
        return "\(open) open · \(hours)"
    }
}

struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project?

    @State private var name: String
    @State private var tag: String
    @State private var emoji: String
    @State private var color: ProjectColor
    @State private var windows: [TimeWindow]
    @State private var strict: Bool
    @State private var hostMatch: String
    @State private var saving = false

    init(project: Project?) {
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _tag = State(initialValue: project?.tag ?? "")
        _emoji = State(initialValue: project?.emoji ?? "")
        _color = State(initialValue: project?.color ?? .teal)
        _windows = State(initialValue: project?.windows ?? [])
        _strict = State(initialValue: project?.windowStrict ?? false)
        _hostMatch = State(initialValue: project?.hostMatch ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Tag for #capture (optional)", text: $tag)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Emoji", text: $emoji)
                    HStack(spacing: 10) {
                        ForEach(ProjectColor.allCases, id: \.self) { c in
                            Button { color = c } label: {
                                Circle()
                                    .fill(c.color)
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == c ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                            .accessibilityAddTraits(color == c ? .isSelected : [])
                        }
                    }
                }

                Section {
                    ForEach(windows.indices, id: \.self) { i in
                        WindowEditor(window: $windows[i]) { windows.remove(at: i) }
                    }
                    Button {
                        windows.append(TimeWindow(days: [1, 2, 3, 4, 5], start: "09:00", end: "12:00"))
                    } label: {
                        Label("Add Hours", systemImage: "plus")
                    }
                    TextField("Also use events titled…", text: $hostMatch, prompt: Text("e.g. Career block"))
                    Toggle("Only these hours", isOn: $strict)
                } header: {
                    Text("When to schedule it")
                } footer: {
                    Text("Leave empty to use your working hours. Calendar events whose title contains the text above become time for this project. With “Only these hours” off, Planner falls back to working hours when these are full.")
                }

                if let project {
                    Section {
                        Button("Remove Project", role: .destructive) {
                            Task {
                                await model.removeProject(project)
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("A project with tasks is archived instead, so its history keeps its colour.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(project == nil ? "New Project" : project!.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func save() {
        saving = true
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        let trimmedHost = hostMatch.trimmingCharacters(in: .whitespaces)
        let patch = ProjectPatch(
            name: name.trimmingCharacters(in: .whitespaces),
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            color: color,
            emoji: emoji.trimmingCharacters(in: .whitespaces),
            windows: windows,
            windowStrict: strict,
            hostMatch: .some(trimmedHost.isEmpty ? nil : trimmedHost)
        )
        Task {
            if await model.saveProject(id: project?.id, patch) { dismiss() }
            saving = false
        }
    }
}

private struct WindowEditor: View {
    @Binding var window: TimeWindow
    var onRemove: () -> Void

    private static let names = ["M", "T", "W", "T", "F", "S", "S"]
    private static let times: [String] = (0..<96).map { String(format: "%02d:%02d", $0 / 4, ($0 % 4) * 15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    let on = window.days.contains(day)
                    Button(Self.names[day - 1]) {
                        window.days = on ? window.days.filter { $0 != day } : (window.days + [day]).sorted()
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Remove these hours")
            }
            HStack {
                Picker("From", selection: $window.start) { options(window.start) }
                Picker("Until", selection: $window.end) { options(window.end) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func options(_ current: String) -> some View {
        let list = Self.times.contains(current) ? Self.times : (Self.times + [current]).sorted()
        ForEach(list, id: \.self) { Text($0).tag($0) }
    }
}
