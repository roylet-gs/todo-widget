import AppKit
import SwiftUI

/// End-to-end test mode, enabled by launching with `TODO_E2E_DIR=<dir>` (see `e2e/run.py`).
///
/// In this mode the app:
/// - keeps preferences in a separate, freshly cleared defaults suite (your real settings are untouched;
///   the runner also points `TODO_DB` at a throwaway database),
/// - draws glass as solid fills so window snapshots are legible without Screen Recording permission,
/// - skips network update checks, notifications and the built-in runner timer,
/// - executes JSON commands dropped into the directory as `<id>.cmd.json`, answering in `<id>.res.json`.
enum E2E {
    static let dir: URL? = ProcessInfo.processInfo.environment["TODO_E2E_DIR"].map { URL(fileURLWithPath: $0) }
    static var enabled: Bool { dir != nil }
    /// Solid stand-ins for Liquid Glass (offscreen snapshots can't render the glass backdrop).
    static var flatGlass: Bool { enabled }

    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard enabled else { return .standard }
        let suite = "com.todowidget.app.e2e"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "setupComplete")
        return d
    }()
}

/// All persisted preferences and app state go through this (the e2e suite in test mode).
var AppDefaults: UserDefaults { E2E.defaults }

// MARK: - Glass that degrades to solid fills in e2e mode

extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        if E2E.flatGlass {
            self
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        } else {
            self.glassEffect(glass, in: shape)
        }
    }

    /// Window and sidebar backgrounds are materials that offscreen snapshots don't draw.
    @ViewBuilder
    func e2eOpaque(_ color: NSColor = .windowBackgroundColor) -> some View {
        if E2E.flatGlass {
            self.scrollContentBackground(.hidden).background(Color(nsColor: color))
        } else {
            self
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        switch (E2E.flatGlass, prominent) {
        case (true, true): self.buttonStyle(.borderedProminent)
        case (true, false): self.buttonStyle(.bordered)
        case (false, true): self.buttonStyle(.glassProminent)
        case (false, false): self.buttonStyle(.glass)
        }
    }
}

// MARK: - Command channel

@MainActor
final class E2EServer {
    private let dir: URL
    private let services: AppServices
    private var source: DispatchSourceFileSystemObject?
    private var poll: Timer?
    private var dragStart: NSPoint?
    private var resizeStart: NSPoint?

    init(dir: URL, services: AppServices) {
        self.dir = dir
        self.services = services
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        // Belt and braces: directory events can coalesce.
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        write(["ready": true, "pid": Int(ProcessInfo.processInfo.processIdentifier)], to: dir.appendingPathComponent("ready.json"))
    }

    private func drain() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.lastPathComponent.hasSuffix(".cmd.json") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: f) else { continue }
            try? FileManager.default.removeItem(at: f)
            let id = String(f.lastPathComponent.dropLast(".cmd.json".count))
            var result: [String: Any]
            do {
                let cmd = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                result = try handle(cmd)
                result["ok"] = true
            } catch {
                result = ["ok": false, "error": "\(error)"]
            }
            write(result, to: dir.appendingPathComponent("\(id).res.json"))
        }
    }

    private func write(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = url.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private func task(_ cmd: [String: Any]) throws -> TodoTask {
        let title = cmd["title"] as? String ?? ""
        let m = services.model
        guard let t = (m.open + m.done).first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
            throw Failure(description: "no task matching '\(title)'")
        }
        return t
    }

    private func handle(_ cmd: [String: Any]) throws -> [String: Any] {
        let s = services
        switch cmd["cmd"] as? String ?? "" {
        case "state":
            return state()
        case "reload":
            s.model.reload()
        case "open_drawer":
            s.drawer.open()
        case "close_drawer":
            s.drawer.close()
        case "click_outside":
            s.drawer.handleOutsideClick()
        case "select":
            s.model.select(try task(cmd))
        case "back":
            s.model.select(nil)
        case "toggle_done":
            s.model.toggleDone(try task(cmd))
        case "move":
            s.model.move(try task(cmd).id, to: cmd["index"] as? Int ?? 0)
        case "add":
            s.model.add(cmd["title"] as? String ?? "")
        case "undo":
            s.model.undo()
        case "redo":
            s.model.redo()
        case "dismiss_runs":
            s.model.dismissRecentRuns()
        case "set_schedule":
            let c = ScheduleConfig(weekdaysOnly: cmd["weekdaysOnly"] as? Bool ?? true,
                                   startHour: UInt8(cmd["startHour"] as? Int ?? 9),
                                   endHour: UInt8(cmd["endHour"] as? Int ?? 17),
                                   intervalMinutes: UInt32(cmd["intervalMinutes"] as? Int ?? 60))
            try s.model.store.setSchedule(schedule: c)
            s.model.reload()
        case "set_pref":
            try setPref(cmd["key"] as? String ?? "", cmd["value"])
        case "settings":
            s.showSettings(tab: SettingsTab(rawValue: cmd["tab"] as? String ?? "general") ?? .general)
        case "close_settings":
            s.closeSettings()
        case "setup":
            s.showSetup(step: cmd["step"] as? Int ?? 0)
        case "close_setup":
            s.closeSetup()
        case "drag_begin":
            dragStart = NSPoint(x: s.drawer.tabFrame.midX, y: s.drawer.tabFrame.midY)
            s.drawer.simulatedMouse = dragStart
            s.drawer.dragTab()  // the gesture's first event establishes the grab point
        case "drag_move":
            guard let start = dragStart else { throw Failure(description: "drag_begin first") }
            let p = NSPoint(x: start.x + (cmd["dx"] as? Double ?? 0), y: start.y + (cmd["dy"] as? Double ?? 0))
            s.drawer.simulatedMouse = p
            s.drawer.dragTab()
        case "drag_end":
            s.drawer.endTabDrag()
            dragStart = nil
        case "key":
            // Goes through the same dispatcher as real key presses in the drawer.
            let b = KeyBinding(cmd["key"] as? String ?? "", mods(cmd["modifiers"]))
            let handled = s.drawer.keys.handle(b)
            var r = state()
            r["handled"] = handled
            return r
        case "focus_quick_add":
            s.drawer.keys.perform(.newTask)
        case "modifier_events":
            // Synthetic modifier presses for the double-tap detector: "down", "up" or "key", 50 ms apart.
            let m = Mod(rawValue: cmd["modifier"] as? String ?? "command") ?? .command
            var t = ProcessInfo.processInfo.systemUptime
            for e in cmd["events"] as? [String] ?? [] {
                t += 0.05
                switch e {
                case "down": s.hotkey.flagsChanged([m], at: t)
                case "up": s.hotkey.flagsChanged([], at: t)
                default: s.hotkey.keyDown()
                }
            }
        case "set_keybinding":
            guard let a = KeyAction(rawValue: cmd["action"] as? String ?? "") else { throw Failure(description: "unknown action") }
            let b = (cmd["doubleTap"] as? String).flatMap(Mod.init(rawValue:)).map { KeyBinding(doubleTap: $0) }
                ?? KeyBinding(cmd["key"] as? String ?? "", mods(cmd["modifiers"]))
            s.prefs.keymap.set(b, for: a)
        case "reset_keymap":
            s.prefs.keymap = Keymap()
        case "simulate_update":
            s.updater.simulate(latest: cmd["latest"] as? String ?? "99.0.0", brew: cmd["brew"] as? String ?? "/usr/bin/false")
        case "update_now":
            s.updater.updateNow()
        case "resize_begin":
            let f = s.drawer.drawerFrameNow
            resizeStart = NSPoint(x: s.prefs.edge == .right ? f.minX : f.maxX, y: f.midY)
            s.drawer.simulatedMouse = resizeStart
            s.drawer.resizeDrawer()
        case "resize_move":
            guard let start = resizeStart else { throw Failure(description: "resize_begin first") }
            s.drawer.simulatedMouse = NSPoint(x: start.x + (cmd["dx"] as? Double ?? 0), y: start.y)
            s.drawer.resizeDrawer()
        case "resize_end":
            s.drawer.endResize()
            s.drawer.simulatedMouse = nil
            resizeStart = nil
        case "snapshot":
            let name = cmd["name"] as? String ?? "snapshot"
            let window = cmd["window"] as? String ?? "drawer"
            return ["path": try s.snapshot(window: window, name: name, to: dir)]
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
        default:
            throw Failure(description: "unknown command \(cmd["cmd"] ?? "nil")")
        }
        return state()
    }

    private func setPref(_ key: String, _ value: Any?) throws {
        let p = services.prefs
        let v = value as? String ?? ""
        switch key {
        case "appearance": p.appearance = Appearance(rawValue: v) ?? .system
        case "edge": p.edge = Edge(rawValue: v) ?? .right
        case "windowLevel": p.windowLevel = WindowLevelPref(rawValue: v) ?? .top
        case "pinned": p.pinned = value as? Bool ?? false
        case "clearDone": p.clearDone = ClearDone(rawValue: v) ?? .midnight
        case "runnerEnabled": p.runnerEnabled = value as? Bool ?? false
        case "showKeyHints": p.showKeyHints = value as? Bool ?? true
        default: throw Failure(description: "unknown pref \(key)")
        }
    }

    private func mods(_ v: Any?) -> [Mod] {
        (v as? [String] ?? []).compactMap(Mod.init(rawValue:))
    }

    private func rect(_ r: NSRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }

    private func state() -> [String: Any] {
        let s = services, m = s.model
        let lastSeen = m.lastSeenAt
        func t(_ x: TodoTask) -> [String: Any] {
            ["title": x.title, "unread": x.unread, "status": x.status, "priority": Int(x.priority),
             "chip": x.chip(lastSeen: lastSeen) ?? "", "addedBy": x.addedBy, "userRanked": x.userRankedAt != nil]
        }
        return [
            "open": m.open.map(t),
            "done": m.done.map(t),
            "unread": m.unreadCount,
            "recentRuns": m.recentRuns.map { ["actor": $0.actor, "stats": $0.statsText, "summary": $0.summary ?? ""] },
            "sources": m.sources.map { ["name": $0.name, "kind": $0.kind, "instructions": $0.instructions, "enabled": $0.enabled] },
            "schedulePrompt": (try? m.store.renderSetupPrompt()) ?? "",
            "discoveryPrompt": m.store.renderDiscoveryPrompt(),
            "selected": m.selected?.title ?? NSNull(),
            "highlighted": m.highlighted?.title ?? NSNull(),
            "doneExpanded": m.doneExpanded,
            "shortcutsOpen": m.showShortcuts,
            "typing": s.drawer.keys.typing,
            "keymap": Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0.rawValue, s.prefs.key($0).spoken) }),
            "toast": m.toast?.text ?? NSNull(),
            "lastOpened": SourceOpener.lastOpened ?? NSNull(),
            "update": ["available": s.updater.updateAvailable, "updating": s.updater.updating,
                       "error": s.updater.updateError ?? ""] as [String: Any],
            "drawerOpen": s.drawer.isOpen,
            "tabFree": s.drawer.isFree,
            "tabFrame": rect(s.drawer.tabFrame),
            "drawerFrame": rect(s.drawer.drawerFrameNow),
            "screen": rect(s.drawer.screenVisibleFrame),
            "edge": s.prefs.edge.rawValue,
            "appearance": s.prefs.appearance.rawValue,
            "pinned": s.prefs.pinned,
            "drawerWidth": s.prefs.drawerWidth,
            "settingsOpen": s.isSettingsOpen,
            "setupOpen": s.isSetupOpen,
            "windows": s.windowNumbers,
        ]
    }
}
