import PlannerKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    /// Opening tab. A launch argument like `-PlannerTab calendar` lands in UserDefaults, which
    /// is how screenshots and Siri ("What's next") open a specific screen.
    @State private var tab = UserDefaults.standard.string(forKey: "PlannerTab") ?? "today"

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.isConfigured {
                NavigationStack {
                    SettingsView(onboarding: true)
                }
            } else {
                main
            }
        }
        .routerSheets()
        // Held back while a routine or add sheet is open: presenting it would close that sheet.
        // Routines show their errors inline instead.
        .alert("Planner", isPresented: Binding(get: { model.actionError != nil && router.sheet == nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    @ViewBuilder
    private var main: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            CalendarView().syncBanner()
        }
        #else
        TabView(selection: $tab) {
            NavigationStack {
                TodayView().syncBanner()
            }
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag("today")

            NavigationStack {
                TaskListView().syncBanner()
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }
            .tag("tasks")

            NavigationStack {
                CalendarView().syncBanner()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag("calendar")

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag("settings")
        }
        .overlay(alignment: .bottomTrailing) {
            if tab != "settings" {
                FloatingAddButton()
                    .padding(.trailing, 20)
                    .padding(.bottom, 96)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: tab)
        #endif
    }
}

#if os(macOS)
/// The Mac sidebar: Today at a glance, or the full task list.
struct SidebarView: View {
    enum Pane: String, CaseIterable { case today = "Today", tasks = "Tasks" }
    @State private var pane: Pane = .today

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch pane {
            case .today: TodayView()
            case .tasks: TaskListView()
            }
        }
    }
}
#endif

/// A compact pill above the tab bar when the last sync failed or the server put a block back.
struct SyncBanner: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        if let error = model.syncError {
            pill(
                systemImage: "wifi.exclamationmark",
                title: "Not synced",
                detail: error,
                action: model.suggestedServer != nil ? ("Use :8443", useSuggestion) : ("Retry", retry)
            )
        } else if !model.rejectedMoves.isEmpty {
            pill(
                systemImage: "arrow.uturn.backward",
                title: "Planner put \(model.rejectedMoves.count == 1 ? "a block" : "\(model.rejectedMoves.count) blocks") back",
                detail: model.rejectedMoves.map(\.reason).joined(separator: " "),
                action: nil
            )
        }
    }

    private func useSuggestion() {
        model.useSuggestedServer()
    }

    private func retry() {
        Task { await model.sync() }
    }

    private func pill(systemImage: String, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if expanded {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.35)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the details")
    }
}

extension View {
    /// Puts the sync status pill along the bottom edge, out of the way of titles.
    func syncBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { SyncBanner() }
    }
}

#Preview {
    ContentView()
        .environment(AppModel(calendarStore: InMemoryCalendarStore()))
        .environment(Router())
}
