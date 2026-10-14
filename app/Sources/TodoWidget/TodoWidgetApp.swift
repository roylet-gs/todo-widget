import AppKit
import SwiftUI

/// Long-lived objects shared by the menubar, drawer and settings window.
@MainActor
final class AppServices {
    static var shared: AppServices?

    let prefs: Preferences
    let model: AppModel
    let runner: Runner
    let notifier: Notifier
    let drawer: DrawerController
    let updater: Updater
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var e2e: E2EServer?
    private var midnightTimer: Timer?

    init() throws {
        prefs = Preferences()
        model = try AppModel(prefs: prefs)
        runner = Runner(prefs: prefs, store: model.store)
        notifier = Notifier()
        updater = Updater()
        drawer = DrawerController(model: model, prefs: prefs)
        notifier.onOpen = { [weak self] in self?.drawer.open() }
        notifier.onUndo = { [weak self] id in self?.model.undoGroup(id) }
        model.onRunsFinished = { [weak self] runs in self?.notifier.check(runs) }
        model.reload()
        scheduleMidnight()
        LoginItem.enableByDefaultOnce()
        // Debug hooks used for screenshots and manual testing.
        let env = ProcessInfo.processInfo.environment
        if !prefs.setupComplete && env["TODO_WIDGET_SKIP_SETUP"] != "1" && !E2E.enabled { showSetup() }
        if env["TODO_WIDGET_OPEN"] == "1" { drawer.open() }
        if env["TODO_WIDGET_SETTINGS"] == "1" { showSettings() }
        if let dir = E2E.dir { e2e = E2EServer(dir: dir, services: self) }
    }

    func showSettings(tab: SettingsTab = .general) {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Todo Widget Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model, prefs: prefs, runner: runner, tab: tab))
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    func showSetup(step: Int = 0) {
        setupWindow?.close()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Set up Todo Widget"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SetupView(model: model, prefs: prefs, onFinish: { [weak self] in
            self?.closeSetup()
            self?.drawer.open()
        }, step: SetupView.Step(rawValue: step) ?? .welcome))
        w.center()
        setupWindow = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func closeSetup() {
        setupWindow?.close()
        setupWindow = nil
    }

    /// Reset preferences and stored configuration (and optionally all tasks), then run setup again.
    func reset(eraseTasks: Bool) {
        do {
            try model.store.reset(eraseTasks: eraseTasks)
        } catch {
            model.showToast("Reset failed: \(error)", undoable: false)
            return
        }
        prefs.resetToDefaults()
        for k in ["notifiedRuns", "notifiedBaseline"] { AppDefaults.removeObject(forKey: k) }
        drawer.close()
        closeSettings()
        model.reload()
        showSetup()
    }

    var isSettingsOpen: Bool { settingsWindow?.isVisible == true }
    var isSetupOpen: Bool { setupWindow?.isVisible == true }
    var windowNumbers: [String: Int] {
        var w = drawer.windowNumbers
        w["settings"] = settingsWindow?.isVisible == true ? settingsWindow!.windowNumber : 0
        w["setup"] = setupWindow?.isVisible == true ? setupWindow!.windowNumber : 0
        return w
    }

    /// Render one of the app's windows to `<dir>/<name>.png` (own windows only; no Screen Recording needed).
    func snapshot(window: String, name: String, to dir: URL) throws -> String {
        let view: NSView? = switch window {
        case "settings": settingsWindow?.contentView
        case "setup": setupWindow?.contentView
        default: drawer.panel(window)?.contentView
        }
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw E2EServer.Failure(description: "window '\(window)' is not open")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw E2EServer.Failure(description: "could not encode PNG")
        }
        try png.write(to: url)
        return url.path
    }

    /// Clear done tasks right after local midnight even if the drawer stays closed.
    private func scheduleMidnight() {
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        midnightTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.archiveIfNeeded()
                self?.model.reload()
                self?.scheduleMidnight()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            do {
                AppServices.shared = try AppServices()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Todo Widget could not open its database"
                alert.informativeText = "\(error)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }
}

@main
struct TodoWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuLabel()
        }
    }
}

struct MenuLabel: View {
    var body: some View {
        if let model = AppServices.shared?.model, model.unreadCount > 0 {
            Label("\(model.unreadCount)", systemImage: "checklist").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "checklist")
        }
    }
}

struct MenuContent: View {
    var body: some View {
        if let s = AppServices.shared {
            Button(s.drawer.isOpen ? "Close drawer" : "Open drawer") { s.drawer.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            if s.prefs.runnerEnabled {
                Button(s.runner.isRunning ? "Running…" : "Run agent now") { s.runner.runNow() }
                    .disabled(s.runner.isRunning)
            }
            Button("Undo last change") { s.model.undo() }
            Divider()
            Button("Settings…") { s.showSettings() }.keyboardShortcut(",")
        }
        Divider()
        Button("Quit Todo Widget") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
