import PlannerKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var onboarding = false
    @State private var connectionStatus: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            if onboarding {
                Section {
                    Text("Connect to your Planner server. You'll find the device token as DEVICE_TOKEN in /etc/planner.env on the server.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Server") {
                TextField("Address", text: $model.serverURL, prompt: Text("https://planner.your-tailnet.ts.net"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("Device token", text: $model.token)
                HStack {
                    Button("Test Connection") {
                        testing = true
                        Task {
                            connectionStatus = await model.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let connectionStatus {
                    Text(connectionStatus).font(.callout).foregroundStyle(.secondary)
                }
            }

            calendarSection

            if let settings = model.state?.settings {
                WorkingHoursSection(settings: settings)
            }

            Section("Sync") {
                if let last = model.lastSyncAt {
                    LabeledContent("Last sync", value: Format.relative(last))
                }
                if let error = model.syncError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Sync Now") { Task { await model.sync() } }
                    .disabled(!model.isConfigured || model.isSyncing)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(onboarding ? "Set Up Planner" : "Settings")
    }

    @ViewBuilder
    private var calendarSection: some View {
        @Bindable var model = model
        Section {
            Toggle("Use this device as the calendar bridge", isOn: $model.isCalendarBridge)
        } header: {
            Text("Calendar bridge")
        } footer: {
            Text("The bridge shares this device's calendars with Planner as busy time and writes booked blocks and Planner events into the \"Planner\" calendar. Turn it on for one device only, usually your Mac; iCloud carries the Planner calendar to your other devices.")
        }

        if model.isCalendarBridge {
            busyCalendarsSection
        }
    }

    @ViewBuilder
    private var busyCalendarsSection: some View {
        Section {
            if model.calendarAccess {
                let calendars = model.calendars.filter { $0.id != model.plannerCalendarID }
                ForEach(calendars) { calendar in
                    Toggle(isOn: busyBinding(calendar.id)) {
                        VStack(alignment: .leading) {
                            Text(calendar.title)
                            Text(calendar.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Planner needs calendar access to plan around your events and to add booked blocks to a \"Planner\" calendar.")
                    .foregroundStyle(.secondary)
                Button("Allow Calendar Access") { Task { await model.requestCalendarAccess() } }
            }
        } header: {
            Text("Calendars that count as busy")
        } footer: {
            if model.calendarAccess {
                Text("Booked blocks go into the \"Planner\" calendar. Turn a calendar off if its events shouldn't block time.")
            }
        }
    }

    private func busyBinding(_ id: String) -> Binding<Bool> {
        Binding {
            model.busyCalendarIDs?.contains(id) ?? true
        } set: { isOn in
            var ids = model.busyCalendarIDs ?? Set(model.calendars.map(\.id))
            if isOn { ids.insert(id) } else { ids.remove(id) }
            model.busyCalendarIDs = ids
        }
    }
}

/// Edits the server's scheduling settings. Changes are saved together.
private struct WorkingHoursSection: View {
    @Environment(AppModel.self) private var model
    let settings: PlannerKit.Settings
    @State private var draft: PlannerKit.Settings
    @State private var saving = false

    init(settings: PlannerKit.Settings) {
        self.settings = settings
        _draft = State(initialValue: settings)
    }

    private static let times: [String] = (0..<48).map { String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30) }
    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        Section("Working hours") {
            Picker("Start", selection: $draft.workStart) { times(including: draft.workStart) }
            Picker("End", selection: $draft.workEnd) { times(including: draft.workEnd) }
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    let on = draft.workDays.contains(day)
                    Button(Self.weekdayNames[day - 1]) {
                        if on { draft.workDays.removeAll { $0 == day } } else { draft.workDays = (draft.workDays + [day]).sorted() }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Stepper("Longest block: \(Format.duration(draft.maxBlockMin))", value: $draft.maxBlockMin, in: 30...480, step: 15)
            Stepper("Plan \(draft.horizonDays) days ahead", value: $draft.horizonDays, in: 1...60)
            LabeledContent("Time zone", value: draft.timezone)
            if draft.timezone != TimeZone.current.identifier {
                Button("Use This Device's Time Zone (\(TimeZone.current.identifier))") {
                    draft.timezone = TimeZone.current.identifier
                    draft.timezoneConfirmed = true
                }
            }
            HStack {
                Button("Save") {
                    saving = true
                    Task {
                        await model.saveSettings(SettingsPatch(
                            timezone: draft.timezone,
                            timezoneConfirmed: draft.timezoneConfirmed,
                            workStart: draft.workStart,
                            workEnd: draft.workEnd,
                            workDays: draft.workDays,
                            maxBlockMin: draft.maxBlockMin,
                            horizonDays: draft.horizonDays
                        ))
                        saving = false
                    }
                }
                .disabled(draft == settings || saving || draft.workDays.isEmpty || draft.workEnd <= draft.workStart)
                if draft != settings {
                    Button("Revert") { draft = settings }
                }
            }
        }
        .onChange(of: settings) { _, new in draft = new }
    }

    @ViewBuilder
    private func times(including current: String) -> some View {
        let options = Self.times.contains(current) ? Self.times : (Self.times + [current]).sorted()
        ForEach(options, id: \.self) { Text($0).tag($0) }
    }
}
