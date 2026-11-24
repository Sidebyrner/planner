import PlannerKit
import SwiftUI

/// Today, built around how the day actually runs: the block you're in and its next step, the
/// whole day at a glance with free time to fill, what fits the window you're in (your shift
/// included), chores and bills to tick off, and who you're waiting on.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var openTask: PlannerTask?
    @State private var openEvent: CalEvent?
    @State private var showLater = false
    @State private var planning = false

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96) // room above the floating + button
        }
        .background(Color.pageBackground)
        .navigationTitle("Today")
        .refreshable { await model.sync() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    planning = true
                    Task {
                        await model.planRestOfToday()
                        planning = false
                    }
                } label: {
                    if planning { ProgressView() } else { Label("Plan the rest of today", systemImage: "wand.and.stars") }
                }
                .disabled(planning)
                .help("Propose blocks for open tasks in today's free time")
            }
            AddToolbar(showFlows: true)
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button { router.open(.settings) } label: { Label("Settings", systemImage: "gear") }
            }
            #endif
        }
        .sheet(item: $openTask) { TaskDetailView(task: $0) }
        .sheet(item: $openEvent) { EventDetailView(event: $0) }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let review = model.blocksToReview()
        let chores = model.choresDue
        let other = model.otherDueToday
        let people = model.people.filter { !$0.due.isEmpty }
        let waitingCount = model.people.reduce(0) { $0 + $1.pending.count }
        let later = model.todayEvents.filter { $0.startAt > now }

        VStack(alignment: .leading, spacing: 16) {
            header(now: now, chores: chores.count + other.count, people: people.count)

            RoutineStrip(now: now, review: review.count, chase: people.reduce(0) { $0 + $1.due.count })

            NowCard { openEvent = $0 }

            Card(title: "Your day", symbol: "calendar.day.timeline.left") {
                DayStrip(
                    onGap: { gap in router.open(.blockTime(start: gap.start, minutes: min(60, gap.minutes))) },
                    onEvent: { openEvent = $0 }
                )
                Text("Tap a green stretch to fill it.").font(.caption).foregroundStyle(.secondary)
            }

            if let window = model.currentWindow(now: now) {
                WindowCard(window: window)
            }

            if !model.todayProposal.isEmpty {
                Card(title: "Proposed for today", symbol: "wand.and.stars", accessory: {
                    if model.todayProposal.count > 1 {
                        Button("Book all") { Task { await model.bookToday(model.todayProposal) } }
                            .font(.caption.weight(.semibold))
                    }
                }) {
                    ForEach(model.todayProposal) { block in
                        ProposedRow(block: block, project: model.project(id: block.projectId), tasks: (block.taskIds ?? [block.taskId]).compactMap { model.task(id: $0) }) {
                            Task { await model.bookToday([block]) }
                        } onSkip: {
                            model.skipToday(block)
                        }
                    }
                }
            }

            if !review.isEmpty {
                Card(title: "Did these happen?", symbol: "checkmark.circle", tint: .green) {
                    ForEach(review.prefix(4)) { BlockReviewRow(block: $0) }
                    if review.count > 4 {
                        Button("Check off all \(review.count)") { router.open(.flow(.wrapUp)) }.font(.callout)
                    }
                }
            }

            if !chores.isEmpty || !other.isEmpty {
                Card(title: chores.isEmpty ? "Due today" : "Chores & bills", symbol: "checklist.checked", tint: .teal) {
                    ForEach(chores) { task in ChoreRow(task: task) { openTask = task } }
                    if !chores.isEmpty && !other.isEmpty { Divider() }
                    ForEach(other) { task in ChoreRow(task: task) { openTask = task } }
                }
            }

            if !people.isEmpty || waitingCount > 0 {
                Card(title: "Follow-ups", symbol: "person.2", tint: .indigo, accessory: {
                    if !people.isEmpty {
                        Button("Start round") { router.open(.flow(.followUps)) }.font(.caption.weight(.semibold))
                    }
                }) {
                    if people.isEmpty {
                        Text("Waiting on \(waitingCount) thing\(waitingCount == 1 ? "" : "s"); nothing to chase yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(people) { person in
                        PersonCard(person: person) { openTask = $0 }
                        if person.id != people.last?.id { Divider() }
                    }
                }
            }

            if !later.isEmpty {
                Card {
                    DisclosureGroup(isExpanded: $showLater) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(later) { event in
                                TimelineRow(event: event, project: model.projectFor(event), tasks: model.tasks(for: event))
                                    .contentShape(Rectangle())
                                    .onTapGesture { openEvent = event }
                                    .contextMenu { EventActions(event: event) }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Later today (\(later.count))", systemImage: "list.bullet").font(.headline).foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func header(now: Date, chores: Int, people: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(greeting(now))
                .font(.title2.weight(.bold))
            let parts = [
                model.todayEvents.filter { $0.endAt > now && !$0.ignored }.count.nonZero { "\($0) on the calendar" },
                chores.nonZero { "\($0) due" },
                people.nonZero { "\($0) to chase" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func greeting(_ now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case ..<12: "Good morning"
        case ..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}

private extension Int {
    func nonZero(_ text: (Int) -> String) -> String? { self > 0 ? text(self) : nil }
}

/// The routines, with the one that fits the time of day first and highlighted.
private struct RoutineStrip: View {
    @Environment(Router.self) private var router
    let now: Date
    let review: Int
    let chase: Int

    private var suggested: Router.Flow { .suggested(now: now, review: review, chase: chase) }

    var body: some View {
        let order = [suggested] + Router.Flow.allCases.filter { $0 != suggested }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(order) { flow in
                    let featured = flow == suggested
                    Button { router.open(.flow(flow)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: flow.symbol).font(.headline)
                                Spacer(minLength: 0)
                                if let badge = badge(flow) {
                                    Text("\(badge)").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(featured ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(flow.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(flow.blurb).font(.caption2).lineLimit(2).opacity(0.8)
                        }
                        .foregroundStyle(featured ? Color.white : Color.primary)
                        .padding(12)
                        .frame(width: 150, height: 104, alignment: .topLeading)
                        .background(featured ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.cardBackground),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(flow.blurb)
                }
                Button { router.go(.routines) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2").font(.headline)
                        Text("All routines").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 96, height: 104)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .scrollClipDisabled()
    }

    private func badge(_ flow: Router.Flow) -> Int? {
        switch flow {
        case .wrapUp: review > 0 ? review : nil
        case .followUps: chase > 0 ? chase : nil
        default: nil
        }
    }
}

/// Move, push or remove one of Planner's own blocks (long-press menu).
private struct EventActions: View {
    @Environment(AppModel.self) private var model
    let event: CalEvent

    var body: some View {
        if event.source == .local {
            if event.isTaskBlock {
                Button { Task { await model.completeTasks(in: event) } } label: { Label("Done", systemImage: "checkmark") }
            }
            Button { Task { await model.push(event, minutes: 15) } } label: { Label("Push 15 min", systemImage: "clock.arrow.circlepath") }
            Button { Task { await model.moveToTomorrow(event) } } label: { Label("Move to Tomorrow", systemImage: "arrow.right.to.line") }
            Button(role: .destructive) { Task { await model.removeBlock(event) } } label: { Label("Remove", systemImage: "trash") }
        }
    }
}

private struct ProposedRow: View {
    let block: ProposedBlock
    let project: Project?
    let tasks: [PlannerTask]
    var onBook: () -> Void
    var onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Format.time(block.startAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(project.tint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title).fontWeight(.semibold)
                Text([
                    "Proposed · until \(Format.time(block.endAt))",
                    block.isBatch ? tasks.map(\.title).joined(separator: ", ") : nil,
                    block.late ? "ends after it's due" : nil,
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(block.late ? .orange : .secondary)
            }
            Spacer()
            Button("Skip", action: onSkip).font(.caption).buttonStyle(.borderless)
            Button("Book", action: onBook)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .listRowBackground(project.tint.opacity(0.06))
    }
}

private struct TimelineRow: View {
    let event: CalEvent
    let project: Project?
    let tasks: [PlannerTask]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Format.time(event.startAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(project?.color.color ?? (event.isTaskBlock ? Color.accentColor : .gray))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).fontWeight(event.isTaskBlock ? .semibold : .regular)
                if event.isBatch {
                    Text(tasks.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Text("until \(Format.time(event.endAt))").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .opacity(event.endAt < Date() ? 0.5 : 1)
    }
}
