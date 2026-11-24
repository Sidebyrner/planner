import PlannerKit
import SwiftUI

/// Every project at a glance: what's next, what's slipping, what's waiting. Tap one for its page.
struct ProjectsHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if model.liveProjects.isEmpty {
                    empty
                } else {
                    ForEach(model.projectsByAttention, id: \.project.id) { item in
                        NavigationLink(value: item.project.id) {
                            ProjectCard(project: item.project, summary: item.summary)
                        }
                        .buttonStyle(.plain)
                    }
                    let unfiled = model.summary(for: nil)
                    if unfiled.open + unfiled.waiting.count > 0 {
                        NavigationLink(value: ProjectsHomeView.unfiledID) {
                            ProjectCard(project: nil, summary: unfiled)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96) // room above the floating + button
        }
        .background(Color.pageBackground)
        .navigationTitle("Projects")
        .navigationDestination(for: String.self) { id in
            ProjectDetailView(projectId: id == Self.unfiledID ? nil : id)
        }
        .refreshable { await model.sync() }
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    .help("Add a project")
            }
            AddToolbar()
        }
        .sheet(isPresented: $adding) { ProjectEditor(project: nil) }
    }

    static let unfiledID = "__unfiled"

    private var empty: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("No projects yet", systemImage: "folder").font(.headline)
                Text("A project groups tasks so you can see how each one is going. Type #tag when you add a task to file it.")
                    .foregroundStyle(.secondary)
                Button { adding = true } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A project's card: name, progress this week, what's next and anything that needs a look.
private struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let project: Project?
    let summary: AppModel.ProjectSummary

    private var tint: Color { project.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(project == nil ? Color.gray : tint).frame(width: 6, height: 22)
                Text(project?.label ?? "No project").font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(summary.open == 0 ? "Clear" : "\(summary.open) open")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }

            if !summary.doneThisWeek.isEmpty {
                ProgressView(value: summary.progress)
                    .tint(project == nil ? .gray : tint)
                    .accessibilityLabel("\(summary.doneThisWeek.count) done this week, \(summary.open) open")
            }

            if let next = summary.nextUp {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Next").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text(next.title).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    nextWhen(next)
                }
            } else if summary.waiting.isEmpty {
                Text("Nothing open. Add a task with #\(project?.tag ?? "tag").")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            let chips = chips
            if !chips.isEmpty {
                // As many chips as fit on one line, most important first.
                ViewThatFits(in: .horizontal) {
                    ForEach((1...chips.count).reversed(), id: \.self) { n in
                        chipRow(Array(chips.prefix(n)))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project")
    }

    @ViewBuilder private func nextWhen(_ task: PlannerTask) -> some View {
        if let due = task.dueAt, due < Date() {
            Text("Overdue").font(.caption.weight(.semibold)).foregroundStyle(.red)
        } else if let block = model.nextBlock(for: task) {
            Label(Format.relative(block.startAt), systemImage: "calendar").font(.caption).foregroundStyle(tint)
        } else {
            Text("Not scheduled").font(.caption).foregroundStyle(.orange)
        }
    }

    private struct Chip { var text: String; var symbol: String; var color: Color }

    private func chipRow(_ chips: [Chip]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips, id: \.text) { chip in
                Label(chip.text, systemImage: chip.symbol)
                    .font(.caption.weight(.medium))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(chip.color)
                    .background(chip.color.opacity(0.12), in: Capsule())
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var chips: [Chip] {
        var out: [Chip] = []
        if !summary.overdue.isEmpty { out.append(Chip(text: "\(summary.overdue.count) overdue", symbol: "exclamationmark.circle", color: .red)) }
        if !summary.unscheduled.isEmpty { out.append(Chip(text: "\(summary.unscheduled.count) unbooked", symbol: "calendar.badge.exclamationmark", color: .orange)) }
        if summary.dueThisWeek > 0 { out.append(Chip(text: "\(summary.dueThisWeek) due soon", symbol: "flag", color: .secondary)) }
        if !summary.waiting.isEmpty { out.append(Chip(text: "\(summary.waiting.count) waiting", symbol: "hourglass", color: .secondary)) }
        if summary.minutesLeft > 0 { out.append(Chip(text: Format.duration(summary.minutesLeft) + " to book", symbol: "clock", color: .secondary)) }
        return out
    }
}

// MARK: - A project's page

/// Everything in one project, grouped by what it needs: overdue, booked, to schedule, waiting, done.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    /// `nil` shows tasks with no project.
    let projectId: String?
    @State private var openTask: PlannerTask?
    @State private var editing = false
    @State private var newTitle = ""
    @State private var adding = false
    @State private var scheduling = false
    @State private var showDone = false
    @FocusState private var addFocused: Bool

    private var project: Project? { model.project(id: projectId) }

    var body: some View {
        let s = model.summary(for: project)
        List {
            Section {
                header(s)
                quickAdd
            }

            if !s.overdue.isEmpty {
                Section {
                    rows(s.overdue)
                } header: {
                    Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            if !s.scheduled.isEmpty {
                Section("Booked") { rows(s.scheduled) }
            }

            Section {
                if s.unscheduled.isEmpty {
                    Text(s.open == 0 ? "Nothing open." : "Everything open has time booked.")
                        .foregroundStyle(.secondary)
                }
                ForEach(s.unscheduled) { task in
                    row(task)
                        .swipeActions(edge: .leading) {
                            Button { Task { await model.scheduleNextFree(task) } } label: { Label("Next free", systemImage: "calendar.badge.plus") }
                                .tint(.accentColor)
                        }
                        .contextMenu {
                            Button { Task { await model.scheduleNextFree(task) } } label: { Label("Book Next Free Slot", systemImage: "calendar.badge.plus") }
                        }
                }
            } header: {
                HStack {
                    Text("To schedule")
                    Spacer()
                    if s.unscheduled.count > 0 {
                        Button(scheduling ? "Scheduling…" : "Schedule all \(s.unscheduled.count)") { scheduleAll(s.unscheduled) }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                            .disabled(scheduling)
                    }
                }
            } footer: {
                if !s.unscheduled.isEmpty {
                    Text("Swipe right on a task to book its next free slot\(project.map { $0.windows.isEmpty ? "" : " in this project's hours" } ?? "").")
                }
            }

            if !s.waiting.isEmpty {
                Section("Waiting on others") { rows(s.waiting) }
            }

            if !s.doneThisWeek.isEmpty {
                Section(isExpanded: $showDone) {
                    rows(s.doneThisWeek)
                } header: {
                    Text("Done this week (\(s.doneThisWeek.count))")
                }
            }
        }
        .navigationTitle(project?.label ?? "No project")
        .refreshable { await model.sync() }
        .sheet(item: $openTask) { TaskDetailView(task: $0) }
        .sheet(isPresented: $editing) { ProjectEditor(project: project) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { router.open(.board(projectId: projectId)) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                    .help("This project's tasks by status")
                if project != nil {
                    Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                        .help("Name, colour and hours")
                }
            }
        }
    }

    private func row(_ task: PlannerTask) -> some View {
        TaskRow(task: task, nextBlock: model.nextBlock(for: task), showProject: false, onOpen: { openTask = task })
    }

    private func rows(_ tasks: [PlannerTask]) -> some View {
        ForEach(tasks) { row($0) }
    }

    private func header(_ s: AppModel.ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                stat("\(s.open)", "open")
                stat("\(s.doneThisWeek.count)", "done this week")
                stat(s.minutesLeft > 0 ? Format.duration(s.minutesLeft) : "0", "to book")
            }
            if !s.doneThisWeek.isEmpty {
                ProgressView(value: s.progress).tint(project.tint)
            }
            if let project {
                Label(hours(project), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                let links = project.links.filter { $0.destination != nil }
                if !links.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(links) { link in
                                if let url = link.destination {
                                    Link(destination: url) {
                                        Label(link.label, systemImage: "link")
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(project.color.color.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func hours(_ p: Project) -> String {
        var parts = p.windows.map { "\(Format.weekdays($0.days)) \(Format.clock($0.start))–\(Format.clock($0.end))" }
        if let host = p.hostMatch { parts.append("events titled “\(host)”") }
        if parts.isEmpty { return "Scheduled in your working hours" }
        return parts.joined(separator: " · ") + (p.windowStrict ? " only" : "")
    }

    private var quickAdd: some View {
        HStack {
            Image(systemName: "plus.circle.fill").foregroundStyle(project.tint)
            TextField(project == nil ? "Add a task…" : "Add to \(project!.name)… e.g. draft intro 45m fri", text: $newTitle)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .onSubmit(add)
                .disabled(adding)
            if adding { ProgressView().controlSize(.small) }
        }
    }

    private func add() {
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        adding = true
        Task {
            // The capture parser reads durations and dates; the #tag files it here.
            let ok: Bool
            if let tag = project?.tag, !tag.isEmpty {
                ok = await model.capture("\(text) #\(tag)")
            } else {
                ok = await model.createTask(TaskDraft(title: text, projectId: projectId)) != nil
            }
            if ok { newTitle = "" }
            adding = false
            addFocused = true
        }
    }

    private func scheduleAll(_ tasks: [PlannerTask]) {
        scheduling = true
        Task {
            if let proposal = await model.propose(taskIds: tasks.map(\.id)) {
                if proposal.blocks.isEmpty {
                    model.actionError = "No free time left in the planning window for these tasks."
                } else {
                    await model.book(proposal.blocks)
                }
            }
            scheduling = false
        }
    }
}
