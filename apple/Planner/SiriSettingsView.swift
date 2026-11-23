#if os(iOS)
import AppIntents
import SwiftUI

/// What you can say, and a link to the Shortcuts app.
struct SiriSettingsView: View {
    private let phrases: [(String, String, String)] = [
        ("plus.circle", "“Add a task in Planner”", "Then say it like the capture bar: “Order limes Friday #jays”, “@Sam send the invoice”."),
        ("clock", "“What's next in Planner”", "What you're in now and what's coming up."),
        ("wand.and.stars", "“Plan my day in Planner”", "Books today's free time for open tasks and reads back what it booked."),
        ("checkmark.circle", "“Mark a task done in Planner”", "Siri asks which one."),
        ("hourglass", "“Who am I waiting on in Planner”", "People who owe you something, and follow-ups that are due."),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(phrases, id: \.1) { icon, phrase, detail in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phrase).font(.body.weight(.semibold))
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: icon).foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Say to Siri")
            } footer: {
                Text("These work as soon as Planner is installed. You can also run them from Spotlight, the Action button or the Shortcuts app.")
            }

            Section {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Siri & Shortcuts")
    }
}
#endif
