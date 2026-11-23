import PlannerKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

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
        .alert("Planner", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    @ViewBuilder
    private var main: some View {
        #if os(macOS)
        NavigationSplitView {
            TaskListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            VStack(spacing: 0) {
                SyncBanner()
                CalendarView()
            }
        }
        #else
        TabView {
            NavigationStack {
                VStack(spacing: 0) {
                    SyncBanner()
                    TaskListView()
                }
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }

            NavigationStack {
                VStack(spacing: 0) {
                    SyncBanner()
                    CalendarView()
                }
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
        #endif
    }
}

/// Shown when the last sync failed or the server changed a block back.
struct SyncBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.syncError {
            banner(systemImage: "wifi.exclamationmark", text: "Can't reach Planner. Showing what was saved\(model.lastSyncAt.map { " at \(Format.time($0))" } ?? ""). \(error)")
        } else if !model.rejectedMoves.isEmpty {
            banner(systemImage: "arrow.uturn.backward", text: "Planner put \(model.rejectedMoves.count == 1 ? "a block" : "\(model.rejectedMoves.count) blocks") back: \(model.rejectedMoves.map(\.reason).joined(separator: " "))")
        }
    }

    private func banner(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.15))
    }
}

#Preview {
    ContentView()
        .environment(AppModel(calendarStore: InMemoryCalendarStore()))
}
