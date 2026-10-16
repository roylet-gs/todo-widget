import AppKit
import SwiftUI

/// A modifier key, in the order macOS displays them.
enum Mod: String, Codable, CaseIterable, Identifiable, Comparable {
    case control, option, shift, command
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    var name: String { rawValue.capitalized }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    static func from(_ flags: NSEvent.ModifierFlags) -> Set<Mod> {
        Set(allCases.filter { flags.contains($0.flag) })
    }

    static func < (a: Mod, b: Mod) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// One key binding: a key plus modifiers, or a double tap of a modifier (global toggle only), optionally
/// while holding others (`mods`), e.g. hold ⌃ and double-tap ⌘.
/// `key` is a lowercased character ("e", "?") or a special key name ("up", "return", "space"…).
struct KeyBinding: Codable, Hashable {
    var key: String = ""
    var mods: [Mod] = []
    /// Virtual key code, kept so a global combo can be registered with the system.
    var code: UInt16?
    var doubleTap: Mod?

    init(_ key: String, _ mods: [Mod] = []) {
        self.key = key
        self.mods = mods.sorted()
        code = Self.specialCodes[key] ?? Self.letterCodes[key]
    }

    init(doubleTap: Mod, holding: [Mod] = []) {
        self.doubleTap = doubleTap
        mods = holding.filter { $0 != doubleTap }.sorted()
    }

    init?(event: NSEvent) {
        let name = Self.specialNames[event.keyCode]
        guard let key = name ?? event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        var mods = Mod.from(event.modifierFlags)
        // Shift is part of punctuation like "?" already.
        if name == nil, !key.unicodeScalars.allSatisfy(CharacterSet.letters.contains) { mods.remove(.shift) }
        self.key = key
        self.mods = mods.sorted()
        code = event.keyCode
    }

    // Equality ignores the key code (the same key recorded on different layouts is the same binding).
    static func == (a: KeyBinding, b: KeyBinding) -> Bool {
        a.key == b.key && Set(a.mods) == Set(b.mods) && a.doubleTap == b.doubleTap
    }

    func hash(into h: inout Hasher) {
        h.combine(key); h.combine(Set(mods)); h.combine(doubleTap)
    }

    var hasCommandOrControl: Bool { mods.contains(.command) || mods.contains(.control) }

    /// Compact form for key caps, e.g. "⌥⌘↑", "Space", "⌘⌘", "⌃⌘⌘".
    var display: String {
        if let m = doubleTap { return mods.sorted().map(\.symbol).joined() + m.symbol + m.symbol }
        return mods.sorted().map(\.symbol).joined() + keySymbol
    }

    /// Readable form for tooltips and accessibility, e.g. "Double-tap ⌘", "⌃ + double-tap ⌘".
    var spoken: String {
        if let m = doubleTap {
            return mods.isEmpty ? "Double-tap \(m.symbol)" : mods.sorted().map(\.symbol).joined() + " + double-tap \(m.symbol)"
        }
        return display
    }

    private var keySymbol: String {
        switch key {
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "return": "↩"
        case "delete": "⌫"
        case "forwarddelete": "⌦"
        case "space": "Space"
        case "escape": "Esc"
        case "tab": "⇥"
        case "home": "↖"
        case "end": "↘"
        case "pageup": "⇞"
        case "pagedown": "⇟"
        default: key.uppercased()
        }
    }

    /// For showing the binding next to a menu item.
    var keyboardShortcut: KeyboardShortcut? {
        guard doubleTap == nil else { return nil }
        let k: KeyEquivalent? = switch key {
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        case "return": .return
        case "delete": .delete
        case "forwarddelete": .deleteForward
        case "space": .space
        case "escape": .escape
        case "tab": .tab
        case "home": .home
        case "end": .end
        case "pageup": .pageUp
        case "pagedown": .pageDown
        default: key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
        guard let k else { return nil }
        var m: EventModifiers = []
        for mod in mods {
            switch mod {
            case .command: m.insert(.command)
            case .option: m.insert(.option)
            case .control: m.insert(.control)
            case .shift: m.insert(.shift)
            }
        }
        return KeyboardShortcut(k, modifiers: m)
    }

    private static let specialNames: [UInt16: String] = [
        126: "up", 125: "down", 123: "left", 124: "right", 36: "return", 76: "return", 51: "delete",
        117: "forwarddelete", 49: "space", 53: "escape", 48: "tab", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]
    private static let specialCodes: [String: UInt16] = {
        var m: [String: UInt16] = [:]
        for (c, n) in specialNames where m[n] == nil || c != 76 { m[n] = c }
        return m
    }()
    /// US layout codes, used when a binding wasn't recorded from a real key press.
    private static let letterCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43,
        ".": 47, "/": 44,
    ]
}

/// Where an action applies. The drawer shows either the list or one task's detail.
enum KeyScope {
    case global, list, detail, drawer

    func overlaps(_ o: KeyScope) -> Bool {
        if self == o { return true }
        if self == .global || o == .global { return true }
        return self == .drawer || o == .drawer
    }
}

enum KeyGroup: String, CaseIterable {
    case global = "Global"
    case navigate = "Moving around"
    case tasks = "Tasks"
    case drawer = "Drawer"
}

enum KeyAction: String, CaseIterable, Codable, Identifiable {
    case toggleWidget
    case previous, next, first, last, open, openSource, back
    case toggleDone, delete, reject, edit, save, moveUp, moveDown, priority1, priority2, priority3, newTask
    case search, toggleDoneSection, undo, redo, pin, runNow, settings, shortcuts

    /// The action that sets priority `p` (1–3).
    static func priority(_ p: UInt8) -> KeyAction { p <= 1 ? .priority1 : p == 2 ? .priority2 : .priority3 }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleWidget: "Show or hide the widget"
        case .previous: "Previous task"
        case .next: "Next task"
        case .first: "First task"
        case .last: "Last task"
        case .open: "Open task"
        case .openSource: "Open in source app"
        case .back: "Back / close drawer"
        case .toggleDone: "Mark done / reopen"
        case .delete: "Delete task"
        case .reject: "Reject an agent's task"
        case .edit: "Edit task"
        case .save: "Save edits"
        case .moveUp: "Move task up"
        case .moveDown: "Move task down"
        case .priority1: "Set priority P1"
        case .priority2: "Set priority P2"
        case .priority3: "Set priority P3"
        case .newTask: "New task"
        case .search: "Search tasks"
        case .toggleDoneSection: "Show or hide done tasks"
        case .undo: "Undo"
        case .redo: "Redo"
        case .pin: "Pin drawer open"
        case .runNow: "Run agent now"
        case .settings: "Settings"
        case .shortcuts: "Keyboard shortcuts"
        }
    }

    var group: KeyGroup {
        switch self {
        case .toggleWidget: .global
        case .previous, .next, .first, .last, .open, .openSource, .back: .navigate
        case .toggleDone, .delete, .reject, .edit, .save, .moveUp, .moveDown, .priority1, .priority2, .priority3, .newTask: .tasks
        case .search, .toggleDoneSection, .undo, .redo, .pin, .runNow, .settings, .shortcuts: .drawer
        }
    }

    var scope: KeyScope {
        switch self {
        case .toggleWidget: .global
        case .previous, .next, .first, .last, .open, .moveUp, .moveDown, .toggleDoneSection: .list
        case .edit, .save: .detail
        case .openSource, .toggleDone, .delete, .reject, .back, .newTask, .search, .priority1, .priority2, .priority3, .undo, .redo, .pin, .runNow, .settings, .shortcuts: .drawer
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .toggleWidget: KeyBinding(doubleTap: .command, holding: [.control])
        case .previous: KeyBinding("up")
        case .next: KeyBinding("down")
        case .first: KeyBinding("up", [.command])
        case .last: KeyBinding("down", [.command])
        case .open: KeyBinding("return")
        case .openSource: KeyBinding("o")
        case .back: KeyBinding("escape")
        case .toggleDone: KeyBinding("space")
        case .delete: KeyBinding("delete")
        case .reject: KeyBinding("delete", [.shift])
        case .edit: KeyBinding("e")
        case .save: KeyBinding("return", [.command])
        case .moveUp: KeyBinding("up", [.option, .command])
        case .moveDown: KeyBinding("down", [.option, .command])
        case .priority1: KeyBinding("1")
        case .priority2: KeyBinding("2")
        case .priority3: KeyBinding("3")
        case .newTask: KeyBinding("n", [.command])
        case .search: KeyBinding("f", [.command])
        case .toggleDoneSection: KeyBinding("d", [.command])
        case .undo: KeyBinding("z", [.command])
        case .redo: KeyBinding("z", [.shift, .command])
        case .pin: KeyBinding("p", [.command])
        case .runNow: KeyBinding("r", [.command])
        case .settings: KeyBinding(",", [.command])
        case .shortcuts: KeyBinding("?")
        }
    }
}

/// The user's key bindings: only overrides are stored; everything else uses the defaults.
struct Keymap: Codable, Equatable {
    var overrides: [String: KeyBinding] = [:]

    func binding(for a: KeyAction) -> KeyBinding { overrides[a.rawValue] ?? a.defaultBinding }

    func isDefault(_ a: KeyAction) -> Bool { binding(for: a) == a.defaultBinding }

    mutating func set(_ b: KeyBinding, for a: KeyAction) {
        overrides[a.rawValue] = b == a.defaultBinding ? nil : b
    }

    mutating func reset(_ a: KeyAction) { overrides[a.rawValue] = nil }

    /// The action a key press triggers in the drawer, given whether a task's detail is showing.
    func action(for b: KeyBinding, inDetail: Bool) -> KeyAction? {
        KeyAction.allCases.first { a in
            guard binding(for: a) == b else { return false }
            switch a.scope {
            case .global, .drawer: return true
            case .list: return !inDetail
            case .detail: return inDetail
            }
        }
    }

    /// Other actions that share this action's key and could fire in the same place.
    func conflicts(for a: KeyAction) -> [KeyAction] {
        let b = binding(for: a)
        return KeyAction.allCases.filter { $0 != a && binding(for: $0) == b && $0.scope.overlaps(a.scope) }
    }

    // Stored as a JSON string in the preferences.
    init() {}

    init(json: String?) {
        if let data = json?.data(using: .utf8), let m = try? JSONDecoder().decode(Keymap.self, from: data) { self = m }
    }

    var json: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
}

// MARK: - Showing keys in the UI

/// A small key cap, e.g. [⌘N].
struct KeyCap: View {
    let text: String
    var onAccent = false

    init(_ text: String, onAccent: Bool = false) {
        self.text = text
        self.onAccent = onAccent
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .frame(minWidth: 16)
            .background(onAccent ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(.fill.tertiary),
                        in: .rect(cornerRadius: 4))
            .foregroundStyle(onAccent ? AnyShapeStyle(Color.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

extension Preferences {
    func key(_ a: KeyAction) -> KeyBinding { keymap.binding(for: a) }

    /// "Mark done (Space)" — for tooltips and accessibility hints.
    func tooltip(_ title: String, _ a: KeyAction) -> String { "\(title) (\(key(a).spoken))" }
}

extension View {
    /// Tooltip and accessibility hint naming the action's current key.
    func keyHelp(_ prefs: Preferences, _ title: String, _ a: KeyAction) -> some View {
        help(prefs.tooltip(title, a)).accessibilityHint("Shortcut: \(prefs.key(a).spoken)")
    }

    /// `keyHelp` when there is a shortcut, else a plain tooltip.
    @ViewBuilder
    func optionalKeyHelp(_ prefs: Preferences, _ title: String, _ a: KeyAction?) -> some View {
        if let a { keyHelp(prefs, title, a) } else { help(title) }
    }

    /// Shows the binding next to a context-menu or menu item.
    @ViewBuilder
    func menuShortcut(_ prefs: Preferences, _ a: KeyAction) -> some View {
        if let s = prefs.key(a).keyboardShortcut { keyboardShortcut(s) } else { self }
    }
}
