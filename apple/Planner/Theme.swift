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

    /// Text that reads on a solid tile of this colour: dark on the light ones.
    var inkOnFill: Color {
        switch self {
        case .amber, .green, .teal, .orange: Color.black.opacity(0.82)
        default: .white
        }
    }
}

extension Optional where Wrapped == Project {
    /// The project's colour, or the neutral accent for unfiled work.
    var tint: Color { self?.color.color ?? .accentColor }
}

extension Color {
    /// A colour that differs in light and dark mode.
    init(light: Color, dark: Color) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? NSColor(dark) : NSColor(light) })
        #endif
    }

    /// The floating add and voice buttons and the Today tab marker: near-black in light mode,
    /// near-white in dark. Kept apart from the blue accent and the project colours.
    static let ink = Color(light: Color(red: 0.11, green: 0.11, blue: 0.13), dark: Color(red: 0.95, green: 0.95, blue: 0.97))
    /// Glyphs on ink.
    static let onInk = Color(light: .white, dark: Color(red: 0.08, green: 0.08, blue: 0.1))
}

extension View {
    /// Liquid Glass on iOS 26 and macOS 26, a frosted material with a hairline and shadow before.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        }
    }
}

extension Animation {
    /// The one spring used for list and card changes, so the app moves consistently.
    static let planner = Animation.snappy(duration: 0.32, extraBounce: 0.08)
}

/// Shrinks a little while pressed, for cards and big buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
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
