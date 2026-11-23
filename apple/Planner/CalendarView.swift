import PlannerKit
import SwiftUI

/// Week grid on the Mac, one day at a time on the iPhone. Proposed blocks are dashed;
/// everything Planner owns is coloured by project. On the Mac, drag a Planner block to move it.
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var anchor = Date()
    @State private var selectedProposal: ProposedBlock?
    @State private var selectedEvent: CalEvent?
    @State private var planning = false

    #if os(macOS)
    private let dayCount = 7
    #else
    private let dayCount = 1
    #endif

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday, matching the server's ISO weekdays
        return calendar
    }

    private var days: [Date] {
        let start = dayCount == 7
            ? calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
            : calendar.startOfDay(for: anchor)
        return (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var title: String {
        guard let first = days.first, let last = days.last else { return "Calendar" }
        if dayCount == 1 { return first.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
        return "\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    private var scrollHour: Int {
        let start = model.state?.settings.workStart.split(separator: ":").first.flatMap { Int($0) } ?? 8
        return max(0, start - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let proposal = model.proposal {
                ProposalBar(proposal: proposal)
            }
            ScheduleGrid(
                days: days,
                events: model.state?.events ?? [],
                proposed: model.proposal?.blocks ?? [],
                scrollToHour: scrollHour,
                project: { model.project(id: $0) },
                eventProject: { model.projectFor($0) },
                onTapProposed: { selectedProposal = $0 },
                onTapEvent: { selectedEvent = $0 },
                onMove: { event, start in Task { await model.move(event, to: start) } }
            )
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                Button { move(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Today") { anchor = Date() }
                    .keyboardShortcut("t")
                Button { move(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button {
                    planning = true
                    Task {
                        await model.plan()
                        planning = false
                    }
                } label: {
                    Label("Plan", systemImage: "wand.and.stars")
                }
                .disabled(planning)
                .keyboardShortcut("p")
                .help("Propose time blocks for open tasks")
            }
        }
        .confirmationDialog(
            selectedProposal.map { "\($0.title), \(Format.dayTime($0.startAt))–\(Format.time($0.endAt))" } ?? "",
            isPresented: Binding(get: { selectedProposal != nil }, set: { if !$0 { selectedProposal = nil } }),
            titleVisibility: .visible,
            presenting: selectedProposal
        ) { block in
            Button("Book") { Task { await model.book([block]) } }
            Button("Discard", role: .destructive) { model.discard(block) }
        } message: { block in
            let names = (block.taskIds ?? []).compactMap { model.task(id: $0)?.title }
            let notes = [
                names.isEmpty ? nil : names.joined(separator: ", "),
                block.late ? "This block ends after the task is due." : nil,
                block.outsideWindow == true ? "The project's own hours were full, so this uses working hours." : nil,
            ].compactMap { $0 }
            if !notes.isEmpty { Text(notes.joined(separator: "\n")) }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailView(event: event)
        }
    }

    private func move(_ direction: Int) {
        anchor = calendar.date(byAdding: .day, value: direction * dayCount, to: anchor) ?? anchor
    }
}

struct ProposalBar: View {
    @Environment(AppModel.self) private var model
    let proposal: ScheduleProposal

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(proposal.blocks.count) proposed \(proposal.blocks.count == 1 ? "block" : "blocks")")
                    .font(.headline)
                if !proposal.unscheduled.isEmpty {
                    Text("Didn't fit: \(proposal.unscheduled.map(\.title).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap a dashed block to book or discard it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Discard All", role: .destructive) { model.discardProposal() }
            Button("Book All") { Task { await model.book(proposal.blocks) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Details for any event: what it is, its project, the tasks in a Quick block, and what you can do with it.
struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: CalEvent
    @State private var openTask: PlannerTask?

    var body: some View {
        let project = model.project(id: event.projectId)
        let tasks = model.tasks(for: event)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("When", value: event.allDay ? Format.relative(event.startAt) : "\(Format.dayTime(event.startAt))–\(Format.time(event.endAt))")
                    if let project { LabeledContent("Project") { ProjectChip(project: project) } }
                    LabeledContent("From", value: source)
                }
                if !tasks.isEmpty {
                    Section(event.isBatch ? "Tasks in this block" : "Task") {
                        ForEach(tasks) { task in
                            TaskRow(task: task, nextBlock: nil, showProject: false, onOpen: { openTask = task })
                        }
                    }
                }
                if !event.notes.isEmpty {
                    Section("Notes") { Text(event.notes) }
                }
                if event.source == .local {
                    Section {
                        Button(event.isTaskBlock ? "Remove Block" : "Delete Event", role: .destructive) {
                            Task {
                                await model.removeBlock(event)
                                dismiss()
                            }
                        }
                    } footer: {
                        #if os(macOS)
                        Text("Drag it on the grid, or in Apple Calendar's Planner calendar, to move it.")
                        #else
                        Text("To move it, drag it in Apple Calendar's Planner calendar.")
                        #endif
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(event.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $openTask) { TaskDetailView(task: $0) }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private var source: String {
        switch event.source {
        case .local: event.isTaskBlock ? "Planner (task block)" : "Planner"
        case .device: "Your calendars (read-only here)"
        case .google: "Google Calendar"
        }
    }
}

// MARK: - Grid

private struct GridItemModel: Identifiable {
    enum Kind { case event(CalEvent), proposed(ProposedBlock) }
    let kind: Kind
    let start: Date
    let end: Date

    var id: String {
        switch kind {
        case .event(let e): "e:\(e.id)"
        case .proposed(let p): "p:\(p.id)"
        }
    }
}

private struct PlacedItem: Identifiable {
    let item: GridItemModel
    let lane: Int
    let lanes: Int
    var id: String { item.id }
}

struct ScheduleGrid: View {
    let days: [Date]
    let events: [CalEvent]
    let proposed: [ProposedBlock]
    let scrollToHour: Int
    var project: (String?) -> Project? = { _ in nil }
    /// An event's project, including mirrored events matched by title.
    var eventProject: (CalEvent) -> Project? = { _ in nil }
    var onTapProposed: (ProposedBlock) -> Void
    var onTapEvent: (CalEvent) -> Void
    var onMove: (CalEvent, Date) -> Void = { _, _ in }

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { header }
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(Array(days.enumerated()), id: \.element) { index, day in
                            DayColumn(
                                day: day,
                                items: items(on: day),
                                hourHeight: hourHeight,
                                project: project,
                                eventProject: eventProject,
                                onTapProposed: onTapProposed,
                                onTapEvent: onTapEvent,
                                onDrop: { event, dayOffset, minutes in
                                    let target = Calendar.current.date(byAdding: .day, value: dayOffset, to: event.startAt) ?? event.startAt
                                    onMove(event, target.addingTimeInterval(Double(minutes) * 60))
                                },
                                columnIndex: index,
                                columnCount: days.count
                            )
                            if day != days.last { Divider() }
                        }
                    }
                    .frame(height: hourHeight * 24)
                }
                .onAppear { proxy.scrollTo(scrollToHour, anchor: .top) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 0) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.title3.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                        .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : .primary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var allDayRow: some View {
        let allDay = days.map { day in events.filter { $0.allDay && overlaps($0.startAt, $0.endAt, day) } }
        if allDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter)
                ForEach(days.indices, id: \.self) { index in
                    VStack(spacing: 2) {
                        ForEach(allDay[index]) { event in
                            Text(event.title)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .background((eventProject(event)?.color.color ?? .gray).opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                                .onTapGesture { onTapEvent(event) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    .padding(.top, 2)
                    .id(hour)
            }
        }
        .frame(width: gutter)
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "" }
        return date.formatted(.dateTime.hour())
    }

    private func overlaps(_ start: Date, _ end: Date, _ day: Date) -> Bool {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return start < dayEnd && end > day
    }

    private func items(on day: Date) -> [PlacedItem] {
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        var items: [GridItemModel] = events
            .filter { !$0.allDay && $0.startAt < dayEnd && $0.endAt > day }
            .map { GridItemModel(kind: .event($0), start: max($0.startAt, day), end: min($0.endAt, dayEnd)) }
        items += proposed
            .filter { $0.startAt < dayEnd && $0.endAt > day }
            .map { GridItemModel(kind: .proposed($0), start: max($0.startAt, day), end: min($0.endAt, dayEnd)) }
        return Self.layout(items)
    }

    /// Side-by-side lanes for overlapping items.
    private static func layout(_ items: [GridItemModel]) -> [PlacedItem] {
        var result: [PlacedItem] = []
        var cluster: [(GridItemModel, Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let lanes = max(laneEnds.count, 1)
            result += cluster.map { PlacedItem(item: $0.0, lane: $0.1, lanes: lanes) }
            cluster = []
            laneEnds = []
        }

        for item in items.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if item.start >= clusterEnd { flush() }
            if let lane = laneEnds.firstIndex(where: { $0 <= item.start }) {
                laneEnds[lane] = item.end
                cluster.append((item, lane))
            } else {
                laneEnds.append(item.end)
                cluster.append((item, laneEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, item.end)
        }
        flush()
        return result
    }
}

private struct DayColumn: View {
    let day: Date
    let items: [PlacedItem]
    let hourHeight: CGFloat
    let project: (String?) -> Project?
    let eventProject: (CalEvent) -> Project?
    var onTapProposed: (ProposedBlock) -> Void
    var onTapEvent: (CalEvent) -> Void
    /// (event, days moved, minutes moved within the day)
    var onDrop: (CalEvent, Int, Int) -> Void
    let columnIndex: Int
    let columnCount: Int

    @State private var dragging: (id: String, offset: CGSize)?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle()
                            .fill(.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) { Divider().opacity(0.6) }
                    }
                }
                if Calendar.current.isDateInToday(day) { nowLine }
                ForEach(items) { placed in
                    let width = (geo.size.width - 4) / CGFloat(placed.lanes)
                    let offset = dragging?.id == placed.id ? dragging!.offset : .zero
                    block(placed.item, columnWidth: geo.size.width)
                        .frame(width: max(width - 2, 0), height: max(height(placed.item), 18))
                        .offset(x: 2 + CGFloat(placed.lane) * width + offset.width, y: y(placed.item.start) + offset.height)
                        .zIndex(dragging?.id == placed.id ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .zIndex(dragging != nil ? 1 : 0)
    }

    private var nowLine: some View {
        Rectangle()
            .fill(.red)
            .frame(height: 1.5)
            .offset(y: y(Date()))
    }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(day) / 3600) * hourHeight
    }

    private func height(_ item: GridItemModel) -> CGFloat {
        CGFloat(item.end.timeIntervalSince(item.start) / 3600) * hourHeight
    }

    /// Whole days and 15-minute steps a drag of `translation` amounts to.
    private func snapped(_ translation: CGSize, columnWidth: CGFloat) -> (days: Int, minutes: Int) {
        let days = columnWidth > 0 ? Int((translation.width / columnWidth).rounded()) : 0
        let clampedDays = min(max(days, -columnIndex), columnCount - 1 - columnIndex)
        let minutes = Int((translation.height / hourHeight * 60 / 15).rounded()) * 15
        return (clampedDays, minutes)
    }

    @ViewBuilder
    private func block(_ item: GridItemModel, columnWidth: CGFloat) -> some View {
        switch item.kind {
        case .proposed(let p):
            let tint = project(p.projectId).tint
            label(p.title, start: p.startAt, end: p.endAt, caption: p.late ? "Proposed · late" : p.outsideWindow == true ? "Proposed · outside its hours" : "Proposed")
                .background((p.late ? Color.orange : tint).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(p.late ? Color.orange : tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                )
                .contentShape(Rectangle())
                .onTapGesture { onTapProposed(p) }
                .accessibilityAddTraits(.isButton)
        case .event(let e):
            let proj = eventProject(e)
            let tint: Color = e.isTaskBlock ? proj.tint : (proj?.color.color ?? (e.source == .device ? .gray : .purple))
            let view = label(e.title, start: e.startAt, end: e.endAt, caption: e.isBatch ? "Quick block" : e.isTaskBlock ? proj?.label ?? "Task block" : nil)
                .background(tint.opacity(e.isTaskBlock ? 0.28 : 0.16), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    Rectangle().fill(tint).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
                .contentShape(Rectangle())
                .onTapGesture { onTapEvent(e) }
                .accessibilityAddTraits(.isButton)
            #if os(macOS)
            if e.source == .local && !e.allDay {
                view.gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let s = snapped(value.translation, columnWidth: columnWidth)
                            dragging = ("e:\(e.id)", CGSize(width: CGFloat(s.days) * columnWidth, height: CGFloat(s.minutes) / 60 * hourHeight))
                        }
                        .onEnded { value in
                            let s = snapped(value.translation, columnWidth: columnWidth)
                            dragging = nil
                            if s.days != 0 || s.minutes != 0 { onDrop(e, s.days, s.minutes) }
                        }
                )
                .help("Drag to move")
            } else {
                view
            }
            #else
            view
            #endif
        }
    }

    private func label(_ title: String, start: Date, end: Date, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(2)
            Text([Format.time(start) + "–" + Format.time(end), caption].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
