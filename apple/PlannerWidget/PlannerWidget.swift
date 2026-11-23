import PlannerKit
import SwiftUI
import WidgetKit

// Home and Lock Screen widgets: what's on now and next. The widget fetches from the server itself
// with the token shared through the Keychain group (no App Group needed).

struct EventSnapshot: Hashable {
    var title: String
    var start: Date
    var end: Date
    var color: ProjectColor?
}

struct PlannerEntry: TimelineEntry {
    let date: Date
    var current: EventSnapshot?
    var upcoming: [EventSnapshot]
    var openTasks: Int
    var followUps: Int
    var problem: String?

    static let sample = PlannerEntry(
        date: .now,
        current: EventSnapshot(title: "Write report", start: .now.addingTimeInterval(-1800), end: .now.addingTimeInterval(3600), color: .indigo),
        upcoming: [
            EventSnapshot(title: "Quick: 3 tasks", start: .now.addingTimeInterval(3600), end: .now.addingTimeInterval(5400), color: .amber),
            EventSnapshot(title: "Gym", start: .now.addingTimeInterval(9000), end: .now.addingTimeInterval(12600), color: .rose),
            EventSnapshot(title: "Call parents", start: .now.addingTimeInterval(14400), end: .now.addingTimeInterval(16200), color: nil),
        ],
        openTasks: 6,
        followUps: 1
    )
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PlannerEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (PlannerEntry) -> Void) {
        if context.isPreview { return completion(.sample) }
        Task { completion(await Self.load().first ?? .sample) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlannerEntry>) -> Void) {
        Task {
            let entries = await Self.load()
            // Refetch every 15 minutes; entries in between roll Now/Next forward without a network call.
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    static func load() async -> [PlannerEntry] {
        let now = Date()
        guard let raw = SharedCredentials.serverURL, let url = URL(string: raw), let token = SharedCredentials.token, !token.isEmpty else {
            return [PlannerEntry(date: now, upcoming: [], openTasks: 0, followUps: 0, problem: "Open Planner to connect")]
        }
        do {
            let state = try await PlannerAPI(baseURL: url, token: token).state()
            let projects = state.projects
            func color(_ e: CalEvent) -> ProjectColor? {
                if let id = e.projectId, let p = projects.first(where: { $0.id == id }) { return p.color }
                let title = e.title.lowercased()
                return projects.first { p in
                    !p.archived && ((p.hostMatch.map { !$0.isEmpty && title.contains($0.lowercased()) } ?? false) || title.hasPrefix(p.name.lowercased()))
                }?.color
            }
            let events = state.events
                .filter { !$0.allDay && $0.endAt > now }
                .sorted { $0.startAt < $1.startAt }
                .prefix(12)
                .map { EventSnapshot(title: $0.title, start: $0.startAt, end: $0.endAt, color: color($0)) }
            let open = state.tasks.filter { $0.status == .todo && !$0.isUpcoming(now: now) }
            let followUps = open.filter { $0.waitingOn != nil }.count

            // One entry now, then one at each start/end in the next few hours.
            let horizon = now.addingTimeInterval(4 * 3600)
            let changes = Set(events.flatMap { [$0.start, $0.end] }.filter { $0 > now && $0 < horizon })
            return ([now] + changes.sorted()).map { at in
                PlannerEntry(
                    date: at,
                    current: events.last { $0.start <= at && $0.end > at },
                    upcoming: Array(events.filter { $0.start > at }.prefix(3)),
                    openTasks: open.count,
                    followUps: followUps
                )
            }
        } catch {
            return [PlannerEntry(date: now, upcoming: [], openTasks: 0, followUps: 0, problem: "Can't reach Planner")]
        }
    }
}

// MARK: - Views

private func projectTint(_ c: ProjectColor?) -> Color { c?.color ?? .accentColor }

private func untilText(_ e: EventSnapshot, at now: Date) -> String {
    e.start <= now ? "until \(Format.time(e.end))" : Format.relative(e.start)
}

struct SmallView: View {
    let entry: PlannerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = entry.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption)
            } else if let e = entry.current ?? entry.upcoming.first {
                Text(entry.current != nil ? "NOW" : "NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(projectTint(e.color))
                Text(e.title)
                    .font(.headline)
                    .lineLimit(3)
                Text(untilText(e, at: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if entry.current != nil, let next = entry.upcoming.first {
                    Text("Then \(next.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Clear").font(.headline)
                Text("\(entry.openTasks) open tasks").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MediumView: View {
    let entry: PlannerEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SmallView(entry: PlannerEntry(date: entry.date, current: entry.current, upcoming: Array(entry.upcoming.prefix(entry.current == nil ? 1 : 0)), openTasks: entry.openTasks, followUps: entry.followUps, problem: entry.problem))
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.upcoming.dropFirst(entry.current == nil ? 1 : 0).prefix(3), id: \.self) { e in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(projectTint(e.color)).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(Format.time(e.start)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Label("\(entry.openTasks)", systemImage: "checklist")
                    if entry.followUps > 0 {
                        Label("\(entry.followUps)", systemImage: "arrow.uturn.left").foregroundStyle(.red)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RectangularView: View {
    let entry: PlannerEntry

    var body: some View {
        if let e = entry.current ?? entry.upcoming.first {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.current != nil ? "Now" : "Next").font(.caption2.weight(.semibold)).widgetAccentable()
                Text(e.title).font(.headline).lineLimit(1)
                Text(untilText(e, at: entry.date)).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.problem ?? "Nothing scheduled").font(.caption)
        }
    }
}

struct PlannerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlannerEntry

    var body: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline:
            if let e = entry.current ?? entry.upcoming.first {
                Text("\(entry.current != nil ? "Now" : "Next"): \(e.title) · \(Format.time(entry.current != nil ? e.end : e.start))")
            } else {
                Text("Planner: clear")
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "checklist").font(.caption2)
                    Text("\(entry.openTasks)").font(.headline)
                }
            }
        default: SmallView(entry: entry)
        }
    }
}

struct PlannerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PlannerNowNext", provider: Provider()) { entry in
            PlannerWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now & Next")
        .description("What you're doing now and what's coming up.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

@main
struct PlannerWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlannerWidget()
    }
}
