import PlannerKit
import SwiftUI

/// What matters right now: the current and next block, the rest of today with its free gaps
/// (fill one with a tap), a plan for the rest of the day, follow-ups and what's due.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var openTask: PlannerTask?
    @State private var openEvent: CalEvent?
    @State private var quickAdd: QuickAddRequest?
    @State private var showVoice = false
    @State private var showEarlier = false
    @State private var planning = false

    struct QuickAddRequest: Identifiable {
        let id = UUID()
        var start: Date?
        var minutes = 30
    }

    /// The rest of today in order: events, free gaps and proposed blocks.
    private enum Row: Identifiable {
        case event(CalEvent)
        case gap(AppModel.Gap)
        case proposed(ProposedBlock)

        var id: String {
            switch self {
            case .event(let e): "e:\(e.id)"
            case .gap(let g): "g:\(g.start.timeIntervalSince1970)"
            case .proposed(let p): "p:\(p.id)"
            }
        }

        var start: Date {
            switch self {
            case .event(let e): e.startAt
            case .gap(let g): g.start
            case .proposed(let p): p.startAt
            }
        }
    }

    private func rows(now: Date) -> [Row] {
        let events = model.todayEvents.filter { $0.endAt > now }.map(Row.event)
        let proposed = model.todayProposal.map(Row.proposed)
        // Hide gaps the proposal already fills, so the list doesn't say "free" under a dashed block.
        let gaps = model.todayGaps(now: now).filter { gap in
            !model.todayProposal.contains { $0.startAt < gap.end && $0.endAt > gap.start && $0.endAt.timeIntervalSince($0.startAt) >= gap.end.timeIntervalSince(gap.start) - 60 }
        }.map(Row.gap)
        return (events + proposed + gaps).sorted { $0.start < $1.start }
    }

    var body: some View {
        let now = Date()
        let earlier = model.todayEvents.filter { $0.endAt <= now }
        List {
            Section {
                CaptureBar()
            } header: {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }

            Section {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(spacing: 10) {
                        if let current = model.currentEvent {
                            NowCard(label: "Now", event: current, project: model.projectFor(current), at: context.date)
                                .onTapGesture { openEvent = current }
                        }
                        if let next = model.nextEvent {
                            NowCard(label: "Next", event: next, project: model.projectFor(next), at: context.date)
                                .onTapGesture { openEvent = next }
                        }
                        if model.currentEvent == nil && model.nextEvent == nil {
                            Text("Nothing else on the calendar.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !model.followUpsDue.isEmpty {
                Section("Follow up") {
                    ForEach(model.followUpsDue) { task in
                        Button { openTask = task } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    Text("with \(task.waitingOn ?? "them")").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "arrow.uturn.left.circle").foregroundStyle(.red)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                let items = rows(now: now)
                if items.isEmpty {
                    Text(earlier.isEmpty ? "A clear day." : "Nothing else today.").foregroundStyle(.secondary)
                }
                ForEach(items) { row in
                    switch row {
                    case .event(let event):
                        TimelineRow(event: event, project: model.projectFor(event), tasks: model.tasks(for: event))
                            .contentShape(Rectangle())
                            .onTapGesture { openEvent = event }
                            .modifier(EventSwipes(event: event))
                    case .gap(let gap):
                        GapRow(gap: gap, suggestions: model.suggestions(for: gap)) { task in
                            Task { await model.book(task, at: gap.start, minutes: min(model.remainingMinutes(task), gap.minutes)) }
                        } onAdd: {
                            quickAdd = QuickAddRequest(start: gap.start, minutes: min(60, gap.minutes))
                        }
                    case .proposed(let block):
                        ProposedRow(block: block, project: model.project(id: block.projectId), tasks: (block.taskIds ?? [block.taskId]).compactMap { model.task(id: $0) }) {
                            Task { await model.bookToday([block]) }
                        } onSkip: {
                            model.skipToday(block)
                        }
                    }
                }
                if !earlier.isEmpty {
                    DisclosureGroup("Earlier today (\(earlier.count))", isExpanded: $showEarlier) {
                        ForEach(earlier) { event in
                            TimelineRow(event: event, project: model.projectFor(event), tasks: model.tasks(for: event))
                                .contentShape(Rectangle())
                                .onTapGesture { openEvent = event }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Rest of today")
                    Spacer()
                    if model.todayProposal.count > 1 {
                        Button("Book all \(model.todayProposal.count)") { Task { await model.bookToday(model.todayProposal) } }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }

            if !model.dueToday.isEmpty {
                Section("Due today or overdue") {
                    ForEach(model.dueToday) { task in
                        TaskRow(task: task, nextBlock: model.nextBlock(for: task), onOpen: { openTask = task })
                    }
                }
            }

            if !model.waitingTasks.isEmpty {
                Section("Waiting on others") {
                    ForEach(model.waitingTasks) { task in
                        Button { openTask = task } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                Text([task.waitingOn.map { "Waiting on \($0)" }, task.followUpAt.map { "follow up \(Format.relative($0))" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Today")
        .refreshable { await model.sync() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                Button { showVoice = true } label: { Label("Speak", systemImage: "mic") }
                Button { quickAdd = QuickAddRequest() } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $openTask) { TaskDetailView(task: $0) }
        .sheet(item: $openEvent) { EventDetailView(event: $0) }
        .sheet(item: $quickAdd) { QuickAddView(start: $0.start, minutes: $0.minutes) }
        .sheet(isPresented: $showVoice) { VoiceCaptureView() }
    }
}

/// Swipe actions for Planner's own items; mirrored calendar events stay read-only.
private struct EventSwipes: ViewModifier {
    @Environment(AppModel.self) private var model
    let event: CalEvent

    func body(content: Content) -> some View {
        if event.source == .local {
            content
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if event.isTaskBlock {
                        Button { Task { await model.completeTasks(in: event) } } label: { Label("Done", systemImage: "checkmark") }
                            .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { Task { await model.removeBlock(event) } } label: { Label("Remove", systemImage: "trash") }
                    Button { Task { await model.moveToTomorrow(event) } } label: { Label("Tomorrow", systemImage: "arrow.right.to.line") }
                        .tint(.indigo)
                    Button { Task { await model.push(event, minutes: 15) } } label: { Label("+15m", systemImage: "clock.arrow.circlepath") }
                        .tint(.orange)
                }
        } else {
            content
        }
    }
}

private struct GapRow: View {
    let gap: AppModel.Gap
    let suggestions: [PlannerTask]
    var onBook: (PlannerTask) -> Void
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Format.time(gap.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                Image(systemName: "sparkles").foregroundStyle(.green).font(.caption)
                Text("Free · \(Format.duration(gap.minutes)) until \(Format.time(gap.end))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                Spacer()
                Button("Add…", action: onAdd)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Fits:").font(.caption).foregroundStyle(.secondary)
                        ForEach(suggestions) { task in
                            Button { onBook(task) } label: {
                                Label("\(task.title) · \(Format.duration(task.estimateMin))", systemImage: "plus.circle")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .accessibilityHint("Books it in this free time")
                        }
                    }
                    .padding(.leading, 66)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.green.opacity(0.05))
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

private struct NowCard: View {
    let label: String
    let event: CalEvent
    let project: Project?
    let at: Date

    private var detail: String {
        if event.startAt <= at {
            let left = max(0, Int(event.endAt.timeIntervalSince(at) / 60))
            return "\(Format.duration(left)) left · until \(Format.time(event.endAt))"
        }
        let until = max(0, Int(event.startAt.timeIntervalSince(at) / 60))
        let when = Calendar.current.isDateInToday(event.startAt) ? Format.time(event.startAt) : Format.relative(event.startAt)
        return until < 120 ? "in \(Format.duration(until)) · \(when)" : when
    }

    private var progress: Double? {
        guard event.startAt <= at else { return nil }
        let total = event.endAt.timeIntervalSince(event.startAt)
        return total > 0 ? min(1, at.timeIntervalSince(event.startAt) / total) : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(project.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(event.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress).tint(project.tint)
                }
                if let project { ProjectChip(project: project) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(project.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
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
