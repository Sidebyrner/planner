import PlannerKit
import SwiftUI

/// Opens the add sheets and guided workflows from anywhere: the floating + button, toolbars,
/// Today's cards and, on the Mac, the menu bar.
@Observable
final class Router {
    enum Flow: String, Identifiable, CaseIterable {
        case planDay, wrapUp, followUps, weekly, board
        var id: String { rawValue }

        var title: String {
            switch self {
            case .planDay: "Plan My Day"
            case .wrapUp: "Wrap Up the Day"
            case .followUps: "Follow-up Round"
            case .weekly: "Weekly Review"
            case .board: "Task Board"
            }
        }

        var symbol: String {
            switch self {
            case .planDay: "sunrise"
            case .wrapUp: "moon.stars"
            case .followUps: "person.2.wave.2"
            case .weekly: "calendar.badge.checkmark"
            case .board: "rectangle.split.3x1"
            }
        }

        var blurb: String {
            switch self {
            case .planDay: "Clear leftovers, pick your top 3, book them"
            case .wrapUp: "Check off today, move what's left"
            case .followUps: "Chase who you're waiting on"
            case .weekly: "Your week by project, then next week"
            case .board: "Every task by status"
            }
        }

        /// The routines you step through, as opposed to the board, which is a tool.
        static var guided: [Flow] { [.planDay, .wrapUp, .followUps, .weekly] }

        /// Up to two routines that fit the moment, best first, leaving out any already done:
        /// planning in the morning, chasing people or planning in the afternoon (wrapping up
        /// once blocks pile up), wrapping up in the evening with the weekly review at the weekend.
        static func forNow(now: Date, review: Int, chase: Int, unbooked: Int = 0) -> [Flow] {
            let hour = Calendar.current.component(.hour, from: now)
            let weekday = Calendar.current.component(.weekday, from: now) // 1 = Sunday
            var picks: [Flow]
            switch hour {
            case ..<12:
                picks = [.planDay] + (chase > 0 ? [.followUps] : [])
            case ..<17:
                picks = []
                if chase > 0 { picks.append(.followUps) }
                if unbooked > 0 || chase == 0 { picks.append(.planDay) }
                if review >= 3 { picks.insert(.wrapUp, at: 0) }
            default:
                picks = [.wrapUp] + ([6, 7, 1].contains(weekday) ? [.weekly] : [])
                if chase > 0 && picks.count < 2 { picks.append(.followUps) }
            }
            return Array(picks.filter { !$0.isDone(now: now) }.prefix(2))
        }

        /// The one routine that fits the moment, even if it's been done.
        static func suggested(now: Date, review: Int, chase: Int, unbooked: Int = 0) -> Flow {
            if let first = forNow(now: now, review: review, chase: chase, unbooked: unbooked).first { return first }
            let hour = Calendar.current.component(.hour, from: now)
            return hour < 12 ? .planDay : hour < 17 ? .followUps : .wrapUp
        }

        private var doneKey: String { "routine.\(rawValue).lastDone" }

        /// When this routine was last finished on this device.
        var lastDone: Date? { UserDefaults.standard.object(forKey: doneKey) as? Date }

        func markDone(_ date: Date = Date()) { UserDefaults.standard.set(date, forKey: doneKey) }

        /// Finished today, or this week for the weekly review.
        func isDone(now: Date = Date()) -> Bool {
            guard let last = lastDone else { return false }
            if self == .weekly {
                var calendar = Calendar(identifier: .iso8601)
                calendar.timeZone = .current
                return calendar.isDate(last, equalTo: now, toGranularity: .weekOfYear)
            }
            return Calendar.current.isDate(last, inSameDayAs: now)
        }
    }

    /// The app's main sections: tabs on iPhone, the sidebar picker on the Mac (where the
    /// calendar is always on the right instead).
    enum Place: String, CaseIterable, Identifiable {
        case today, tasks, projects, calendar, routines
        var id: String { rawValue }

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .tasks: "checklist"
            case .projects: "folder"
            case .calendar: "calendar"
            case .routines: "list.bullet.rectangle.portrait"
            }
        }

        static var sidebar: [Place] { [.today, .tasks, .projects, .routines] }
    }

    enum Sheet: Identifiable {
        case newTask
        case newEvent(start: Date? = nil, minutes: Int = 60)
        case blockTime(start: Date? = nil, minutes: Int = 30)
        case voice
        case addTray
        case flow(Flow)
        case board(projectId: String?)
        case settings
        case nudge(taskId: String, channel: Nudge.Channel? = nil)

        var id: String {
            switch self {
            case .newTask: "task"
            case .newEvent(let s, let m): "event-\(s?.timeIntervalSince1970 ?? 0)-\(m)"
            case .blockTime(let s, let m): "block-\(s?.timeIntervalSince1970 ?? 0)-\(m)"
            case .voice: "voice"
            case .addTray: "tray"
            case .flow(let f): "flow-\(f.rawValue)"
            case .board(let id): "board-\(id ?? "all")"
            case .settings: "settings"
            case let .nudge(id, channel): "nudge-\(id)-\(channel?.rawValue ?? "")"
            }
        }
    }

    var sheet: Sheet?

    /// The section on screen. A launch argument like `-PlannerTab routines` lands in
    /// UserDefaults, which is how screenshots and Siri ("What's next") open a specific screen.
    var place: Place = Place(rawValue: UserDefaults.standard.string(forKey: "PlannerTab") ?? "") ?? .today

    func go(_ place: Place) {
        #if os(macOS)
        self.place = place == .calendar ? .today : place
        #else
        self.place = place
        #endif
    }

    func open(_ sheet: Sheet) {
        // Swap sheets cleanly when one opens another (the + tray opening voice).
        if self.sheet != nil {
            self.sheet = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                self.sheet = sheet
            }
        } else {
            self.sheet = sheet
        }
    }
}

/// Presents whatever the router asks for. Attach once, near the root.
struct RouterSheets: ViewModifier {
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        @Bindable var router = router
        content.sheet(item: $router.sheet) { sheet in
            switch sheet {
            case .newTask: NewTaskView()
            case let .newEvent(start, minutes): QuickAddView(kind: .event, start: start, minutes: minutes)
            case let .blockTime(start, minutes): QuickAddView(kind: .task, start: start, minutes: minutes)
            case .voice: VoiceCaptureView()
            case .addTray: AddTray()
            case .flow(let flow): FlowView(flow: flow)
            case .board(let projectId):
                BoardView(projectId: projectId)
                #if os(macOS)
                    .frame(minWidth: 1000, minHeight: 640)
                #endif
            case let .nudge(taskId, channel):
                NudgeSheet(taskId: taskId, channel: channel)
            case .settings:
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { router.sheet = nil } }
                        }
                }
            }
        }
    }
}

extension View {
    func routerSheets() -> some View { modifier(RouterSheets()) }
}

// MARK: - The floating + button (iPhone)

/// Two ink buttons, bottom right: the mic speaks a task or event straight away; the + opens Task,
/// Event, Block time and Speak (press and hold it to speak too).
struct FloatingAddButton: View {
    @Environment(Router.self) private var router
    /// Set by the long press so the tap that ends it doesn't also open the tray.
    @State private var heldForVoice = false

    var body: some View {
        VStack(spacing: 12) {
            Button { router.open(.voice) } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.onInk)
                    .frame(width: 48, height: 48)
                    .background(Color.ink, in: Circle())
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel("Speak")
            .accessibilityHint("Add a task or event by voice")

            Button {
                if heldForVoice {
                    heldForVoice = false
                    return
                }
                router.open(.addTray)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.onInk)
                    .frame(width: 60, height: 60)
                    .background(Color.ink, in: Circle())
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
            .buttonStyle(.pressable(scale: 0.9))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    heldForVoice = true
                    router.open(.voice)
                }
            )
            .accessibilityLabel("Add")
            .accessibilityHint("Opens Task, Event, Block time and Speak. Touch and hold to speak.")
            .accessibilityAction(named: "Speak") { router.open(.voice) }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: router.sheet?.id)
    }
}

/// The small sheet the + opens: four big choices.
struct AddTray: View {
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add").font(.title2.weight(.bold))
            LazyVGrid(columns: columns, spacing: 12) {
                tile("Task", "checklist", .blue) { router.open(.newTask) }
                tile("Event", "calendar.badge.plus", .orange) { router.open(.newEvent()) }
                tile("Block time", "clock.badge.checkmark", .green) { router.open(.blockTime()) }
                tile("Speak", "mic.fill", .pink) { router.open(.voice) }
            }
            Text("Tip: touch and hold + to start speaking. Say a task (“Order kegs by Friday 30 min #jays”) or an event (“Dentist Tuesday 3pm”).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
    }

    private func tile(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title).font(.headline).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .padding(14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toolbar buttons (iPhone and Mac)

/// Add menu and mic in the toolbar, plus the workflows menu where it fits.
struct AddToolbar: ToolbarContent {
    @Environment(Router.self) private var router
    var showFlows = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if showFlows {
                Menu {
                    ForEach(Router.Flow.allCases) { flow in
                        Button { router.open(.flow(flow)) } label: { Label(flow.title, systemImage: flow.symbol) }
                    }
                } label: {
                    Label("Routines", systemImage: "list.bullet.rectangle.portrait")
                }
            }
            Button { router.open(.voice) } label: { Label("Speak", systemImage: "mic") }
                .help("Add a task or event by voice")
            Menu {
                Button { router.open(.newTask) } label: { Label("New Task", systemImage: "checklist") }
                Button { router.open(.newEvent()) } label: { Label("New Event", systemImage: "calendar.badge.plus") }
                Button { router.open(.blockTime()) } label: { Label("Block Time", systemImage: "clock.badge.checkmark") }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("New task, event or block of time")
        }
    }
}

// MARK: - New task

/// A task without booking time: title, project, estimate, due date and repeat.
struct NewTaskView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var projectId: String?
    @State private var priority = 2
    @State private var estimateMin = 30
    @State private var hasDue = false
    @State private var due = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var repeatRule = RepeatDraft(nil, due: nil)
    @State private var notes = ""
    @State private var bookNow = false
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing?", text: $title)
                        .focused($titleFocused)
                        .onSubmit(save)
                    Picker("Project", selection: $projectId) {
                        Text("No project").tag(String?.none)
                        ForEach(model.liveProjects) { Text($0.label).tag(String?.some($0.id)) }
                    }
                    Picker("Priority", selection: $priority) {
                        Text("High").tag(3)
                        Text("Normal").tag(2)
                        Text("Low").tag(1)
                    }
                }
                Section("Timing") {
                    Stepper("Takes \(Format.duration(estimateMin))", value: $estimateMin, in: 5...1440, step: 5)
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue { DatePicker("Due", selection: $due) }
                    Toggle("Find time for it now", isOn: $bookNow)
                }
                RepeatSection(rule: $repeatRule, hasDue: hasDue)
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save).disabled(saving || trimmed.isEmpty)
                }
            }
            .onAppear { titleFocused = true }
            .onChange(of: due) { _, d in
                // Keep the repeat's default day in step with the due date until it's edited.
                if repeatRule.kind == .never { repeatRule = RepeatDraft(nil, due: d) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    private func save() {
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        let draft = TaskDraft(
            title: trimmed,
            notes: notes.isEmpty ? nil : notes,
            priority: priority,
            estimateMin: estimateMin,
            dueAt: hasDue ? due : nil,
            projectId: projectId,
            recurrence: repeatRule.rule
        )
        Task {
            if let task = await model.createTask(draft) {
                if bookNow { await model.scheduleNextFree(task) }
                dismiss()
            }
            saving = false
        }
    }
}
