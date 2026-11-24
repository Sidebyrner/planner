import PlannerKit
import SwiftUI

/// The floating bar on Tasks: one field that finds as you type and adds on return, with the
/// mic and + beside it. While typing, a card above it offers "Add …" (with how Planner read it)
/// and, after a #, the matching projects.
struct TaskSearchBar: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// How many open tasks match what's typed.
    let matches: Int

    @State private var preview: Captured?
    @State private var saving = false
    @State private var added: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The word being typed if it starts with #, for project suggestions.
    private var projectQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("#") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    private var projectSuggestions: [Project] {
        guard let q = projectQuery else { return [] }
        return model.liveProjects.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.tag.lowercased().hasPrefix(q) }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(spacing: 10) {
            if focused.wrappedValue && (!trimmed.isEmpty || added != nil) {
                suggestions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.planner, value: focused.wrappedValue)
        .animation(.planner, value: trimmed.isEmpty)
        .animation(.planner, value: projectSuggestions.map(\.id))
        .task(id: trimmed) {
            guard !trimmed.isEmpty else {
                preview = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            preview = await model.preview(trimmed)
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find or add a task", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .submitLabel(.done)
                .onSubmit(add)
                .disabled(saving)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
            if focused.wrappedValue {
                Button { focused.wrappedValue = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")
            } else {
                Button { router.open(.voice) } label: {
                    Image(systemName: "mic.fill").foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speak a task")
            }
            Button {
                if trimmed.isEmpty { router.open(.newTask) } else { add() }
            } label: {
                Group {
                    if saving { ProgressView().tint(Color.onInk) } else { Image(systemName: "plus").font(.body.weight(.bold)) }
                }
                .foregroundStyle(Color.onInk)
                .frame(width: 36, height: 36)
                .background(Color.ink, in: Circle())
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel(trimmed.isEmpty ? "New task" : "Add \(trimmed)")
        }
        .font(.body)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 50)
        .glassSurface(Capsule(style: .continuous), interactive: true)
    }

    @ViewBuilder private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let added {
                Label("Added “\(added)”", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(14)
            } else {
                ForEach(projectSuggestions) { project in
                    Button { pick(project) } label: {
                        HStack(spacing: 10) {
                            Text(project.emoji.isEmpty ? "#" : project.emoji)
                                .frame(width: 30, height: 30)
                                .background(project.color.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name).font(.subheadline.weight(.semibold))
                                Text("#\(project.tag)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 54)
                }
                Button(action: add) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add “\(trimmed)”").font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let preview {
                                Text(Format.captured(preview, projectName: model.project(id: preview.projectId)?.label))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("return").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                Text(matches == 0 ? "No tasks match" : "\(matches) matching task\(matches == 1 ? "" : "s") above")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func pick(_ project: Project) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        text = (words + ["#\(project.tag) "]).joined(separator: " ").trimmingCharacters(in: .init(charactersIn: " ")) + " "
    }

    private func add() {
        let line = trimmed
        guard !line.isEmpty, !saving else { return }
        saving = true
        Task {
            if await model.capture(line) {
                text = ""
                preview = nil
                withAnimation(.planner) { added = line }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.planner) { added = nil }
            }
            saving = false
        }
    }
}
