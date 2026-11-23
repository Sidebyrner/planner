import PlannerKit
import SwiftUI

/// What matters right now: the current and next block, today's timeline, what's due and who to chase.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var openTask: PlannerTask?
    @State private var showEarlier = false

    var body: some View {
        let now = Date()
        let earlier = model.todayEvents.filter { $0.endAt <= now }
        let later = model.todayEvents.filter { $0.endAt > now }
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
                        if let now = model.currentEvent {
                            NowCard(label: "Now", event: now, project: model.projectFor(now), at: context.date)
                        }
                        if let next = model.nextEvent {
                            NowCard(label: "Next", event: next, project: model.projectFor(next), at: context.date)
                        }
                        if model.currentEvent == nil && model.nextEvent == nil {
                            Text("Nothing else on the calendar. Press Plan to book time for open tasks.")
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

            if !model.dueToday.isEmpty {
                Section("Due today or overdue") {
                    ForEach(model.dueToday) { task in
                        TaskRow(task: task, nextBlock: model.nextBlock(for: task), onOpen: { openTask = task })
                    }
                }
            }

            Section("Rest of today") {
                if later.isEmpty {
                    Text(earlier.isEmpty ? "A clear day." : "Nothing else today.").foregroundStyle(.secondary)
                }
                ForEach(later) { event in
                    TimelineRow(event: event, project: model.projectFor(event), tasks: model.tasks(for: event))
                }
                if !earlier.isEmpty {
                    DisclosureGroup("Earlier today (\(earlier.count))", isExpanded: $showEarlier) {
                        ForEach(earlier) { event in
                            TimelineRow(event: event, project: model.projectFor(event), tasks: model.tasks(for: event))
                        }
                    }
                    .foregroundStyle(.secondary)
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
        .sheet(item: $openTask) { task in
            TaskDetailView(task: task)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(project.tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(event.title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                if let project { ProjectChip(project: project) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(project.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
