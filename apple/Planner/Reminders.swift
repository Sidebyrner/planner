import Foundation
import PlannerKit
import UserNotifications

/// Local notifications at the start of Planner's blocks and when a follow-up is due.
/// Each device schedules its own from the synced state, so nothing extra runs on the server.
enum Reminders {
    private static let prefix = "planner."
    /// iOS keeps at most 64 pending notifications per app; leave room.
    private static let limit = 50

    static let followUpCategory = "planner.followup"
    private static let notifiedRepliesKey = "planner.notifiedReplies"

    enum Action: String {
        case message = "planner.followup.message"
        case email = "planner.followup.email"
        case snooze = "planner.followup.snooze"
        case gotIt = "planner.followup.gotit"
    }

    /// Message, Email, Snooze and Got it on a follow-up notification.
    static func registerCategories() {
        let actions = [
            UNNotificationAction(identifier: Action.message.rawValue, title: "Message", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "message")),
            UNNotificationAction(identifier: Action.email.rawValue, title: "Email", options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "envelope")),
            UNNotificationAction(identifier: Action.snooze.rawValue, title: "Check again in 2 days", options: [], icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath")),
            UNNotificationAction(identifier: Action.gotIt.rawValue, title: "Got it", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark")),
        ]
        let category = UNNotificationCategory(identifier: followUpCategory, actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

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
            content.categoryIdentifier = followUpCategory
            content.userInfo = ["taskId": task.id]
            requests.append((at, request("\(prefix)followup.\(task.id)", content, at: at)))
        }

        for (_, r) in requests.sorted(by: { $0.0 < $1.0 }).prefix(limit) {
            try? await center.add(r)
        }

        // New replies found by the server: tell once, right away.
        var told = Set(UserDefaults.standard.stringArray(forKey: notifiedRepliesKey) ?? [])
        for task in tasks where task.hasReply {
            guard let at = task.repliedAt, now.timeIntervalSince(at) < 2 * 86_400 else { continue }
            let key = "\(task.id)@\(Int(at.timeIntervalSince1970))"
            guard !told.contains(key) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(task.waitingOn ?? "They") replied"
            content.body = [task.title, task.replySnippet].compactMap { $0 }.joined(separator: " — ")
            content.sound = .default
            content.categoryIdentifier = followUpCategory
            content.userInfo = ["taskId": task.id]
            try? await center.add(UNNotificationRequest(identifier: "\(prefix)reply.\(task.id)", content: content, trigger: nil))
            told.insert(key)
        }
        UserDefaults.standard.set(Array(told.suffix(200)), forKey: notifiedRepliesKey)
    }

    private static func request(_ id: String, _ content: UNNotificationContent, at date: Date) -> UNNotificationRequest {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
}

/// Handles taps on reminder buttons. Message and Email open the drafted nudge; Snooze and Got it
/// update the task without opening the app.
@MainActor
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    weak var model: AppModel?
    weak var router: Router?

    func attach(model: AppModel, router: Router) {
        self.model = model
        self.router = router
        Reminders.registerCategories()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let taskId = response.notification.request.content.userInfo["taskId"] as? String else { return }
        await handle(action: action, taskId: taskId)
    }

    private func handle(action: String, taskId: String) async {
        guard let model else { return }
        if model.state == nil { await model.start() }
        guard let task = model.task(id: taskId) else { return }
        switch Reminders.Action(rawValue: action) {
        case .message: router?.open(.nudge(taskId: taskId, channel: .message))
        case .email: router?.open(.nudge(taskId: taskId, channel: .email))
        case .snooze: await model.snooze(task, days: 2)
        case .gotIt: await model.gotIt(task)
        case nil: router?.open(.nudge(taskId: taskId))
        }
    }
}
