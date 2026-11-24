import EventKit
import SwiftUI

@main
struct PlannerApp: App {
    @State private var model = AppModel()
    @State private var router = Router()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(router)
                // Sync on launch, when the app comes back to the front, and every
                // five minutes while it stays there.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await model.start()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(300))
                        if Task.isCancelled { break }
                        await model.sync()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    model.calendarChanged()
                }
        }
        .commands { PlannerCommands(router: router) }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        SwiftUI.Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(model)
            .environment(router)
            .frame(width: 520, height: 640)
        }
        #endif
    }
}

/// Menu-bar commands (Mac) and keyboard shortcuts (Mac and iPad) for adding and the routines.
struct PlannerCommands: Commands {
    let router: Router

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { router.open(.newTask) }
                .keyboardShortcut("n")
            Button("New Event") { router.open(.newEvent()) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Block Time") { router.open(.blockTime()) }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Button("Add by Voice") { router.open(.voice) }
                .keyboardShortcut("v", modifiers: [.command, .option])
        }
        CommandMenu("Routines") {
            ForEach(Array(Router.Flow.allCases.enumerated()), id: \.element) { i, flow in
                Button(flow.title) { router.open(.flow(flow)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
        }
    }
}
