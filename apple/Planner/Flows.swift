import PlannerKit
import SwiftUI

/// Opens one of the guided workflows.
struct FlowView: View {
    let flow: Router.Flow

    var body: some View {
        Group {
            switch flow {
            case .planDay: PlanDayFlow()
            case .wrapUp: WrapUpFlow()
            case .followUps: FollowUpRoundFlow()
            case .weekly: WeeklyReviewFlow()
            case .board: BoardView()
            }
        }
        #if os(macOS)
        .frame(minWidth: flow == .board ? 1000 : 560, minHeight: flow == .board ? 640 : 620)
        #endif
    }
}

// MARK: - Shared step frame

/// Steps with a progress bar, a title per step, and Back / Next / Done along the bottom.
///
/// The parent builds `content` and `nextLabel` in its own body, so they always reflect its
/// current state. (A closure called later from here would read a stale copy of it.)
struct StepFlow<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let title: String
    /// Stamped as done when the last step is finished.
    var flow: Router.Flow?
    let steps: [String]
    @Binding var step: Int
    var nextLabel: String
    var onNext: (Int) async -> Bool
    let content: Content
    @State private var working = false
    @State private var celebrating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String, flow: Router.Flow? = nil, steps: [String], step: Binding<Int>, nextLabel: String = "Next",
        onNext: @escaping (Int) async -> Bool = { _ in true }, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.flow = flow
        self.steps = steps
        _step = step
        self.nextLabel = nextLabel
        self.onNext = onNext
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(steps.indices, id: \.self) { i in
                            Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 4)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Step \(step + 1) of \(steps.count)")
                    Text(steps[step]).font(.title.weight(.bold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                ScrollView {
                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.pageBackground)

                // Errors show here: the app-wide alert can't appear over a sheet.
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .onTapGesture { model.actionError = nil }
                }

                HStack {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 } }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    Spacer()
                    Button {
                        working = true
                        Task {
                            let go = await onNext(step)
                            working = false
                            guard go else { return }
                            if step == steps.count - 1 {
                                flow?.markDone()
                                withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.4)) { celebrating = true }
                                try? await Task.sleep(for: .milliseconds(reduceMotion ? 500 : 1100))
                                dismiss()
                            } else { withAnimation { step += 1 } }
                        }
                    } label: {
                        if working { ProgressView().frame(minWidth: 120) } else {
                            Text(step == steps.count - 1 ? "Done" : nextLabel).frame(minWidth: 120)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(.bar)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .overlay {
                if celebrating { Celebration(title: "\(title) done") }
            }
            .sensoryFeedback(.success, trigger: celebrating)
        }
    }
}

/// A short "done" moment when a routine finishes.
struct Celebration: View {
    let title: String
    @State private var pop = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundStyle(.white, Color.green.gradient)
                    .scaleEffect(pop ? 1 : 0.3)
                    .rotationEffect(.degrees(pop ? 0 : -30))
                Text(title).font(.title2.weight(.bold))
                    .opacity(pop ? 1 : 0)
                    .offset(y: pop ? 0 : 12)
            }
        }
        .transition(.opacity)
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.5)) { pop = true } }
        .accessibilityElement(children: .combine)
    }
}

/// A grey hint when a step has nothing in it.
private struct AllClear: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.seal")
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

/// An open task with Today / Tomorrow / Done buttons, for leftovers.
private struct LeftoverRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    var todayLabel = "Today"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title).font(.body.weight(.medium))
                if task.repeats { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if let due = task.dueAt {
                    Text(Format.relative(due)).font(.caption).foregroundStyle(due < Date() ? .red : .secondary)
                }
            }
            HStack(spacing: 6) {
                Button(todayLabel) { Task { await model.scheduleNextFree(task) } }
                Button("Tomorrow") { Task { await model.pushDue(task, days: 1) } }
                Button("Next week") { Task { await model.pushDue(task, days: 7) } }
                Spacer()
                Button { Task { await model.toggleDone(task) } } label: { Label("Done", systemImage: "checkmark") }
                    .tint(.green)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .font(.caption.weight(.semibold))
        }
    }
}

// MARK: - Plan my day

struct PlanDayFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var picked: [String] = []
    @State private var proposal: ScheduleProposal?
    @State private var keep: Set<String> = []
    @State private var booked = 0

    private static let maxPicks = 3

    var body: some View {
        StepFlow(
            title: "Plan My Day",
            flow: .planDay,
            steps: ["Clear leftovers", "Pick your top \(Self.maxPicks)", "Fit them in", "You're set"],
            step: $step,
            nextLabel: nextLabel,
            onNext: next
        ) {
            switch step {
            case 0: leftovers
            case 1: pick
            case 2: fit
            default: summary
            }
        }
    }

    private var nextLabel: String {
        switch step {
        case 1: picked.isEmpty ? "Skip" : "Find time"
        case 2: keep.isEmpty ? "Skip" : "Book \(keep.count)"
        default: "Next"
        }
    }

    private func next(_ i: Int) async -> Bool {
        switch i {
        case 1:
            guard !picked.isEmpty else { proposal = nil; keep = []; return true }
            let result = await model.propose(taskIds: picked)
            proposal = result
            keep = Set(result?.blocks.map(\.id) ?? [])
            return true
        case 2:
            let blocks = proposal?.blocks.filter { keep.contains($0.id) } ?? []
            if !blocks.isEmpty {
                await model.book(blocks)
                booked = blocks.count
            }
            return true
        default:
            return true
        }
    }

    @ViewBuilder private var leftovers: some View {
        let review = model.blocksToReview(days: 3)
        let overdue = model.overdue
        VStack(alignment: .leading, spacing: 16) {
            Text("First, what didn't get finished. Mark old blocks, then move or finish what's overdue.")
                .foregroundStyle(.secondary)
            Card(title: "Blocks to check off", symbol: "checkmark.circle", tint: .green) {
                if review.isEmpty { AllClear(text: "Nothing to check off.") }
                ForEach(review) { BlockReviewRow(block: $0) }
            }
            Card(title: "Overdue", symbol: "exclamationmark.circle", tint: .red) {
                if overdue.isEmpty { AllClear(text: "Nothing overdue.") }
                ForEach(overdue) { task in
                    LeftoverRow(task: task)
                    if task.id != overdue.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder private var pick: some View {
        let candidates = Array(model.topCandidates.prefix(20))
        VStack(alignment: .leading, spacing: 16) {
            Text("What would make today a good day? Pick up to \(Self.maxPicks). Due soonest is at the top.")
                .foregroundStyle(.secondary)
            Card {
                if candidates.isEmpty { AllClear(text: "No open tasks. Add one with +.") }
                ForEach(candidates) { task in
                    let on = picked.contains(task.id)
                    Button {
                        if on { picked.removeAll { $0 == task.id } } else if picked.count < Self.maxPicks { picked.append(task.id) }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 2)
                                    .background(on ? Color.accentColor : .clear, in: Circle())
                                if let n = picked.firstIndex(of: task.id) {
                                    Text("\(n + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).foregroundStyle(.primary)
                                Text([Format.duration(model.remainingMinutes(task)), model.project(id: task.projectId)?.name, task.dueAt.map { "due \(Format.relative($0))" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .opacity(!on && picked.count >= Self.maxPicks ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var fit: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Today", symbol: "calendar.day.timeline.left") { DayStrip() }
            if let proposal, !proposal.blocks.isEmpty {
                Card(title: "Proposed blocks", symbol: "wand.and.stars") {
                    ForEach(proposal.blocks) { block in
                        let on = keep.contains(block.id)
                        Toggle(isOn: Binding(get: { on }, set: { if $0 { keep.insert(block.id) } else { keep.remove(block.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block.title)
                                Text("\(Format.relative(block.startAt))–\(Format.time(block.endAt))\(Calendar.current.isDateInToday(block.startAt) ? "" : " · not today")\(block.late ? " · ends after it's due" : "")")
                                    .font(.caption)
                                    .foregroundStyle(block.late || !Calendar.current.isDateInToday(block.startAt) ? .orange : .secondary)
                            }
                        }
                    }
                }
                if !proposal.unscheduled.isEmpty {
                    Label("No room for \(proposal.unscheduled.map(\.title).joined(separator: ", ")) in the planning window.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else {
                AllClear(text: picked.isEmpty ? "Nothing picked; you can still fill free time from Today." : "Those already have time booked.")
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let first = model.blocks(on: Date()).first { $0.endAt > Date() }
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sun.max.fill").font(.system(size: 54)).foregroundStyle(.orange)
            Text(booked > 0 ? "Booked \(booked) block\(booked == 1 ? "" : "s")." : "Your day is set.").font(.title2.weight(.semibold))
            if let first {
                Card(title: "First up", symbol: "play.circle") {
                    Text(first.title).font(.headline)
                    Text("\(Format.time(first.startAt))–\(Format.time(first.endAt))").foregroundStyle(.secondary)
                }
            }
            let chores = model.choresDue.count
            if chores > 0 {
                Label("\(chores) chore\(chores == 1 ? "" : "s") or bill\(chores == 1 ? "" : "s") due today. They're on Today.", systemImage: "checklist")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Wrap up the day

struct WrapUpFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var step = 0

    var body: some View {
        StepFlow(title: "Wrap Up", flow: .wrapUp, steps: ["How did today go?", "Still open", "Loose ends", "Tomorrow"], step: $step) {
            switch step {
            case 0: blocks
            case 1: stillOpen
            case 2: looseEnds
            default: tomorrow
            }
        }
    }

    @ViewBuilder private var blocks: some View {
        let today = model.blocks(on: Date()).filter { $0.startAt <= Date() }
        let earlier = model.blocksToReview(days: 3).filter { !Calendar.current.isDateInToday($0.startAt) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Mark each block. Done counts the time against the task; Missed sends the work back to be planned.")
                .foregroundStyle(.secondary)
            Card(title: "Today's blocks", symbol: "checkmark.circle", tint: .green) {
                if today.isEmpty { AllClear(text: "No blocks today.") }
                ForEach(today) { BlockReviewRow(block: $0) }
            }
            if !earlier.isEmpty {
                Card(title: "From before", symbol: "clock.arrow.circlepath", tint: .orange) {
                    ForEach(earlier) { BlockReviewRow(block: $0) }
                }
            }
        }
    }

    @ViewBuilder private var stillOpen: some View {
        let due = model.due(by: Date())
        VStack(alignment: .leading, spacing: 16) {
            Text("Due today and not done. Finish it, find it time, or move the date.").foregroundStyle(.secondary)
            Card {
                if due.isEmpty { AllClear(text: "Everything due today is done.") }
                ForEach(due) { task in
                    LeftoverRow(task: task, todayLabel: "Find time")
                    if task.id != due.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder private var looseEnds: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Anything still on your mind? Get it out of your head and into Planner.").foregroundStyle(.secondary)
            Card { StandaloneCaptureBar() }
            HStack {
                Button { router.open(.voice) } label: { Label("Speak it", systemImage: "mic.fill").frame(maxWidth: .infinity) }
                Button { router.open(.newTask) } label: { Label("New task", systemImage: "checklist").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    @ViewBuilder private var tomorrow: some View {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let events = (model.state?.events ?? []).filter { !$0.allDay && !$0.ignored && Calendar.current.isDate($0.startAt, inSameDayAs: day) }
            .sorted { $0.startAt < $1.startAt }
        let due = model.due(by: day).filter { !Calendar.current.isDateInToday($0.dueAt ?? .distantPast) && ($0.dueAt ?? .distantPast) > Date() }
        VStack(alignment: .leading, spacing: 16) {
            Card(title: day.formatted(.dateTime.weekday(.wide)), symbol: "moon.stars") {
                if events.isEmpty { AllClear(text: "Nothing on the calendar yet.") }
                ForEach(events.prefix(8)) { event in
                    HStack {
                        Text(Format.time(event.startAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(event.title).lineLimit(1)
                    }
                }
            }
            if !due.isEmpty {
                Card(title: "Due tomorrow", symbol: "flag") {
                    ForEach(due) { Text($0.title) }
                }
            }
            Text("Tomorrow morning, start with Plan My Day.").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Follow-up round

/// One follow-up at a time: chase them, mark it come through, or come back later.
struct FollowUpRoundFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var nudging: String?
    @State private var queue: [String] = []
    @State private var index = 0
    @State private var handled = 0
    @State private var started = false

    private var current: PlannerTask? { index < queue.count ? model.task(id: queue[index]) : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !queue.isEmpty {
                    ProgressView(value: Double(min(index, queue.count)), total: Double(queue.count))
                        .accessibilityLabel("\(min(index, queue.count)) of \(queue.count) done")
                }
                if let task = current {
                    card(task)
                    Spacer(minLength: 0)
                    actions(task)
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                    Text(queue.isEmpty ? "Nobody to chase right now." : "Round done. \(handled) handled.")
                        .font(.title2.weight(.semibold))
                    let waiting = model.people.reduce(0) { $0 + $1.pending.count }
                    if waiting > 0 {
                        Text("Still waiting on \(waiting) thing\(waiting == 1 ? "" : "s"); they'll come back on their follow-up dates.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Spacer()
                    Button("Done") {
                        if !queue.isEmpty { Router.Flow.followUps.markDone() }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(20)
            .background(Color.pageBackground)
            .navigationTitle(queue.isEmpty ? "Follow-ups" : "Follow-up \(min(index + 1, queue.count)) of \(queue.count)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: Binding(get: { nudging.map(IdentifiedString.init) }, set: { nudging = $0?.id })) { item in
                NudgeSheet(taskId: item.id) {
                    // Sent: count it and move to the next person once the sheet closes.
                    handled += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        nudging = nil
                        withAnimation(.planner) { index += 1 }
                    }
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                queue = model.people.flatMap { $0.due.map(\.id) }
            }
        }
    }

    private func card(_ task: PlannerTask) -> some View {
        let person = model.people.first { $0.id == (task.waitingOn ?? "").lowercased() }
        let contact = task.contact ?? person?.contact
        return Card {
            HStack(spacing: 12) {
                Text(String((task.waitingOn ?? "?").prefix(1)).uppercased())
                    .font(.title2.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.indigo.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.waitingOn ?? "Someone").font(.title3.weight(.semibold))
                    if let p = model.project(id: task.projectId) { ProjectChip(project: p) }
                }
                Spacer()
            }
            Text(task.title).font(.title2.weight(.bold))
            Text([
                "Waiting since \(task.createdAt.formatted(.dateTime.month().day()))",
                task.followUpAt.map { "follow-up was \(Format.relative($0))" },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            if !task.notes.isEmpty { Text(task.notes).font(.callout) }
            ForEach(task.links) { link in
                if let url = link.destination {
                    Link(destination: url) { Label(link.label, systemImage: TaskLinkIcon.name(for: url)) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Draft").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(Nudge.text(for: task)).font(.callout).italic()
                Button { nudging = task.id } label: {
                    Label(contact?.phone != nil || contact?.email != nil ? "Edit & Send Nudge" : "Edit & Copy Nudge", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)
            }
        }
    }

    private func actions(_ task: PlannerTask) -> some View {
        VStack(spacing: 10) {
            Button { act { await model.gotIt(task) } } label: {
                Label("They came through", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            HStack {
                Button { act { await model.snooze(task, days: 2) } } label: { Text("Chased · 2 days").frame(maxWidth: .infinity) }
                Button { act { await model.snooze(task, days: 7) } } label: { Text("Chased · a week").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            Button("Skip for now") { withAnimation { index += 1 } }
                .buttonStyle(.borderless)
        }
        .controlSize(.large)
    }

    private func act(_ work: @escaping () async -> Void) {
        Task {
            await work()
            handled += 1
            withAnimation { index += 1 }
        }
    }
}

// MARK: - Weekly review

struct WeeklyReviewFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var proposal: ScheduleProposal?
    @State private var keep: Set<String> = []
    @State private var openTask: PlannerTask?

    var body: some View {
        StepFlow(
            title: "Weekly Review",
            flow: .weekly,
            steps: ["How the week went", "Overdue", "Waiting on", "Next week"],
            step: $step,
            nextLabel: step == 2 ? "Plan next week" : "Next",
            onNext: { i in
                if i == 2 {
                    let ids = model.openTasks.map(\.id)
                    proposal = ids.isEmpty ? nil : await model.propose(taskIds: ids)
                    let weekOut = Date().addingTimeInterval(8 * 86_400)
                    keep = Set(proposal?.blocks.filter { $0.startAt < weekOut }.map(\.id) ?? [])
                }
                if i == 3 {
                    let blocks = proposal?.blocks.filter { keep.contains($0.id) } ?? []
                    if !blocks.isEmpty { await model.book(blocks) }
                }
                return true
            }
        ) {
            switch step {
            case 0: week
            case 1: overdue
            case 2: waiting
            default: nextWeek
            }
        }
        .sheet(item: $openTask) { TaskDetailView(task: $0) }
    }

    @ViewBuilder private var week: some View {
        let insights = model.insights()
        VStack(alignment: .leading, spacing: 16) {
            Text(insights.total == 0 ? "Nothing ticked off yet this week." : "You finished \(insights.total) task\(insights.total == 1 ? "" : "s") since Monday.")
                .font(.title3.weight(.semibold))
            InsightsSummary(insights: insights)
        }
    }

    @ViewBuilder private var overdue: some View {
        let items = model.overdue
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear the decks: finish, find time, or move each one.").foregroundStyle(.secondary)
            Card {
                if items.isEmpty { AllClear(text: "Nothing overdue.") }
                ForEach(items) { task in
                    LeftoverRow(task: task, todayLabel: "Find time")
                    if task.id != items.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        let people = model.people
        VStack(alignment: .leading, spacing: 16) {
            Text("Everyone you're waiting on. Chase anyone who's late.").foregroundStyle(.secondary)
            if people.isEmpty { AllClear(text: "Not waiting on anyone.") }
            ForEach(people) { person in
                Card {
                    PersonCard(person: person) { openTask = $0 }
                    ForEach(person.pending) { task in
                        HStack {
                            Text(task.title).font(.callout)
                            Spacer()
                            if let f = task.followUpAt { Text("check \(Format.relative(f))").font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.leading, 44)
                        .contentShape(Rectangle())
                        .onTapGesture { openTask = task }
                    }
                }
            }
        }
    }

    @ViewBuilder private var nextWeek: some View {
        let blocks = proposal?.blocks ?? []
        VStack(alignment: .leading, spacing: 16) {
            Text("Proposed time for your open tasks over the next week. Untick anything you don't want booked.")
                .foregroundStyle(.secondary)
            Card {
                if blocks.isEmpty { AllClear(text: "Every open task already has time booked.") }
                ForEach(blocks) { block in
                    Toggle(isOn: Binding(get: { keep.contains(block.id) }, set: { if $0 { keep.insert(block.id) } else { keep.remove(block.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.title)
                            Text("\(Format.relative(block.startAt))–\(Format.time(block.endAt))\(block.outsideWindow == true ? " · outside its project's hours" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !keep.isEmpty {
                Text("Tap Done to book \(keep.count) block\(keep.count == 1 ? "" : "s").").font(.callout.weight(.semibold))
            }
        }
    }
}

// MARK: - Task board

/// Every task in a column by status. Drag a card to another column, or use its menu.
struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectId: String?
    @State private var openTask: PlannerTask?
    @State private var askWho: PlannerTask?
    @State private var who = ""
    @State private var target: AppModel.BoardColumn?

    init(projectId: String? = nil) {
        _projectId = State(initialValue: projectId)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(AppModel.BoardColumn.allCases) { column in
                        columnView(column)
                    }
                }
                .scrollTargetLayout()
                .padding(16)
            }
            // On a phone, a swipe lands on the next column instead of halfway.
            .scrollTargetBehavior(.viewAligned)
            .background(Color.pageBackground)
            .navigationTitle("Board")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Project", selection: $projectId) {
                        Text("All projects").tag(String?.none)
                        ForEach(model.liveProjects) { Text($0.label).tag(String?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                }
            }
            .sheet(item: $openTask) { TaskDetailView(task: $0) }
            .alert("Waiting on who?", isPresented: Binding(get: { askWho != nil }, set: { if !$0 { askWho = nil } })) {
                TextField("Name", text: $who)
                Button("Cancel", role: .cancel) { askWho = nil }
                Button("Move") {
                    if let task = askWho { Task { await model.move(task, to: .waiting, waitingOn: who) } }
                    askWho = nil
                }
            } message: {
                Text("It comes back to To do on its follow-up date.")
            }
        }
    }

    private func columnView(_ column: AppModel.BoardColumn) -> some View {
        let tasks = model.board(column, projectId: projectId)
        let highlighted = target == column
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(column.rawValue, systemImage: column.symbol).font(.headline)
                Spacer()
                Text("\(tasks.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        BoardCard(task: task, column: column)
                            .onTapGesture { openTask = task }
                            .draggable(task.id)
                            .contextMenu {
                                ForEach(AppModel.BoardColumn.allCases.filter { $0 != column }) { other in
                                    Button { drop(task, on: other) } label: { Label("Move to \(other.rawValue)", systemImage: other.symbol) }
                                }
                            }
                    }
                    if tasks.isEmpty {
                        Text(column == .done ? "Nothing finished this week yet." : "Drop tasks here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids { if let task = model.task(id: id) { drop(task, on: column) } }
            return true
        } isTargeted: { on in
            target = on ? column : (target == column ? nil : target)
        }
    }

    private func drop(_ task: PlannerTask, on column: AppModel.BoardColumn) {
        if column == .waiting && (task.waitingOn ?? "").isEmpty {
            who = ""
            askWho = task
        } else {
            Task { await model.move(task, to: column) }
        }
    }
}

private struct BoardCard: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    let column: AppModel.BoardColumn

    var body: some View {
        let project = model.project(id: task.projectId)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title).font(.subheadline.weight(.semibold)).strikethrough(task.isDone).lineLimit(3)
                Spacer(minLength: 4)
                if task.repeats { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                if let project { ProjectChip(project: project) }
                switch column {
                case .scheduled:
                    if let block = model.nextBlock(for: task) { Label(Format.relative(block.startAt), systemImage: "calendar") }
                case .waiting:
                    if let who = task.waitingOn { Label(who, systemImage: "person") }
                case .todo:
                    if let who = task.waitingOn {
                        Label("Chase \(who)", systemImage: "arrow.uturn.left").foregroundStyle(.red)
                    } else if let due = task.dueAt {
                        Label(Format.relative(due), systemImage: "flag").foregroundStyle(due < Date() ? .red : .secondary)
                    }
                case .done:
                    if let at = task.completedAt { Label(Format.relative(at), systemImage: "checkmark") }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if let progress = task.checklistProgress {
                Label(progress, systemImage: "checklist").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pageBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(project.tint).frame(width: 3).padding(.vertical, 8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Touch and hold to move it to another column")
    }
}

/// A string usable with `.sheet(item:)`.
struct IdentifiedString: Identifiable { let id: String }
