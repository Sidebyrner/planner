import AuthenticationServices
import PlannerKit
import SwiftUI

/// Gmail as a Messages-style list of people. Those you're waiting on sit on top, marked
/// Replied or Chase, so it's clear who needs an answer.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        Group {
            if model.gmailConnected {
                list
            } else {
                ScrollView { ConnectGmailCard().padding(16) }
                    .background(Color.pageBackground)
            }
        }
        .navigationTitle("Inbox")
        .navigationDestination(for: InboxPerson.self) { ConversationView(person: $0) }
        .task(id: model.gmailConnected) { await model.loadInbox() }
    }

    private func matches(_ p: InboxPerson) -> Bool {
        query.isEmpty || p.name.localizedCaseInsensitiveContains(query) || p.email.localizedCaseInsensitiveContains(query)
            || p.threads.contains { $0.subject.localizedCaseInsensitiveContains(query) }
    }

    private var list: some View {
        let people = model.inbox.people.filter(matches)
        let waiting = people.filter { !model.tasks(for: $0).filter { $0.waitingOn != nil }.isEmpty }
        let rest = people.filter { p in !waiting.contains { $0.id == p.id } }
        return List {
            if let error = model.inbox.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .onTapGesture { model.inbox.error = nil }
            }
            if model.gmailConnected && !model.gmailCanReply {
                ReconnectRow()
            }
            if people.isEmpty {
                Text(model.inbox.loading ? "Loading your inbox…" : query.isEmpty ? "No email in the last 30 days." : "No one matches.")
                    .foregroundStyle(.secondary)
            }
            if !waiting.isEmpty {
                Section("Waiting on") { ForEach(waiting) { row($0) } }
            }
            if !rest.isEmpty {
                Section(waiting.isEmpty ? "" : "Everyone else") { ForEach(rest) { row($0) } }
            }
        }
        .searchable(text: $query, prompt: "People or subjects")
        .refreshable { await model.loadInbox(force: true) }
        .animation(.planner, value: people.map(\.id))
    }

    private func row(_ person: InboxPerson) -> some View {
        NavigationLink(value: person) {
            PersonRow(person: person, tasks: model.tasks(for: person))
        }
        .swipeActions(edge: .leading) {
            if person.unread > 0 {
                Button { Task { for t in person.threads where t.unread { await model.markRead(threadId: t.id) } } } label: {
                    Label("Read", systemImage: "envelope.open")
                }
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if let latest = person.threads.first {
                Button { Task { await model.archive(threadId: latest.id) } } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(.indigo)
            }
        }
    }
}

/// One person: avatar, name, the latest subject and a line of it, and a follow-up tag.
private struct PersonRow: View {
    let person: InboxPerson
    let tasks: [PlannerTask]

    private var followUp: PlannerTask? { tasks.first { $0.waitingOn != nil } }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: person.name.isEmpty ? person.email : person.name, size: 46)
                .overlay(alignment: .topLeading) {
                    if person.unread > 0 {
                        Circle().fill(Color.accentColor).frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.cardBackground, lineWidth: 2))
                            .offset(x: -3, y: -1)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(person.name.isEmpty ? person.email : person.name)
                        .font(.body.weight(person.unread > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.relative(person.lastAt)).font(.caption).foregroundStyle(.secondary)
                }
                if let thread = person.threads.first {
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.subheadline.weight(person.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Text(thread.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let followUp { tag(followUp) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func tag(_ task: PlannerTask) -> some View {
        let (text, symbol, tint): (String, String, Color) =
            task.hasReply ? ("Replied · \(task.title)", "envelope.open.fill", .green)
            : task.isWaiting ? ("Waiting · \(task.title)", "hourglass", .secondary)
            : ("Chase · \(task.title)", "arrow.uturn.left", .red)
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .padding(.top, 2)
    }
}

/// Connect Gmail from the app: Google's sign-in sheet, then back here.
struct ConnectGmailCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    var reconnect = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(reconnect ? "Reconnect Gmail to reply" : "Your email, as conversations").font(.title3.weight(.bold))
                Text(reconnect
                     ? "Gmail is connected for reading only. Reconnect once to reply, archive and mark as read from here."
                     : "See your Primary inbox grouped by person, reply right here, and turn any email into a task or a follow-up. People you're waiting on stay on top, and Planner notices when they reply.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.gmail?.configured == false {
                    Text("Google isn't set up on your Planner server yet (GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET).")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Button(action: connect) {
                        HStack {
                            if connecting { ProgressView().tint(.white) }
                            Text(reconnect ? "Reconnect Gmail" : "Connect Gmail").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(connecting)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            }
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            guard let url = await model.gmailLink() else {
                error = model.actionError ?? "Couldn't reach your Planner server."
                model.actionError = nil
                return
            }
            do {
                let callback = try await webAuth.authenticate(using: url, callbackURLScheme: "planner", preferredBrowserSession: .shared)
                if let message = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "error" })?.value {
                    error = message
                    return
                }
                await model.sync()
                model.inbox.reset()
                await model.loadInbox(force: true)
            } catch {
                // Cancelled by the user: say nothing.
                if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { self.error = error.localizedDescription }
            }
        }
    }
}

private struct ReconnectRow: View {
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label("Reconnect Gmail to reply from here", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout.weight(.semibold))
        }
        .sheet(isPresented: $showing) {
            ScrollView { ConnectGmailCard(reconnect: true).padding(16) }
                .background(Color.pageBackground)
                .presentationDetents([.medium])
        }
    }
}
