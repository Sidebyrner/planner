import PlannerKit
import SwiftUI

// MARK: - Card styling

extension Color {
    /// The page behind the cards: a step darker than the system's grouped background in light
    /// mode and true black in dark mode, so cards lift clearly off it.
    static var pageBackground: Color {
        #if os(iOS)
        Color(light: Color(red: 0.91, green: 0.91, blue: 0.94), dark: .black)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A card on that page.
    static var cardBackground: Color {
        #if os(iOS)
        Color(light: .white, dark: Color(red: 0.11, green: 0.11, blue: 0.12))
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The hairline around a card.
    static var cardBorder: Color { Color.primary.opacity(0.08) }
}

extension View {
    /// Card surface: fill, hairline border and a soft shadow so it reads as something to touch.
    func cardSurface(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(Color.cardBackground, in: shape)
            .overlay(shape.strokeBorder(Color.cardBorder, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
    }
}

/// A titled card, the building block of Today and the workflows.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color = .accentColor
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(tint).font(.subheadline.weight(.semibold))
                    }
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    accessory()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, symbol: String? = nil, tint: Color = .accentColor, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Day strip

/// Today as one bar: events, your blocks, free stretches you can tap to fill, and now.
struct DayStrip: View {
    @Environment(AppModel.self) private var model
    var day: Date = Date()
    var onGap: (AppModel.Gap) -> Void = { _ in }
    var onEvent: (CalEvent) -> Void = { _ in }

    private var calendar: Calendar { .current }

    private var range: (start: Date, end: Date) {
        let base = calendar.startOfDay(for: day)
        let earliest = events.map { calendar.component(.hour, from: $0.startAt) }.min() ?? 7
        let latest = events.map { calendar.component(.hour, from: $0.endAt) + 1 }.max() ?? 22
        let startHour = max(5, min(7, earliest))
        let endHour = min(24, max(22, latest))
        return (calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: base) ?? base,
                calendar.date(byAdding: .hour, value: endHour, to: base) ?? base)
    }

    private var events: [CalEvent] {
        model.todayEvents.filter { !$0.ignored && calendar.isDate($0.startAt, inSameDayAs: day) }
    }

    private var gaps: [AppModel.Gap] {
        calendar.isDateInToday(day) ? model.todayGaps(minMinutes: 15) : []
    }

    var body: some View {
        let (start, end) = range
        let total = end.timeIntervalSince(start)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let x = { (d: Date) -> CGFloat in CGFloat(max(0, min(1, d.timeIntervalSince(start) / total))) * width }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1))

                    ForEach(gaps) { gap in
                        Button { onGap(gap) } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.green, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    if x(gap.end) - x(gap.start) > 34 {
                                        Image(systemName: "plus").font(.caption.weight(.bold)).foregroundStyle(.green)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(6, x(gap.end) - x(gap.start) - 2), height: 40)
                        .offset(x: x(gap.start) + 1)
                        .accessibilityLabel("Free \(Format.duration(gap.minutes)) from \(Format.time(gap.start))")
                        .accessibilityHint("Adds something here")
                    }

                    ForEach(events) { event in
                        let w = max(4, x(event.endAt) - x(event.startAt))
                        let tint = event.isTaskBlock || model.projectFor(event) != nil ? model.projectFor(event).tint : Color.gray
                        Button { onEvent(event) } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tint.opacity(event.isTaskBlock ? 0.85 : 0.45))
                                .overlay(alignment: .leading) {
                                    if w > 54 {
                                        Text(event.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                            .padding(.horizontal, 5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .frame(width: w, height: 40)
                        .offset(x: x(event.startAt))
                        .accessibilityLabel("\(event.title), \(Format.time(event.startAt)) to \(Format.time(event.endAt))")
                    }

                    if calendar.isDateInToday(day), Date() > start, Date() < end {
                        Capsule().fill(Color.red).frame(width: 2.5, height: 48).offset(x: x(Date()) - 1, y: -4)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 40)

            GeometryReader { geo in
                let firstHour = calendar.component(.hour, from: start)
                let lastHour = calendar.component(.hour, from: end.addingTimeInterval(-1)) + 1
                ForEach(Array(stride(from: firstHour + (3 - firstHour % 3) % 3, through: lastHour, by: 3)), id: \.self) { hour in
                    let at = calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: day) ?? day
                    Text(hour == 12 ? "noon" : Format.shortClock(at))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: CGFloat(at.timeIntervalSince(start) / total) * geo.size.width, y: 6)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Now

/// The block you're in, the step to do next, and one-tap Done / +15 / Skip.
struct NowCard: View {
    @Environment(AppModel.self) private var model
    var onOpen: (CalEvent) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let current = model.todayEvents.last { !$0.ignored && $0.startAt <= now && $0.endAt > now && $0.isTaskBlock }
            let other = model.todayEvents.last { !$0.ignored && $0.startAt <= now && $0.endAt > now && !$0.isTaskBlock }
            let next = model.todayEvents.first { !$0.ignored && $0.startAt > now }
            VStack(alignment: .leading, spacing: 10) {
                if let block = current {
                    blockCard(block, now: now)
                } else if let other {
                    plainNow(other, now: now)
                }
                if let next {
                    Button { onOpen(next) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                            Text("Then ").foregroundStyle(.secondary) + Text(next.title).fontWeight(.semibold)
                            Spacer(minLength: 4)
                            Text(untilText(next.startAt, now: now)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, current == nil && other == nil ? 0 : 4)
                } else if current == nil && other == nil {
                    Text("Nothing else on the calendar today.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func untilText(_ start: Date, now: Date) -> String {
        let minutes = Int(start.timeIntervalSince(now) / 60)
        return minutes < 180 ? "in \(Format.duration(max(1, minutes)))" : Format.time(start)
    }

    @ViewBuilder
    private func blockCard(_ block: CalEvent, now: Date) -> some View {
        let project = model.projectFor(block)
        let left = max(0, Int(block.endAt.timeIntervalSince(now) / 60))
        let progress = min(1, max(0, now.timeIntervalSince(block.startAt) / block.endAt.timeIntervalSince(block.startAt)))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOW").font(.caption.weight(.heavy)).foregroundStyle(project.tint)
                Text("\(Format.duration(left)) left · until \(Format.time(block.endAt))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let project { ProjectChip(project: project) }
            }
            Button { onOpen(block) } label: {
                Text(block.title).font(.title2.weight(.bold)).multilineTextAlignment(.leading).foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            ProgressView(value: progress).tint(project.tint)

            if let step = model.nextStep(in: block) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STEP \(step.number) OF \(step.of)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(step.item.text).font(.title3.weight(.semibold))
                    Button {
                        Task { await model.toggleStep(step.item, of: step.task) }
                    } label: {
                        Label("Done, next step", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(project.tint)
                    .controlSize(.large)
                }
                .padding(12)
                .background(project.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            }

            HStack(spacing: 8) {
                Button { Task { await model.mark(block, .done) } } label: {
                    Label("Done", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .tint(.green)
                Button { Task { await model.extend(block, minutes: 15) } } label: {
                    Label("+15 min", systemImage: "plus.circle").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                Button { Task { await model.mark(block, .missed) } } label: {
                    Label("Skip", systemImage: "forward.end").frame(maxWidth: .infinity)
                }
                .tint(.secondary)
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .background(
            LinearGradient(colors: [project.tint.opacity(0.18), project.tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private func plainNow(_ event: CalEvent, now: Date) -> some View {
        let project = model.projectFor(event) ?? model.hostProject(for: event)
        return Button { onOpen(event) } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(project.tint).frame(width: 4, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW").font(.caption.weight(.heavy)).foregroundStyle(project.tint)
                    Text(event.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                }
                Spacer()
                Text("until \(Format.time(event.endAt))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The window you're in

/// Free time you're in right now (or a project's own time, like your shift), with what fits.
struct WindowCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let window: AppModel.Window

    private var title: String {
        switch window.kind {
        case .free:
            if let until = window.until { return "Free now · \(Format.duration(window.minutes)) until \(until.title)" }
            return "Free for the rest of the day"
        case .hosted(let project):
            return "During \(window.until?.title ?? project.name) · \(Format.duration(window.minutes)) left"
        }
    }

    private var suggestions: [PlannerTask] {
        switch window.kind {
        case .free:
            return model.fits(minutes: window.minutes)
        case .hosted(let project):
            // That project's work first, then anything quick.
            let own = model.fits(minutes: window.minutes, projectId: project.id, limit: 3)
            let quick = model.fits(minutes: 15, limit: 3).filter { q in !own.contains { $0.id == q.id } }
            return Array((own + quick).prefix(4))
        }
    }

    private var startNow: Date {
        let snap = 5 * 60.0
        return Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / snap).rounded(.up) * snap)
    }

    var body: some View {
        let tasks = suggestions
        Card(title: title, symbol: window.kind.isFree ? "sparkles" : "briefcase", tint: window.kind.isFree ? .green : .orange) {
            if tasks.isEmpty {
                Text(window.kind.isFree ? "Nothing open fits in this time." : "No open tasks for this stretch.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Pick one to start now:").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        FitRow(task: task, minutes: min(model.remainingMinutes(task), window.minutes), start: startNow)
                        if task.id != tasks.last?.id { Divider().padding(.leading, 4) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Button { router.open(.blockTime(start: startNow, minutes: min(60, window.minutes))) } label: {
                    Label("Task here", systemImage: "clock.badge.checkmark").frame(maxWidth: .infinity)
                }
                Button { router.open(.newEvent(start: startNow, minutes: min(60, window.minutes))) } label: {
                    Label("Event here", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .font(.subheadline.weight(.semibold))
        }
    }
}

/// A task that fits the free time: room for a two-line title and its details, and a big Start.
private struct FitRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    let minutes: Int
    let start: Date
    @State private var starting = false
    @State private var started = false

    var body: some View {
        let project = model.project(id: task.projectId)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let project { ProjectChip(project: project) }
                    if let due = task.dueAt {
                        Label(Format.relative(due), systemImage: "flag")
                            .foregroundStyle(due < Date() ? Color.red : Color.secondary)
                    }
                    if let progress = task.checklistProgress {
                        Label(progress, systemImage: "checklist").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                starting = true
                Task {
                    started = await model.book(task, at: start, minutes: max(5, minutes))
                    starting = false
                }
            } label: {
                VStack(spacing: 1) {
                    if starting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: started ? "checkmark" : "play.fill").font(.subheadline.weight(.bold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(started ? "Booked" : "Start").font(.subheadline.weight(.bold))
                    }
                    Text(Format.duration(minutes)).font(.caption2.weight(.semibold)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .frame(minWidth: 76, minHeight: 58)
                .background((started ? Color.green : Color.accentColor).gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.pressable(scale: 0.92))
            .disabled(starting || started)
            .sensoryFeedback(.success, trigger: started)
            .accessibilityLabel("Start \(task.title)")
            .accessibilityHint("Books \(Format.duration(minutes)) for it starting now")
        }
        .padding(.vertical, 12)
    }
}

extension AppModel.Window.Kind {
    var isFree: Bool { if case .free = self { true } else { false } }
}

// MARK: - Chores and bills

struct ChoreRow: View {
    @Environment(AppModel.self) private var model
    let task: PlannerTask
    var onOpen: () -> Void

    var body: some View {
        let overdue = (task.dueAt ?? .distantFuture) < Date()
        HStack(spacing: 12) {
            Button { Task { await model.toggleDone(task) } } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.isDone ? Color.green : model.project(id: task.projectId).tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(task.title) done")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(task.title).foregroundStyle(.primary)
                        if task.repeats { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text([task.dueAt.map { overdue ? "overdue · \(Format.relative($0))" : Format.relative($0) }, task.recurrence?.summary]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(overdue ? .red : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Follow-ups

/// Message, email or call someone from a small icon row. Message and Email open a drafted
/// nudge for `task`; sending it counts as chasing them.
struct ContactIcons: View {
    @Environment(Router.self) private var router
    let contact: Contact?
    var task: PlannerTask?

    var body: some View {
        HStack(spacing: 8) {
            let phone = contact?.phone?.filter { $0.isNumber || $0 == "+" } ?? ""
            if !phone.isEmpty {
                if let task {
                    Button { router.open(.nudge(taskId: task.id, channel: .message)) } label: { icon("message.fill", .green) }
                        .buttonStyle(.pressable(scale: 0.88))
                        .accessibilityLabel("Message \(contact?.name ?? "")")
                }
                if let url = URL(string: "tel:\(phone)") {
                    Link(destination: url) { icon("phone.fill", .accentColor) }.accessibilityLabel("Call \(contact?.name ?? "")")
                }
            }
            if contact?.email?.isEmpty == false, let task {
                Button { router.open(.nudge(taskId: task.id, channel: .email)) } label: { icon("envelope.fill", .accentColor) }
                    .buttonStyle(.pressable(scale: 0.88))
                    .accessibilityLabel("Email \(contact?.name ?? "")")
            }
        }
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.subheadline)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.3), lineWidth: 0.75))
    }
}

/// One person you're waiting on: what's due to chase, with Snooze and Got it.
struct PersonCard: View {
    @Environment(AppModel.self) private var model
    let person: AppModel.Person
    var onOpen: (PlannerTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Avatar(name: person.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name).font(.body.weight(.semibold))
                    Text(summary).font(.caption.weight(person.hasReply ? .semibold : .regular))
                        .foregroundStyle(person.hasReply ? Color.green : person.due.isEmpty ? Color.secondary : Color.red)
                }
                Spacer()
                ContactIcons(contact: person.contact, task: person.due.first ?? person.pending.first)
            }
            ForEach(person.due) { task in
                FollowUpRow(task: task, onOpen: { onOpen(task) })
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        let replied = person.due.filter(\.hasReply).count
        if replied > 0 { parts.append("replied") }
        let chase = person.due.count - replied
        if chase > 0 { parts.append("\(chase) to chase") }
        if !person.pending.isEmpty { parts.append("\(person.pending.count) waiting") }
        return parts.joined(separator: " · ")
    }
}

struct FollowUpRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    let task: PlannerTask
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    if task.hasReply, let at = task.repliedAt {
                        Label("Replied \(Format.relative(at))", systemImage: "envelope.open.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else if let since = task.followUpAt {
                        Text("follow-up was \(Format.relative(since))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if task.hasReply, let snippet = task.replySnippet, !snippet.isEmpty {
                ReplyQuote(text: snippet)
            }
            HStack(spacing: 8) {
                if task.hasReply {
                    Button { Task { await model.gotIt(task) } } label: { Label("Got it", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
                Button { router.open(.nudge(taskId: task.id)) } label: { Label(task.hasReply ? "Reply" : "Nudge", systemImage: "text.bubble") }
                    .buttonStyle(.borderedProminent)
                    .tint(task.hasReply ? .secondary : .indigo)
                Menu {
                    Button("Check again tomorrow") { Task { await model.snooze(task, days: 1) } }
                    Button("Check again in 3 days") { Task { await model.snooze(task, days: 3) } }
                    Button("Check again next week") { Task { await model.snooze(task, days: 7) } }
                } label: {
                    Label("Snooze", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                if !task.hasReply {
                    Button { Task { await model.gotIt(task) } } label: { Label("Got it", systemImage: "checkmark") }
                        .buttonStyle(.bordered)
                        .tint(.green)
                }
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
        }
        .padding(.leading, 44)
    }
}

/// The start of an email they sent back, quoted.
struct ReplyQuote: View {
    let text: String

    var body: some View {
        Text("“\(text)”")
            .font(.callout)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.green).frame(width: 3).padding(.vertical, 6)
            }
            .accessibilityLabel("They wrote: \(text)")
    }
}

// MARK: - Checking off blocks

/// A finished block: did it happen? Done takes its time off the task; Missed finds new time.
struct BlockReviewRow: View {
    @Environment(AppModel.self) private var model
    let block: CalEvent
    @State private var working = false

    var body: some View {
        let project = model.projectFor(block)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(project.tint).frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(Format.relative(block.startAt))–\(Format.time(block.endAt))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let outcome = block.outcome {
                Label(outcome == .done ? "Done" : "Missed", systemImage: outcome == .done ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(outcome == .done ? .green : .orange)
            } else if working {
                ProgressView()
            } else {
                Button { mark(.missed) } label: { Text("Missed") }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                Button { mark(.done) } label: { Text("Done") }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .font(.caption.weight(.semibold))
    }

    private func mark(_ outcome: BlockOutcome) {
        working = true
        Task {
            await model.mark(block, outcome)
            working = false
        }
    }
}
