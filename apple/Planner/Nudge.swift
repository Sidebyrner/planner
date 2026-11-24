import PlannerKit
import SwiftUI
#if canImport(MessageUI)
import MessageUI
#endif

/// A short, friendly check-in to send someone you're waiting on, written from the task.
enum Nudge {
    enum Channel: String, Identifiable, Hashable {
        case message, email
        var id: String { rawValue }
    }

    static func firstName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    /// "Hi Sam, just checking in on the backsplash quote. Any update? Thanks!"
    static func text(for task: PlannerTask) -> String {
        let who = task.waitingOn.map { "Hi \(firstName($0))" } ?? "Hi"
        let topic = topicPhrase(task.title)
        let since = task.createdAt.formatted(.dateTime.weekday(.wide))
        let waitedLong = Date().timeIntervalSince(task.createdAt) > 6 * 86_400
        let ask = waitedLong ? "Is there anything you need from me to move it along?" : "Any update when you get a chance?"
        let opener = waitedLong ? "just following up on \(topic)" : "just checking in on \(topic) from \(since)"
        return "\(who), \(opener). \(ask) Thanks!"
    }

    static func subject(for task: PlannerTask) -> String {
        "Following up: \(task.title)"
    }

    /// Turns a task title into something that reads in a sentence: "Get quote from Sam" → "the quote".
    static func topicPhrase(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        for prefix in ["waiting on ", "waiting for ", "follow up on ", "follow up with ", "hear back about ", "get ", "chase "] where lower.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            break
        }
        if let from = t.range(of: " from ", options: .caseInsensitive) { t = String(t[..<from.lowerBound]) }
        guard !t.isEmpty else { return "this" }
        // Keep the task's capitalisation (it's often a name), except for a leading article.
        let lowered = t.lowercased()
        for article in ["the ", "a ", "an ", "my ", "your ", "our "] where lowered.hasPrefix(article) {
            return article + t.dropFirst(article.count)
        }
        return "the " + t
    }
}

/// Write the nudge, then send it by Messages or Mail. When the app can tell it was sent, the
/// follow-up is pushed back two days on its own ("chased"), with Undo.
struct NudgeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let taskId: String
    var channel: Nudge.Channel?
    /// Called after a send (or "Mark as chased"), so the Follow-up Round can move on.
    var onChased: (() -> Void)?

    @State private var draft = ""
    @State private var composing: Nudge.Channel?
    @State private var chasedAt: Date?
    @State private var before: PlannerTask?
    @State private var openedExternally = false

    private var task: PlannerTask? { model.task(id: taskId) }
    private var contact: Contact? {
        guard let task else { return nil }
        return task.contact ?? model.people.first { $0.id == (task.waitingOn ?? "").lowercased() }?.contact
    }
    private var phone: String? { contact?.phone?.filter { $0.isNumber || $0 == "+" }.nilIfEmpty }
    private var email: String? { contact?.email?.trimmingCharacters(in: .whitespaces).nilIfEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let task {
                        HStack(spacing: 12) {
                            Avatar(name: task.waitingOn ?? "?", size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.waitingOn ?? "Someone").font(.headline)
                                Text(task.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Card(title: "Your nudge", symbol: "text.bubble", tint: .indigo, accessory: {
                            Button("Rewrite") { withAnimation(.planner) { draft = Nudge.text(for: task) } }
                                .font(.caption.weight(.semibold))
                        }) {
                            TextEditor(text: $draft)
                                .frame(minHeight: 110)
                                .scrollContentBackground(.hidden)
                                .font(.body)
                        }
                        if let chasedAt {
                            chasedBanner(chasedAt)
                        } else {
                            sendButtons
                        }
                    } else {
                        Text("This follow-up is gone.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(Color.pageBackground)
            .navigationTitle("Nudge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(chasedAt == nil ? "Cancel" : "Done") { dismiss() } }
            }
            .onAppear {
                guard draft.isEmpty, let task else { return }
                draft = Nudge.text(for: task)
                before = task
                // Opened from a notification button: go straight to that app.
                if let channel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { send(channel) } }
            }
            #if os(iOS)
            .sheet(item: $composing) { channel in
                ComposeView(channel: channel, to: channel == .message ? phone ?? "" : email ?? "", subject: task.map(Nudge.subject) ?? "", body: draft) { sent in
                    composing = nil
                    if sent { Task { await markChased() } }
                }
                .ignoresSafeArea()
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    @ViewBuilder private var sendButtons: some View {
        VStack(spacing: 10) {
            if phone != nil {
                Button { send(.message) } label: {
                    Label("Send as Message", systemImage: "message.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            if email != nil {
                Button { send(.email) } label: {
                    Label("Send as Email", systemImage: "envelope.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if phone == nil && email == nil {
                Text("No phone or email saved for \(task?.waitingOn ?? "them"). Copy the nudge, or add their details on the task.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { copy() } label: { Label("Copy Nudge", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            if openedExternally {
                Button { Task { await markChased() } } label: {
                    Label("I sent it — mark as chased", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private func chasedBanner(_ next: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                .symbolEffect(.bounce, value: next)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chased").font(.headline)
                Text("Checking again \(next.formatted(.dateTime.weekday(.wide))).").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { Task { await undo() } }.buttonStyle(.bordered)
        }
        .padding(14)
        .cardSurface(cornerRadius: 16)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .sensoryFeedback(.success, trigger: chasedAt)
    }

    private func send(_ channel: Nudge.Channel) {
        #if os(iOS)
        if channel == .message, MFMessageComposeViewController.canSendText() { composing = .message; return }
        if channel == .email, MFMailComposeViewController.canSendMail() { composing = .email; return }
        #endif
        // No in-app composer (Mac, or Mail not set up): hand off to Messages or Mail.
        guard let url = externalURL(channel) else { return }
        openURL(url)
        openedExternally = true
    }

    private func externalURL(_ channel: Nudge.Channel) -> URL? {
        switch channel {
        case .message:
            guard let phone else { return nil }
            var c = URLComponents()
            c.scheme = "sms"
            c.path = phone
            c.queryItems = [URLQueryItem(name: "body", value: draft)]
            return c.url
        case .email:
            guard let email else { return nil }
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = email
            c.queryItems = [URLQueryItem(name: "subject", value: task.map(Nudge.subject) ?? ""), URLQueryItem(name: "body", value: draft)]
            return c.url
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = draft
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft, forType: .string)
        #endif
        openedExternally = true
    }

    private func markChased() async {
        guard let task else { return }
        await model.snooze(task, days: 2)
        withAnimation(.planner) { chasedAt = model.task(id: taskId)?.followUpAt ?? Date() }
        onChased?()
    }

    private func undo() async {
        guard let before, let task else { return }
        if await model.update(task, TaskPatch(status: before.status, followUpAt: .some(before.followUpAt))) {
            withAnimation(.planner) { chasedAt = nil }
        }
    }
}

/// A round initial in a coloured disc.
struct Avatar: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.indigo.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if os(iOS)
/// Messages or Mail inside the app, so Planner hears whether it was sent.
struct ComposeView: UIViewControllerRepresentable {
    let channel: Nudge.Channel
    let to: String
    let subject: String
    let body: String
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        switch channel {
        case .message:
            let vc = MFMessageComposeViewController()
            vc.recipients = [to]
            vc.body = body
            vc.messageComposeDelegate = context.coordinator
            return vc
        case .email:
            let vc = MFMailComposeViewController()
            vc.setToRecipients([to])
            vc.setSubject(subject)
            vc.setMessageBody(body, isHTML: false)
            vc.mailComposeDelegate = context.coordinator
            return vc
        }
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result == .sent)
        }
    }
}
#endif
