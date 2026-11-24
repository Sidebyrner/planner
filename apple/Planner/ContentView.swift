import PlannerKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    #if os(iOS)
    @State private var keyboardUp = false
    #endif

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
        @Bindable var router = router
        // The system tab bar can't make one tab stand out, so the tabs keep their state in a
        // TabView with its bar hidden and our own bar sits along the bottom.
        TabView(selection: $router.place) {
            tab(.routines) { RoutinesView() }
            tab(.calendar) { CalendarView() }
            tab(.today) { TodayView() }
            tab(.tasks) { TaskListView() }
            tab(.projects) { ProjectsHomeView() }
        }
        .overlay(alignment: .bottom) {
            if !keyboardUp {
                PlannerTabBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Tasks has its own add field and mic along the bottom.
            if !keyboardUp && router.place != .tasks {
                FloatingAddButton()
                    .padding(.trailing, 18)
                    .padding(.bottom, Self.tabBarRoom + 18)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.planner, value: keyboardUp)
        .animation(.planner, value: router.place)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onAppear {
            // Settings left the tab bar; `-PlannerTab settings` still opens it.
            if UserDefaults.standard.string(forKey: "PlannerTab") == "settings" { router.open(.settings) }
        }
        #endif
    }
}

#if os(iOS)
extension ContentView {
    /// Room the bottom bar takes, kept clear inside each tab so lists and bottom fields sit above it.
    static let tabBarRoom: CGFloat = 66

    private func tab<V: View>(_ place: Router.Place, @ViewBuilder content: () -> V) -> some View {
        NavigationStack {
            content()
                .syncBanner()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: keyboardUp ? 0 : Self.tabBarRoom)
                }
        }
        .toolbar(.hidden, for: .tabBar)
        .tag(place)
    }
}

/// The bottom bar: Routines · Calendar · Today · Tasks · Projects, with Today raised in the
/// middle as the app's home.
struct PlannerTabBar: View {
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.routines)
            item(.calendar)
            today
            item(.tasks)
            item(.projects)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(Capsule(style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: router.place)
    }

    private func select(_ place: Router.Place) {
        withAnimation(reduceMotion ? nil : .planner) { router.go(place) }
    }

    private func item(_ place: Router.Place) -> some View {
        let on = router.place == place
        return Button { select(place) } label: {
            VStack(spacing: 3) {
                Image(systemName: place.symbol)
                    .font(.system(size: 19, weight: on ? .semibold : .regular))
                    .symbolVariant(on ? .fill : .none)
                    .frame(height: 24)
                Text(place.title).font(.caption2.weight(on ? .semibold : .medium))
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(place.title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// Today: a raised ink disc that fills the middle slot.
    private var today: some View {
        let on = router.place == .today
        return Button { select(.today) } label: {
            VStack(spacing: 3) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.onInk)
                    .symbolEffect(.bounce, value: on)
                    .frame(width: 56, height: 56)
                    .background(Color.ink, in: Circle())
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: on ? 2.5 : 0).padding(-4))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .scaleEffect(on ? 1.04 : 1)
                Text("Today")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(on ? Color.accentColor : Color.primary)
            }
            .offset(y: -10)
            .padding(.bottom, -10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel("Today")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
#endif

#if os(macOS)
/// The Mac sidebar: Today, the task list, projects or routines, with the calendar beside it.
struct SidebarView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: 0) {
            Picker("View", selection: $router.place) {
                ForEach(Router.Place.sidebar) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch router.place {
            case .today, .calendar: TodayView()
            case .tasks: TaskListView()
            case .projects:
                // Its own stack, so a project opens in the sidebar with the calendar still beside it.
                NavigationStack { ProjectsHomeView() }
            case .routines: NavigationStack { RoutinesView() }
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
