import Foundation
import PlannerKit

/// The Gmail inbox, fetched on demand (not part of the synced state).
@MainActor
@Observable
final class InboxStore {
    private(set) var people: [InboxPerson] = []
    private(set) var loadedAt: Date?
    private(set) var loading = false
    var error: String?

    var unread: Int { people.reduce(0) { $0 + $1.unread } }

    func load(_ api: PlannerAPI?, force: Bool = false) async {
        guard let api, !loading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 30 { return }
        loading = true
        defer { loading = false }
        do {
            people = try await api.inbox()
            loadedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Updates the list locally after reading or archiving, so it reacts at once.
    func markRead(_ threadId: String) {
        for i in people.indices {
            if let t = people[i].threads.firstIndex(where: { $0.id == threadId }), people[i].threads[t].unread {
                people[i].threads[t].unread = false
                people[i].unread = max(0, people[i].unread - 1)
            }
        }
    }

    func remove(_ threadId: String) {
        for i in people.indices { people[i].threads.removeAll { $0.id == threadId } }
        people.removeAll { $0.threads.isEmpty }
    }

    func reset() {
        people = []
        loadedAt = nil
    }
}

extension AppModel {
    var gmail: GmailStatus? { state?.gmail }
    var gmailConnected: Bool { state?.gmail?.connected == true }
    var gmailCanReply: Bool { state?.gmail?.canReply == true }
    var inboxUnread: Int { gmailConnected ? inbox.unread : 0 }

    /// Open tasks with this person as the contact: follow-ups and anything made from their mail.
    func tasks(for person: InboxPerson) -> [PlannerTask] {
        person.taskIds.compactMap { task(id: $0) }.filter { !$0.isDone }
    }

    func loadInbox(force: Bool = false) async {
        guard gmailConnected else { return }
        await inbox.load(engine?.api, force: force)
    }

    func gmailLink() async -> URL? {
        guard let api = engine?.api else { return nil }
        do { return try await api.gmailLink() } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func conversation(_ threadId: String) async -> InboxConversation? {
        guard let api = engine?.api else { return nil }
        do { return try await api.thread(id: threadId) } catch {
            inbox.error = error.localizedDescription
            return nil
        }
    }

    func reply(threadId: String, text: String) async -> InboxConversation? {
        guard let api = engine?.api else { return nil }
        do {
            let updated = try await api.reply(threadId: threadId, text: text)
            await sync() // a waiting follow-up may have moved on
            await inbox.load(api, force: true)
            return updated
        } catch {
            inbox.error = error.localizedDescription
            return nil
        }
    }

    func markRead(threadId: String) async {
        inbox.markRead(threadId)
        guard let api = engine?.api else { return }
        try? await api.markRead(threadId: threadId)
    }

    func archive(threadId: String) async {
        inbox.remove(threadId)
        guard let api = engine?.api else { return }
        do { try await api.archive(threadId: threadId) } catch { inbox.error = error.localizedDescription }
    }

    @discardableResult
    func makeTask(threadId: String, kind: PlannerAPI.ThreadTaskKind) async -> PlannerTask? {
        guard let api = engine?.api else { return nil }
        do {
            let task = try await api.makeTask(threadId: threadId, kind: kind)
            await sync()
            await inbox.load(api, force: true)
            return task
        } catch {
            inbox.error = error.localizedDescription
            return nil
        }
    }
}
