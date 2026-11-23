import PlannerKit
import SwiftUI

/// Project colours. System colours adapt to light and dark mode on their own.
extension ProjectColor {
    var color: Color {
        switch self {
        case .amber: .yellow
        case .teal: .teal
        case .indigo: .indigo
        case .rose: .pink
        case .green: .green
        case .violet: .purple
        case .orange: .orange
        case .slate: .gray
        }
    }

    var name: String { rawValue.capitalized }
}

extension Optional where Wrapped == Project {
    /// The project's colour, or the neutral accent for unfiled work.
    var tint: Color { self?.color.color ?? .accentColor }
}

/// A small coloured capsule naming a project.
struct ProjectChip: View {
    let project: Project

    var body: some View {
        Text(project.label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(project.color.color)
            .background(project.color.color.opacity(0.15), in: Capsule())
    }
}
