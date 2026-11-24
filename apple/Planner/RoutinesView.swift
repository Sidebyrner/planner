import PlannerKit
import SwiftUI

/// All the routines in one place: the one that fits right now up top, then each with what's
/// waiting for it and whether you've done it today.
struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            // Re-reads "done today" each minute and whenever a routine sheet closes.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
            .id(router.sheet?.id ?? "none")
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96) // room above the floating + button
        }
        .background(Color.pageBackground)
        .navigationTitle("Routines")
        .refreshable { await model.sync() }
        .toolbar { AddToolbar() }
    }

    private func content(now: Date) -> some View {
        let review = model.blocksToReview(now: now).count
        let chase = model.people.filter { !$0.due.isEmpty }.count
        let unbooked = model.openTasks.filter { model.nextBlock(for: $0) == nil }.count
        let suggested = Router.Flow.suggested(now: now, review: review, chase: chase, unbooked: unbooked)
        return VStack(alignment: .leading, spacing: 20) {
            let streak = model.streak(now: now)
            if streak > 1 {
                Label("\(streak)-day streak", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText())
            }
            SuggestedRoutine(flow: suggested, status: status(suggested, now: now), done: suggested.isDone(now: now)) {
                router.open(.flow(suggested))
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("All routines")
                VStack(spacing: 0) {
                    let flows = Router.Flow.guided
                    ForEach(flows) { flow in
                        RoutineRow(flow: flow, status: status(flow, now: now), done: flow.isDone(now: now)) {
                            router.open(.flow(flow))
                        }
                        if flow != flows.last { Divider().padding(.leading, 60) }
                    }
                }
                .cardSurface()
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Tools")
                VStack(spacing: 0) {
                    RoutineRow(flow: .board, status: "\(model.openTasks.count) open · \(model.waitingTasks.count) waiting", done: false) {
                        router.open(.flow(.board))
                    }
                    Divider().padding(.leading, 60)
                    NavigationLink { InsightsView() } label: { insightsRow }
                        .buttonStyle(.plain)
                }
                .cardSurface()
            }

            #if os(macOS)
            Text("Tip: ⌥⌘1–5 starts a routine from anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var insightsRow: some View {
        let insights = model.insights()
        return HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights").font(.body.weight(.semibold))
                Text("\(insights.total) done this week" + (insights.streak > 0 ? " · \(insights.streak)-day streak" : "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).padding(.leading, 4).accessibilityAddTraits(.isHeader)
    }

    /// One line on what the routine would work through right now.
    private func status(_ flow: Router.Flow, now: Date) -> String {
        switch flow {
        case .planDay:
            let free = model.todayGaps(now: now).reduce(0) { $0 + $1.minutes }
            let open = model.topCandidates.filter { model.nextBlock(for: $0) == nil }.count
            return [open > 0 ? "\(open) task\(open == 1 ? "" : "s") to place" : "Nothing to place",
                    free > 0 ? "\(Format.duration(free)) free today" : "no free time left today"].joined(separator: " · ")
        case .wrapUp:
            let review = model.blocksToReview(now: now).count
            let open = model.due(by: now).count
            return [review > 0 ? "\(review) block\(review == 1 ? "" : "s") to check off" : "No blocks to check off",
                    open > 0 ? "\(open) still due today" : nil].compactMap { $0 }.joined(separator: " · ")
        case .followUps:
            let due = model.people.filter { !$0.due.isEmpty }.count
            let waiting = model.waitingTasks.count
            return due > 0 ? "\(due) \(due == 1 ? "person" : "people") to chase · \(waiting) waiting" : "Nobody to chase · \(waiting) waiting"
        case .weekly:
            let done = model.finishedThisWeek(now: now).reduce(0) { $0 + $1.tasks.count }
            let overdue = model.overdue.count
            return "\(done) finished this week" + (overdue > 0 ? " · \(overdue) overdue" : "")
        case .board:
            return Router.Flow.board.blurb
        }
    }
}

/// The big card for the routine that fits the moment.
private struct SuggestedRoutine: View {
    let flow: Router.Flow
    let status: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(done ? "Done for now" : "Suggested now").font(.caption.weight(.bold)).textCase(.uppercase).opacity(0.85)
                    Spacer()
                    Image(systemName: flow.symbol).font(.title2)
                }
                Text(flow.title).font(.title2.weight(.bold))
                Text(flow.blurb).font(.subheadline).opacity(0.9)
                HStack {
                    Text(status).font(.callout.weight(.medium)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(done ? "Run again" : "Start")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.white.opacity(0.25), in: Capsule())
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 14, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested: \(flow.title). \(status)")
        .accessibilityHint("Starts the routine")
    }
}

/// A routine with its live status and a tick once it's done today.
private struct RoutineRow: View {
    let flow: Router.Flow
    let status: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: flow.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(flow.title).font(.body.weight(.semibold))
                        if done {
                            Label(flow == .weekly ? "This week" : "Today", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "")
        .accessibilityHint(flow.blurb)
    }
}
