import AppKit
import SwiftUI

/// One palette (light or dark) of a theme. Each role is a `#RRGGBB` hex string; `nil` means the system default.
struct ThemeColors: Codable, Equatable {
    /// Buttons, unread dots, selection, the "new" chip.
    var accent: String?
    /// Tints the drawer's glass and the windows' background.
    var background: String?
    /// Primary text; secondary and tertiary text derive from it.
    var text: String?
    /// The P1 priority bar and chip.
    var priority: String?
    /// The fill of a completed task's circle.
    var done: String?

    enum Role: String, CaseIterable, Identifiable {
        case accent, background, text, priority, done
        var id: String { rawValue }
        var label: String {
            switch self {
            case .accent: "Accent"
            case .background: "Background"
            case .text: "Text"
            case .priority: "High priority"
            case .done: "Done"
            }
        }
        var detail: String {
            switch self {
            case .accent: "Buttons, unread dots, selection"
            case .background: "Tints the drawer and windows"
            case .text: "Titles and body text"
            case .priority: "P1 tasks"
            case .done: "Completed tasks"
            }
        }
    }

    subscript(role: Role) -> String? {
        get {
            switch role {
            case .accent: accent
            case .background: background
            case .text: text
            case .priority: priority
            case .done: done
            }
        }
        set {
            switch role {
            case .accent: accent = newValue
            case .background: background = newValue
            case .text: text = newValue
            case .priority: priority = newValue
            case .done: done = newValue
            }
        }
    }

    /// What each role looks like when it isn't set.
    static func fallback(_ role: Role, dark: Bool) -> NSColor {
        switch role {
        case .accent: .controlAccentColor
        case .background: dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        case .text: dark ? .white : NSColor(white: 0.1, alpha: 1)
        case .priority: .systemOrange
        case .done: .systemGreen
        }
    }

    func nsColor(_ role: Role, dark: Bool) -> NSColor {
        self[role].flatMap(NSColor.init(hex:)) ?? Self.fallback(role, dark: dark)
    }
}

struct Theme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// The appearance this theme is designed for; selecting the theme switches to it. `nil` keeps the user's choice.
    var appearance: Appearance?
    var light: ThemeColors
    var dark: ThemeColors

    var isBuiltIn: Bool { Theme.presets.contains { $0.id == id } }

    func colors(dark isDark: Bool) -> ThemeColors { isDark ? dark : light }

    /// A role as a color that follows the current light/dark appearance, or `nil` if neither palette sets it.
    func dynamic(_ role: ThemeColors.Role) -> Color? {
        guard light[role] != nil || dark[role] != nil else { return nil }
        let l = light.nsColor(role, dark: false), d = dark.nsColor(role, dark: true)
        return Color(nsColor: NSColor(name: nil) { $0.isDark ? d : l })
    }

    var accent: Color { dynamic(.accent) ?? .accentColor }
    var background: Color? { dynamic(.background) }
    var text: Color? { dynamic(.text) }
    var priority: Color { dynamic(.priority) ?? .orange }
    var done: Color { dynamic(.done) ?? .green }

    /// Colors for a task priority: P1 stands out, P2 takes the accent, the rest recede.
    func priority(_ p: UInt8) -> Color {
        switch p {
        case 1: priority
        case 2: accent
        default: .secondary
        }
    }

    /// How strongly the background role tints glass and windows.
    static let glassTint = 0.55
    static let windowTint = 0.35

    static let `default` = Theme(id: "default", name: "Default", appearance: nil, light: ThemeColors(), dark: ThemeColors())

    static let presets: [Theme] = [
        .default,
        Theme(id: "graphite", name: "Graphite", appearance: nil,
              light: ThemeColors(accent: "#4F5866", background: "#E4E6EA", text: "#1D2127", priority: "#B4561F", done: "#6E8F74"),
              dark: ThemeColors(accent: "#8592A6", background: "#25282D", text: "#E4E7EB", priority: "#E08A50", done: "#7FA886")),
        Theme(id: "ocean", name: "Ocean", appearance: nil,
              light: ThemeColors(accent: "#0A6FB8", background: "#D7EAF7", text: "#0F2A3D", priority: "#D2591F", done: "#2E9C8A"),
              dark: ThemeColors(accent: "#2E8FD6", background: "#0D2233", text: "#DCEBF5", priority: "#F08A4B", done: "#3FB8A3")),
        Theme(id: "forest", name: "Forest", appearance: nil,
              light: ThemeColors(accent: "#2F7D4A", background: "#DFEDDF", text: "#1C2B20", priority: "#C0602A", done: "#5E9C5A"),
              dark: ThemeColors(accent: "#3F9E60", background: "#15241A", text: "#DDEBDF", priority: "#E8955A", done: "#6FBF73")),
        Theme(id: "sunset", name: "Sunset", appearance: nil,
              light: ThemeColors(accent: "#C9471F", background: "#FBE3D3", text: "#3A1E14", priority: "#B8325A", done: "#C98A2E"),
              dark: ThemeColors(accent: "#E8643A", background: "#2B1712", text: "#F6E3D9", priority: "#FF6B8E", done: "#E0A040")),
        Theme(id: "rose", name: "Rosé", appearance: nil,
              light: ThemeColors(accent: "#B83C6F", background: "#F8E1EA", text: "#3A1A28", priority: "#D2591F", done: "#9C6FB5"),
              dark: ThemeColors(accent: "#D25A8C", background: "#2A151F", text: "#F5DDE7", priority: "#F49A5A", done: "#B992D0")),
        Theme(id: "solarized", name: "Solarized", appearance: nil,
              light: ThemeColors(accent: "#268BD2", background: "#FDF6E3", text: "#073642", priority: "#CB4B16", done: "#859900"),
              dark: ThemeColors(accent: "#268BD2", background: "#002B36", text: "#EEE8D5", priority: "#CB4B16", done: "#859900")),
        Theme(id: "midnight", name: "Midnight", appearance: .dark,
              light: ThemeColors(accent: "#5A55D6", background: "#E6E6F5", text: "#1B1A33", priority: "#D14E7A", done: "#3D9A8B"),
              dark: ThemeColors(accent: "#7A73F5", background: "#12131F", text: "#E4E4F2", priority: "#FF7AA2", done: "#4FC3A1")),
    ]

    /// A new custom theme that starts from this one's colors.
    func duplicate(named name: String) -> Theme {
        Theme(id: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: name, appearance: appearance, light: light, dark: dark)
    }
}

// MARK: - Contrast

enum Contrast {
    /// WCAG contrast ratio between two colors (1...21).
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: NSColor) -> Double {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }
}

// MARK: - Hex

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        func b(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var theme: Theme = .default
}

private struct Themed: ViewModifier {
    let prefs: Preferences

    func body(content: Content) -> some View {
        let theme = prefs.theme
        content
            .environment(\.theme, theme)
            .tint(theme.accent)
            .foregroundStyle(theme.text.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
    }
}

extension View {
    /// Applies the selected theme. Every window's root view gets this.
    func themed(_ prefs: Preferences) -> some View { modifier(Themed(prefs: prefs)) }

    /// Tints a window's background with the theme (the drawer gets this through its glass instead).
    func themedWindowBackground() -> some View { modifier(ThemedWindowBackground()) }
}

private struct ThemedWindowBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background {
            // In e2e mode `e2eOpaque` paints it solid instead.
            if let bg = theme.background, !E2E.flatGlass {
                bg.opacity(Theme.windowTint).ignoresSafeArea()
            }
        }
    }
}
