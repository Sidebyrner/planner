import PlannerKit
import SwiftUI

/// Everything about one task: project, timing, repeat, checklist, links and who it's waiting on.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: PlannerTask

    @State private var title: String
    @State private var notes: String
    @State private var projectId: String?
    @State private var priority: Int
    @State private var estimateMin: Int
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var checklist: [ChecklistItem]
    @State private var newStep = ""
    @State private var waiting: Bool
    @State private var waitingOn: String
    @State private var followUp: Date
    @State private var email: String
    @State private var phone: String
    @State private var links: [TaskLink]
    @State private var newLinkLabel = ""
    @State private var newLinkURL = ""
    @State private var repeatRule: RepeatDraft
    @State private var saving = false

    init(task: PlannerTask) {
        self.task = task
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes)
        _projectId = State(initialValue: task.projectId)
        _priority = State(initialValue: task.priority)
        _estimateMin = State(initialValue: task.estimateMin)
        _hasDue = State(initialValue: task.dueAt != nil)
        _due = State(initialValue: task.dueAt ?? Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date())
        _checklist = State(initialValue: task.checklist)
        _waiting = State(initialValue: task.isWaiting)
        _waitingOn = State(initialValue: task.waitingOn ?? "")
        _followUp = State(initialValue: task.followUpAt ?? Date().addingTimeInterval(2 * 86_400))
        _email = State(initialValue: task.contact?.email ?? "")
        _phone = State(initialValue: task.contact?.phone ?? "")
        _links = State(initialValue: task.links)
        _repeatRule = State(initialValue: RepeatDraft(task.recurrence, due: task.dueAt))
    }

    private var newLink: TaskLink? { TaskLink.normalized(label: newLinkLabel, url: newLinkURL) }

    private var notesHaveList: Bool { !Checklist.fromNotes(notes).items.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Project", selection: $projectId) {
                        Text("No project").tag(String?.none)
                        ForEach(model.projects.filter { !$0.archived || $0.id == task.projectId }) { p in
                            Text(p.label).tag(String?.some(p.id))
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("High").tag(3)
                        Text("Normal").tag(2)
                        Text("Low").tag(1)
                    }
                }

                if !waiting {
                    Section("Timing") {
                        Stepper("Takes \(Format.duration(estimateMin))", value: $estimateMin, in: 5...1440, step: 5)
                        Toggle("Due date", isOn: $hasDue)
                        if hasDue {
                            DatePicker("Due", selection: $due)
                        }
                        if let block = model.nextBlock(for: task) {
                            LabeledContent("Next block", value: Format.relative(block.startAt))
                        }
                    }

                    RepeatSection(rule: $repeatRule, hasDue: hasDue)
                }

                Section {
                    ForEach($checklist) { $item in
                        HStack {
                            Button {
                                item.done.toggle()
                            } label: {
                                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            TextField("Step", text: $item.text)
                                .strikethrough(item.done)
                        }
                    }
                    .onDelete { checklist.remove(atOffsets: $0) }
                    .onMove { checklist.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("Add a step", text: $newStep)
                            .onSubmit(addStep)
                        Button("Add", action: addStep).disabled(newStep.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if notesHaveList {
                        Button("Make Checklist from Notes") {
                            let (items, rest) = Checklist.fromNotes(notes)
                            checklist += items
                            notes = rest
                        }
                    }
                } header: {
                    Text(checklist.isEmpty ? "Checklist" : "Checklist (\(checklist.filter(\.done).count)/\(checklist.count))")
                }

                Section {
                    Toggle("Waiting on someone else", isOn: $waiting)
                        .disabled(task.isDone)
                    if waiting || !waitingOn.isEmpty {
                        TextField("Who", text: $waitingOn)
                    }
                    if waiting {
                        DatePicker("Follow up", selection: $followUp)
                    }
                    if waiting || !waitingOn.isEmpty {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        TextField("Phone", text: $phone)
                            .textContentType(.telephoneNumber)
                            #if os(iOS)
                            .keyboardType(.phonePad)
                            #endif
                        ContactButtons(name: waitingOn, email: email, phone: phone, subject: title)
                    }
                } footer: {
                    Text("A waiting task isn't scheduled. It comes back to your open list on the follow-up date.")
                }

                Section {
                    ForEach(links) { link in
                        if let url = link.destination {
                            Link(destination: url) {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(link.label)
                                        Text(url.host() ?? link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                } icon: {
                                    Image(systemName: TaskLinkIcon.name(for: url))
                                }
                            }
                        } else {
                            Text(link.label).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { links.remove(atOffsets: $0) }
                    .onMove { links.move(fromOffsets: $0, toOffset: $1) }
                    TextField("Label (e.g. Email thread)", text: $newLinkLabel)
                    HStack {
                        TextField("Link or email address", text: $newLinkURL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .onSubmit(addLink)
                        Button("Add", action: addLink).disabled(newLink == nil)
                    }
                } header: {
                    Text("Links")
                } footer: {
                    if !newLinkURL.isEmpty && newLink == nil {
                        Text("Use a web address, an email address, or a tel: link.")
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 90)
                }

                Section {
                    Button("Delete Task", role: .destructive) {
                        Task {
                            await model.delete(task)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(waiting ? "Waiting" : "Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || (waiting && waitingOn.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func addLink() {
        guard let link = newLink else { return }
        links.append(link)
        newLinkLabel = ""
        newLinkURL = ""
    }

    /// What's in the list plus a link typed but not yet added, so Save doesn't drop it.
    private var allLinks: [TaskLink] { newLink.map { links + [$0] } ?? links }

    private var contact: Contact? {
        let name = waitingOn.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces)
        let p = phone.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !(e.isEmpty && p.isEmpty) else { return nil }
        return Contact(name: name, email: e.isEmpty ? nil : e, phone: p.isEmpty ? nil : p)
    }

    private func addStep() {
        let text = newStep.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        checklist.append(ChecklistItem(text: text))
        newStep = ""
    }

    private func save() {
        saving = true
        let who = waitingOn.trimmingCharacters(in: .whitespaces)
        let status: TaskStatus? = waiting ? .waiting : (task.isWaiting ? .todo : nil)
        let patch = TaskPatch(
            title: title,
            notes: notes,
            status: status,
            priority: priority,
            estimateMin: estimateMin,
            dueAt: .some(hasDue ? due : nil),
            projectId: .some(projectId),
            checklist: checklist,
            waitingOn: .some(who.isEmpty ? nil : who),
            followUpAt: waiting ? .some(followUp) : nil,
            links: allLinks != task.links ? allLinks : nil,
            contact: contact != task.contact ? .some(contact) : nil,
            recurrence: repeatRule.rule != task.recurrence ? .some(repeatRule.rule) : nil
        )
        Task {
            if await model.update(task, patch) { dismiss() }
            saving = false
        }
    }
}
