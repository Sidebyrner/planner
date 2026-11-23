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

/// Seven equal circles, Monday first. ISO weekdays (1 = Monday) in and out.
struct WeekdayPicker: View {
    @Binding var days: [Int]
    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let names = Calendar.current.weekdaySymbols // Sunday first

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    days = on ? days.filter { $0 != day } : (days + [day]).sorted()
                } label: {
                    Text(Self.letters[day - 1])
                        .font(.callout.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Self.names[day % 7])
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
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
