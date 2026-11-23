import Foundation

/// Mirrors src/shared/checklist.ts: lines that start with a list marker become steps.
public enum Checklist {
    // "1. Balance the drawer", "2) Order mix", "- Primer", "* Tape", "[ ] Sand", "- [x] Done"
    // #/…/# literals work in Swift 5 mode without the bare-slash regex flag.
    private static let marker = #/^\s*(?:\d+[.)]|[-*•]|\[[ xX]\])\s+/#
    private static let item = #/^\s*(?:\d+[.)]|[-*•])?\s*(?:\[([ xX])\])?\s*(.+?)\s*$/#

    /// Splits notes into checklist steps and the prose that is left over.
    public static func fromNotes(_ notes: String) -> (items: [ChecklistItem], rest: String) {
        var items: [ChecklistItem] = []
        var rest: [Substring] = []
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard text.firstMatch(of: marker) != nil else {
                rest.append(line)
                continue
            }
            guard let m = text.wholeMatch(of: item) else { continue }
            let step = String(m.2).trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { continue }
            let checked = m.1.map { $0 == "x" || $0 == "X" } ?? false
            items.append(ChecklistItem(text: step, done: checked))
        }
        return (items, rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
