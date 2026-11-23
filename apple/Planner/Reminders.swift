import Foundation
import PlannerKit
import UserNotifications

/// Local notifications at the start of Planner's blocks and when a follow-up is due.
/// Each device schedules its own from the synced state, so nothing extra runs on the server.
enum Reminders {
    private static let prefix = "planner."
    /// iOS keeps at most 64 pending notifications per app; leave room.
    private static let limit = 50

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    static func schedule(events: [CalEvent], tasks: [PlannerTask], projects: [Project]) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        await clear()

        let now = Date()
        let projectNames = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.label) })
        var requests: [(Date, UNNotificationRequest)] = []

        for event in events where event.isTaskBlock && !event.allDay && event.startAt > now {
            let content = UNMutableNotificationContent()
            content.title = "Time for: \(event.title)"
            let titles = event.isBatch ? event.taskIds.compactMap { id in tasks.first { $0.id == id }?.title } : []
            content.body = [
                event.projectId.flatMap { projectNames[$0] },
                "\(Format.time(event.startAt))–\(Format.time(event.endAt))",
                titles.isEmpty ? nil : titles.joined(separator: ", "),
            ].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            requests.append((event.startAt, request("\(prefix)block.\(event.id)", content, at: event.startAt)))
        }

        for task in tasks where task.isWaiting {
            guard let at = task.followUpAt, at > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Follow up with \(task.waitingOn ?? "them")"
            content.body = task.title
            content.sound = .default
            requests.append((at, request("\(prefix)followup.\(task.id)", content, at: at)))
        }

        for (_, r) in requests.sorted(by: { $0.0 < $1.0 }).prefix(limit) {
            try? await center.add(r)
        }
    }

    private static func request(_ id: String, _ content: UNNotificationContent, at date: Date) -> UNNotificationRequest {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
}
