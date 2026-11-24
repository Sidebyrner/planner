import PlannerKit
import SwiftUI

/// Put something on today's calendar fast: a block for a task, or an event.
struct QuickAddView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case task = "Task block", event = "Event"
        var id: String { rawValue }
    }

    enum StartChoice: Hashable { case now, nextFree, afterCurrent, custom }
    private static let lengths: [(String, Int)] = [("15m", 15), ("30m", 30), ("1h", 60), ("1h 30m", 90)]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind = .task
    @State private var title = ""
    @State private var existingTaskId: String?
    @State private var projectId: String?
    @State private var minutes: Int
    @State private var startChoice: StartChoice
    @State private var customStart: Date
    @State private var saving = false

    /// Open prefilled for a gap ("Add…" on a free row), or blank from the + button.
    init(kind: Kind = .task, start: Date? = nil, minutes: Int = 30) {
        _kind = State(initialValue: kind)
        _minutes = State(initialValue: minutes)
        _startChoice = State(initialValue: start == nil ? .nextFree : .custom)
        _customStart = State(initialValue: start ?? Date())
    }

    private var start: Date {
        let now = Date()
        switch startChoice {
        case .now:
            return Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300)
        case .nextFree:
            // The first gap that fits; else the next free moment at all, so it never lands on top of
            // the block you're in.
            return model.todayGaps(minMinutes: minutes).first?.start
                ?? model.todayGaps(minMinutes: 5).first?.start
                ?? model.currentEvent?.endAt
                ?? now
        case .afterCurrent:
            return model.currentEvent?.endAt ?? now
        case .custom:
            return customStart
        }
    }

    private var startOptions: [(String, StartChoice)] {
        var options: [(String, StartChoice)] = [("Now", .now), ("Next free", .nextFree)]
        if model.currentEvent != nil { options.append(("After this", .afterCurrent)) }
        options.append(("Pick", .custom))
        return options
    }

    private var existingTask: PlannerTask? { model.task(id: existingTaskId) }
    private var effectiveTitle: String { existingTask?.title ?? title.trimmingCharacters(in: .whitespaces) }
    private var conflicts: [CalEvent] {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        return (model.state?.events ?? []).filter { !$0.allDay && $0.startAt < end && $0.endAt > start }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    if kind == .task && !model.openTasks.isEmpty {
                        Picker("Task", selection: $existingTaskId) {
                            Text("New task").tag(String?.none)
                            ForEach(model.openTasks) { t in
                                Text(t.title).tag(String?.some(t.id))
                            }
                        }
                    }
                    if existingTask == nil {
                        TextField(kind == .task ? "What will you work on?" : "Event title", text: $title)
                        Picker("Project", selection: $projectId) {
                            Text("No project").tag(String?.none)
                            ForEach(model.liveProjects) { Text($0.label).tag(String?.some($0.id)) }
                        }
                    }
                }

                Section("Starts") {
                    ChipRow(options: startOptions, selection: $startChoice)
                    if startChoice == .custom {
                        DatePicker("Start", selection: $customStart, displayedComponents: [.date, .hourAndMinute])
                    } else {
                        LabeledContent("Start", value: Format.relative(start))
                    }
                }

                Section {
                    ChipRow(options: Self.lengths, selection: $minutes)
                    Stepper("Length: \(Format.duration(minutes))", value: $minutes, in: 5...480, step: 5)
                } header: {
                    Text("Length")
                } footer: {
                    if !conflicts.isEmpty {
                        Label("Overlaps \(conflicts.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(Format.time(start))–\(Format.time(start.addingTimeInterval(Double(minutes) * 60)))")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(kind == .event ? "New Event" : "Block Time")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save).disabled(saving || effectiveTitle.isEmpty)
                }
            }
            .onChange(of: existingTaskId) { _, id in
                // Default the length to what's left of the chosen task.
                if let task = model.task(id: id) {
                    let left = model.remainingMinutes(task)
                    if left > 0 { minutes = min(left, model.state?.settings.maxBlockMin ?? 120) }
                }
            }
        }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func save() {
        saving = true
        let at = start
        Task {
            let ok: Bool
            if let task = existingTask {
                ok = await model.book(task, at: at, minutes: minutes)
            } else if kind == .task {
                ok = await model.addTaskBlock(title: effectiveTitle, projectId: projectId, at: at, minutes: minutes)
            } else {
                ok = await model.addEvent(title: effectiveTitle, projectId: projectId, at: at, minutes: minutes)
            }
            saving = false
            if ok { dismiss() }
        }
    }
}

/// A row of capsule chips for picking one value.
struct ChipRow<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    let (label, value) = options[i]
                    let on = value == selection
                    Button(label) { selection = value }
                        .font(.callout.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}
