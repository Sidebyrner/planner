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
            tab(.inbox) { InboxView() }
            tab(.calendar) { CalendarView() }
            tab(.today) { TodayView() }
            tab(.tasks) { TaskListView() }
            tab(.projects) { ProjectsHomeView() }
        }
        .overlay(alignment: .bottom) {
            if !keyboardUp && !router.chromeHidden {
                PlannerTabBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Tasks has its own add field and mic along the bottom.
            if !keyboardUp && !router.chromeHidden && router.place != .tasks {
                FloatingAddButton()
                    .padding(.trailing, 18)
                    .padding(.bottom, Self.tabBarRoom + 18)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.planner, value: keyboardUp)
        .animation(.planner, value: router.chromeHidden)
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
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
                }
                .syncBanner()
        }
        // On the stack, so pushed pages (a project, a conversation) keep clear of the bar too.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardUp || router.chromeHidden ? 0 : Self.tabBarRoom)
        }
        // Tapping the tab again rebuilds its stack: back to the first page, scrolled to the top.
        .id(router.resets[place, default: 0])
        .toolbar(.hidden, for: .tabBar)
        .tag(place)
    }
}

/// The bottom bar, icons only: Inbox · Calendar · Today · Tasks · Projects, with Today raised in
/// the middle as the app's home. Tapping the tab you're on takes it back to its first page.
struct PlannerTabBar: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            item(.inbox, badge: model.inboxUnread)
            item(.calendar)
            today
            item(.tasks)
            item(.projects)
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background { barBackground }
        .padding(.horizontal, 18)
        .padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: router.place)
    }

    @ViewBuilder private var barBackground: some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.1), radius: 14, y: 4)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.cardBorder, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        }
    }

    private func tap(_ place: Router.Place) {
        withAnimation(reduceMotion ? nil : .planner) { router.tap(place) }
    }

    private func item(_ place: Router.Place, badge: Int = 0) -> some View {
        let on = router.place == place
        return Button { tap(place) } label: {
            VStack(spacing: 5) {
                Image(systemName: place.symbol)
                    .font(.system(size: 22, weight: on ? .semibold : .regular))
                    .symbolVariant(on ? .fill : .none)
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Color.red, in: Capsule())
                                .offset(x: 10, y: -6)
                                .contentTransition(.numericText())
                        }
                    }
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.88))
        .accessibilityLabel(place.title)
        .accessibilityValue(badge > 0 ? "\(badge) unread" : "")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(on ? "Back to the first page" : "")
    }

    /// Today: a raised ink disc in the middle slot.
    private var today: some View {
        let on = router.place == .today
        return Button { tap(.today) } label: {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.onInk)
                .symbolEffect(.bounce, value: on)
                .frame(width: 60, height: 60)
                .background(Color.ink, in: Circle())
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: on ? 2.5 : 0).padding(-4))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                .scaleEffect(on ? 1.04 : 1)
                .offset(y: -12)
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
            Group {
                switch router.place {
                case .today, .calendar: TodayView()
                case .tasks: TaskListView()
                // Their own stacks, so a project or conversation opens in the sidebar with the
                // calendar still beside it.
                case .projects: NavigationStack { ProjectsHomeView() }
                case .inbox: NavigationStack { InboxView() }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                SettingsButton().buttonStyle(.borderless)
                Spacer()
                Button { router.open(.routines) } label: { Label("Routines", systemImage: "list.bullet.rectangle.portrait") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
