import AppKit
import Foundation

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum WindowLevelPref: String, CaseIterable, Identifiable {
    case top, normal, desktop
    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "Always on top"
        case .normal: "Normal"
        case .desktop: "Desktop only"
        }
    }

    var detail: String {
        switch self {
        case .top: "Floats above every window, including full-screen apps and all Spaces."
        case .normal: "Behaves like a regular window and can be covered."
        case .desktop: "Sits on the desktop behind all windows, like a widget."
        }
    }

    var level: NSWindow.Level {
        switch self {
        case .top: .statusBar
        case .normal: .normal
        case .desktop: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        }
    }
}

enum Edge: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ClearDone: String, CaseIterable, Identifiable {
    case midnight, day, never
    var id: String { rawValue }

    var label: String {
        switch self {
        case .midnight: "At midnight"
        case .day: "After 24 hours"
        case .never: "Never"
        }
    }
}

/// User preferences backed by UserDefaults. Observable so views and the panel controller react to changes.
@MainActor
@Observable
final class Preferences {
    private let d = AppDefaults

    var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance"); apply() } }
    var windowLevel: WindowLevelPref { didSet { d.set(windowLevel.rawValue, forKey: "windowLevel") } }
    var edge: Edge { didSet { d.set(edge.rawValue, forKey: "edge") } }
    /// Where the collapsed tab sits: vertical position (0 = bottom, 1 = top) and display.
    var tabY: Double { didSet { d.set(tabY, forKey: "tabY") } }
    var tabDisplay: Int { didSet { d.set(tabDisplay, forKey: "tabDisplay") } }
    var clearDone: ClearDone { didSet { d.set(clearDone.rawValue, forKey: "clearDone") } }
    var pinned: Bool { didSet { d.set(pinned, forKey: "pinned") } }

    // Built-in runner
    var runnerEnabled: Bool { didSet { d.set(runnerEnabled, forKey: "runnerEnabled") } }
    var runnerWeekdaysOnly: Bool { didSet { d.set(runnerWeekdaysOnly, forKey: "runnerWeekdaysOnly") } }
    var runnerIntervalMinutes: Int { didSet { d.set(runnerIntervalMinutes, forKey: "runnerIntervalMinutes") } }
    var runnerStartHour: Int { didSet { d.set(runnerStartHour, forKey: "runnerStartHour") } }
    var runnerEndHour: Int { didSet { d.set(runnerEndHour, forKey: "runnerEndHour") } }
    var runnerModel: String { didSet { d.set(runnerModel, forKey: "runnerModel") } }
    var runnerAllowedTools: String { didSet { d.set(runnerAllowedTools, forKey: "runnerAllowedTools") } }

    static let defaultAllowedTools = [
        "mcp__todo__*",
        "mcp__claude_ai_Slack__slack_read_*", "mcp__claude_ai_Slack__slack_search_*",
        "mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread", "mcp__claude_ai_Gmail__get_message",
        "mcp__claude_ai_Linear__list_*", "mcp__claude_ai_Linear__get_*",
        "mcp__claude_ai_Google_Calendar__list_events", "mcp__claude_ai_Google_Calendar__search_events",
    ].joined(separator: " ")

    init() {
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        windowLevel = WindowLevelPref(rawValue: d.string(forKey: "windowLevel") ?? "") ?? .top
        edge = Edge(rawValue: d.string(forKey: "edge") ?? "") ?? .right
        tabY = d.object(forKey: "tabY") as? Double ?? 0.5
        tabDisplay = d.integer(forKey: "tabDisplay")
        clearDone = ClearDone(rawValue: d.string(forKey: "clearDone") ?? "") ?? .midnight
        pinned = d.bool(forKey: "pinned")
        runnerEnabled = d.bool(forKey: "runnerEnabled")
        runnerWeekdaysOnly = d.object(forKey: "runnerWeekdaysOnly") as? Bool ?? true
        runnerIntervalMinutes = d.object(forKey: "runnerIntervalMinutes") as? Int ?? 120
        runnerStartHour = d.object(forKey: "runnerStartHour") as? Int ?? 8
        runnerEndHour = d.object(forKey: "runnerEndHour") as? Int ?? 18
        runnerModel = d.string(forKey: "runnerModel") ?? "sonnet"
        runnerAllowedTools = d.string(forKey: "runnerAllowedTools") ?? Self.defaultAllowedTools
        apply()
    }

    static let keys = ["appearance", "windowLevel", "edge", "tabY", "tabDisplay", "clearDone", "pinned", "runnerEnabled",
                       "runnerWeekdaysOnly", "runnerIntervalMinutes", "runnerStartHour", "runnerEndHour", "runnerModel",
                       "runnerAllowedTools", "runnerLastRun", "runnerLog", "setupComplete"]

    /// Forget every preference and return to defaults (used by Reset).
    func resetToDefaults() {
        for k in Self.keys { d.removeObject(forKey: k) }
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        windowLevel = WindowLevelPref(rawValue: d.string(forKey: "windowLevel") ?? "") ?? .top
        edge = Edge(rawValue: d.string(forKey: "edge") ?? "") ?? .right
        tabY = d.object(forKey: "tabY") as? Double ?? 0.5
        tabDisplay = d.integer(forKey: "tabDisplay")
        clearDone = ClearDone(rawValue: d.string(forKey: "clearDone") ?? "") ?? .midnight
        pinned = d.bool(forKey: "pinned")
        runnerEnabled = d.bool(forKey: "runnerEnabled")
        runnerWeekdaysOnly = d.object(forKey: "runnerWeekdaysOnly") as? Bool ?? true
        runnerIntervalMinutes = d.object(forKey: "runnerIntervalMinutes") as? Int ?? 120
        runnerStartHour = d.object(forKey: "runnerStartHour") as? Int ?? 8
        runnerEndHour = d.object(forKey: "runnerEndHour") as? Int ?? 18
        runnerModel = d.string(forKey: "runnerModel") ?? "sonnet"
        runnerAllowedTools = d.string(forKey: "runnerAllowedTools") ?? Self.defaultAllowedTools
        apply()
    }

    var setupComplete: Bool {
        get { d.bool(forKey: "setupComplete") }
        set { d.set(newValue, forKey: "setupComplete") }
    }

    func apply() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Human-readable schedule used in the setup prompt.
    var scheduleText: String {
        let days = runnerWeekdaysOnly ? "weekdays" : "every day"
        let every = runnerIntervalMinutes % 60 == 0 ? "\(runnerIntervalMinutes / 60) hours" : "\(runnerIntervalMinutes) minutes"
        return String(format: "%@, every %@ from %02d:00 to %02d:00", days, every, runnerStartHour, runnerEndHour)
    }
}
