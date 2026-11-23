import PlannerKit
import SwiftUI

/// Settings overview: connection status at the top, each area one tap away.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var onboarding = false

    var body: some View {
        if onboarding {
            ConnectView()
        } else {
            overview
        }
    }

    private var overview: some View {
        @Bindable var model = model
        return Form {
            Section {
                NavigationLink {
                    ServerSettingsView()
                } label: {
                    ConnectionStatusRow()
                }
                if let suggestion = model.suggestedServer {
                    Button("Use \(suggestion)") { model.useSuggestedServer() }
                }
            }

            Section("Planning") {
                NavigationLink {
                    ProjectsView()
                } label: {
                    LabeledContent {
                        Text("\(model.liveProjects.count)")
                    } label: {
                        Label("Projects", systemImage: "folder")
                    }
                }
                NavigationLink {
                    SchedulingSettingsView()
                } label: {
                    LabeledContent {
                        Text(schedulingSummary)
                    } label: {
                        Label("Scheduling", systemImage: "clock")
                    }
                }
                .disabled(model.state == nil)
            }

            Section {
                NavigationLink {
                    CalendarSettingsView()
                } label: {
                    LabeledContent {
                        Text(model.isCalendarBridge ? "This device" : "Another device")
                    } label: {
                        Label("Calendars", systemImage: "calendar")
                    }
                }
                Toggle(isOn: $model.remindersEnabled) {
                    Label("Reminders", systemImage: "bell")
                }
                #if os(iOS)
                NavigationLink {
                    SiriSettingsView()
                } label: {
                    Label("Siri & Shortcuts", systemImage: "waveform")
                }
                #endif
            } footer: {
                Text("Reminders: a notification when a booked block starts and when a follow-up is due.")
            }

            Section {
                Button {
                    Task { await model.sync() }
                } label: {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        if model.isSyncing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!model.isConfigured || model.isSyncing)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var schedulingSummary: String {
        guard let s = model.state?.settings else { return "" }
        return "\(Format.weekdays(s.workDays)) \(Format.clock(s.workStart))–\(Format.clock(s.workEnd))"
    }
}

/// Green, orange or red dot with what's going on with the server connection.
struct ConnectionStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.serverHost ?? "Not connected")
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.syncError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if !model.isConfigured || model.syncError != nil { return .red }
        return model.lastSyncAt == nil ? .orange : .green
    }

    private var detail: String {
        if !model.isConfigured { return "Add the server address and device token" }
        if let error = model.syncError { return error }
        if let last = model.lastSyncAt { return "Synced \(last.formatted(.relative(presentation: .named)))" }
        return "Connecting…"
    }
}

// MARK: - First run

/// Just what's needed to connect: address, token, Connect.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var result: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    Text("Connect to your Planner")
                        .font(.title2.weight(.bold))
                    Text("Enter the address of your Planner server and this device's token.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                TextField("Server address", text: $model.serverURL, prompt: Text("https://planner.your-tailnet.ts.net:8443"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    #endif
                HStack {
                    SecureField("Device token", text: $model.token)
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            model.token = pasted.replacingOccurrences(of: "DEVICE_TOKEN=", with: "")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
            } footer: {
                Text("The token is DEVICE_TOKEN in the server's planner.env. It's stored in your Keychain.")
            }

            Section {
                Button {
                    connecting = true
                    Task {
                        result = await model.connect()
                        connecting = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if connecting { ProgressView().controlSize(.small) } else { Text("Connect").bold() }
                        Spacer()
                    }
                }
                .disabled(connecting || model.serverURL.isEmpty || model.token.isEmpty)
                if let result {
                    Label(result, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Set Up")
    }
}

// MARK: - Server

struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ConnectionStatusRow()
            }
            Section {
                TextField("Server address", text: $model.serverURL, prompt: Text("https://planner.your-tailnet.ts.net:8443"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                HStack {
                    SecureField("Device token", text: $model.token)
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            model.token = pasted.replacingOccurrences(of: "DEVICE_TOKEN=", with: "")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                Button {
                    testing = true
                    Task {
                        status = await model.connect() ?? "Connected."
                        testing = false
                    }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(testing)
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } footer: {
                Text("With Tailscale Funnel on, the app lives on port 8443 and only /mcp is public.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server")
    }
}

// MARK: - Calendars

struct CalendarSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Calendar sync runs on", selection: $model.isCalendarBridge) {
                    Text("This device").tag(true)
                    Text("Another device").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Calendar sync runs on")
            } footer: {
                Text("One device shares your calendars with Planner as busy time and writes booked blocks into a \"Planner\" calendar. Use your Mac; iCloud brings that calendar to your other devices.")
            }

            if model.isCalendarBridge {
                Section {
                    if model.calendarAccess {
                        ForEach(model.calendars.filter { $0.id != model.plannerCalendarID }) { calendar in
                            Toggle(isOn: busyBinding(calendar.id)) {
                                VStack(alignment: .leading) {
                                    Text(calendar.title)
                                    Text(calendar.source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("Planner needs calendar access to plan around your events.")
                            .foregroundStyle(.secondary)
                        Button("Allow Calendar Access") { Task { await model.requestCalendarAccess() } }
                    }
                } header: {
                    Text("Count as busy")
                } footer: {
                    if model.calendarAccess {
                        Text("Turn a calendar off if its events shouldn't block time.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendars")
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

// MARK: - Scheduling

/// The server's scheduling settings. Changes are saved together.
struct SchedulingSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let settings = model.state?.settings {
            SchedulingForm(settings: settings)
        } else {
            ContentUnavailableView("Not synced yet", systemImage: "clock", description: Text("Connect to your server first."))
        }
    }
}

private struct SchedulingForm: View {
    @Environment(AppModel.self) private var model
    let settings: PlannerKit.Settings
    @State private var draft: PlannerKit.Settings
    @State private var saving = false

    init(settings: PlannerKit.Settings) {
        self.settings = settings
        _draft = State(initialValue: settings)
    }

    private var valid: Bool { !draft.workDays.isEmpty && draft.workEnd > draft.workStart }

    var body: some View {
        Form {
            Section {
                WeekdayPicker(days: $draft.workDays)
                    .padding(.vertical, 4)
                Picker("From", selection: $draft.workStart) { TimeOptions(current: draft.workStart) }
                Picker("Until", selection: $draft.workEnd) { TimeOptions(current: draft.workEnd) }
            } header: {
                Text("Working hours")
            } footer: {
                Text("Planner books tasks inside these hours, unless a project has its own.")
            }

            Section("Blocks") {
                Stepper("Longest block: \(Format.duration(draft.maxBlockMin))", value: $draft.maxBlockMin, in: 30...480, step: 15)
                Stepper("Plan \(draft.horizonDays) days ahead", value: $draft.horizonDays, in: 1...60)
            }

            Section {
                Stepper(draft.bufferMin == 0 ? "No breathing room" : "\(draft.bufferMin) min breathing room", value: $draft.bufferMin, in: 0...120, step: 5)
                if draft.bufferMin > 0 {
                    Stepper("Around events of \(Format.duration(draft.bufferMinEventMin)) or more", value: $draft.bufferMinEventMin, in: 15...1440, step: 15)
                }
            } header: {
                Text("Around long events")
            } footer: {
                Text("Keeps time free before and after long things like a shift, so tasks aren't booked right up against them.")
            }

            Section("Time zone") {
                LabeledContent("Planning in", value: draft.timezone)
                if draft.timezone != TimeZone.current.identifier {
                    Button("Use \(TimeZone.current.identifier)") {
                        draft.timezone = TimeZone.current.identifier
                        draft.timezoneConfirmed = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scheduling")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
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
                            horizonDays: draft.horizonDays,
                            bufferMin: draft.bufferMin,
                            bufferMinEventMin: draft.bufferMinEventMin
                        ))
                        saving = false
                    }
                }
                .disabled(draft == settings || saving || !valid)
            }
            if draft != settings {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert") { draft = settings }
                }
            }
        }
        .onChange(of: settings) { _, new in draft = new }
    }
}

/// Half-hour choices, keeping an off-grid value that's already set.
struct TimeOptions: View {
    let current: String
    private static let times: [String] = (0..<96).map { String(format: "%02d:%02d", $0 / 4, ($0 % 4) * 15) }

    var body: some View {
        let options = Self.times.contains(current) ? Self.times : (Self.times + [current]).sorted()
        ForEach(options, id: \.self) { Text(Format.clock($0)).tag($0) }
    }
}
