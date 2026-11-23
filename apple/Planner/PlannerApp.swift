import EventKit
import SwiftUI

@main
struct PlannerApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
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
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        SwiftUI.Settings {
            NavigationStack {
                SettingsView()
            }
            .environment(model)
            .frame(width: 520, height: 640)
        }
        #endif
    }
}
