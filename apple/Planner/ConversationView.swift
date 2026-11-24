import PlannerKit
import SwiftUI

/// Everything with one person as a chat: their emails on the left, yours on the right, a new
/// subject marked where a thread changes. Reply at the bottom; make a task or a follow-up above.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let person: InboxPerson

    @State private var conversations: [InboxConversation] = []
    @State private var loading = true
    @State private var draft = ""
    @State private var sending = false
    @State private var sentToast = false
    @State private var madeTask: String?
    @FocusState private var composing: Bool

    private var tasks: [PlannerTask] { model.tasks(for: person) }
    private var followUp: PlannerTask? { tasks.first { $0.waitingOn != nil } }
    /// Replies go to the most recent thread.
    private var replyThread: InboxConversation? { conversations.max { lastAt($0) < lastAt($1) } }

    private func lastAt(_ c: InboxConversation) -> Date { c.messages.last?.at ?? .distantPast }

    private struct Item: Identifiable {
        let message: InboxMessage
        let subject: String
        let newSubject: Bool
        var id: String { message.id }
    }

    private var items: [Item] {
        let all = conversations.flatMap { c in c.messages.map { ($0, c.subject, c.id) } }.sorted { $0.0.at < $1.0.at }
        var lastThread: String?
        return all.map { message, subject, thread in
            defer { lastThread = thread }
            return Item(message: message, subject: subject, newSubject: thread != lastThread)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    actions
                    if loading && conversations.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(items) { item in
                        if item.newSubject {
                            Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                        }
                        Bubble(message: item.message)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.pageBackground)
            .onChange(of: items.count) { _, _ in
                withAnimation(.planner) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .navigationTitle(person.name.isEmpty ? person.email : person.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .overlay(alignment: .top) {
            if let madeTask {
                Label(madeTask, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassSurface(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.planner, value: madeTask)
        .task { await load() }
    }

    private func load() async {
        loading = true
        var loaded: [InboxConversation] = []
        await withTaskGroup(of: InboxConversation?.self) { group in
            for thread in person.threads.prefix(6) {
                group.addTask { await model.conversation(thread.id) }
            }
            for await c in group { if let c { loaded.append(c) } }
        }
        conversations = loaded
        loading = false
        for thread in person.threads where thread.unread { await model.markRead(threadId: thread.id) }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let followUp {
                HStack(spacing: 10) {
                    Image(systemName: followUp.hasReply ? "envelope.open.fill" : "hourglass")
                        .foregroundStyle(followUp.hasReply ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(followUp.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(followUp.hasReply ? "They replied" : followUp.isWaiting ? "Waiting on them" : "Time to chase")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Got it") { Task { await model.gotIt(followUp); flash("Follow-up done") } }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                }
                .padding(12)
                .cardSurface(cornerRadius: 16)
            }
            FlowLayout(spacing: 8) {
                if let thread = replyThread {
                    chip("Make task", "checklist") {
                        if await model.makeTask(threadId: thread.id, kind: .task) != nil { flash("Task added") }
                    }
                    if followUp == nil {
                        chip("Wait for reply", "hourglass") {
                            if await model.makeTask(threadId: thread.id, kind: .followup) != nil { flash("Waiting on \(Nudge.firstName(person.name))") }
                        }
                    }
                    chip("Archive", "archivebox") {
                        for t in person.threads { await model.archive(threadId: t.id) }
                        dismiss()
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.75))
        }
        .buttonStyle(.pressable(scale: 0.94))
    }

    private func flash(_ text: String) {
        madeTask = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if madeTask == text { madeTask = nil }
        }
    }

    // MARK: Composer

    @ViewBuilder private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let followUp, draft.isEmpty, !followUp.hasReply {
                Button { draft = Nudge.text(for: followUp) } label: {
                    Label("Use a drafted nudge", systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.indigo.opacity(0.14), in: Capsule())
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
            }
            if sentToast {
                Label("Sent", systemImage: "paperplane.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.gmailCanReply ? "Reply to \(Nudge.firstName(person.name))" : "Reconnect Gmail to reply", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($composing)
                    .disabled(!model.gmailCanReply || replyThread == nil)
                    .padding(.vertical, 12)
                    .padding(.leading, 16)
                Button(action: send) {
                    Group {
                        if sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor, in: Circle())
                }
                .buttonStyle(.pressable(scale: 0.88))
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.gmailCanReply)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
                .accessibilityLabel("Send")
            }
            .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.planner, value: sentToast)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let thread = replyThread else { return }
        sending = true
        Task {
            if let updated = await model.reply(threadId: thread.id, text: text) {
                if let i = conversations.firstIndex(where: { $0.id == updated.id }) { conversations[i] = updated } else { conversations.append(updated) }
                draft = ""
                sentToast = true
                try? await Task.sleep(for: .seconds(1.5))
                sentToast = false
            }
            sending = false
        }
    }
}

/// One email as a chat bubble. Long ones fold, with a tap to see all of it.
private struct Bubble: View {
    let message: InboxMessage
    @State private var expanded = false

    private var long: Bool { message.text.count > 600 }

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 48) }
            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 4) {
                Text(message.text.isEmpty ? "(no text)" : message.text)
                    .font(.body)
                    .lineLimit(long && !expanded ? 12 : nil)
                    .foregroundStyle(message.fromMe ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.fromMe ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.cardBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .overlay {
                        if !message.fromMe {
                            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.cardBorder, lineWidth: 0.75)
                        }
                    }
                    .onTapGesture { if long { withAnimation(.planner) { expanded.toggle() } } }
                HStack(spacing: 4) {
                    if long { Text(expanded ? "Show less" : "Show all").fontWeight(.semibold) }
                    Text(message.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            }
            if !message.fromMe { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.fromMe ? "You" : message.from.name): \(message.text)")
    }
}
