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
    let hotkey: HotkeyMonitor
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var observedWindows: Set<ObjectIdentifier> = []
    private var e2e: E2EServer?
    private var midnightTimer: Timer?

    init() throws {
        prefs = Preferences()
        model = try AppModel(prefs: prefs)
        runner = Runner(prefs: prefs, store: model.store)
        notifier = Notifier()
        updater = Updater()
        drawer = DrawerController(model: model, prefs: prefs, updater: updater)
        hotkey = HotkeyMonitor(prefs: prefs, onToggle: { [weak drawer] in drawer?.toggle() })
        notifier.onOpen = { [weak self] in self?.drawer.open() }
        notifier.onUndo = { [weak self] id in self?.model.undoGroup(id) }
        model.onRunsFinished = { [weak self] runs in self?.notifier.check(runs) }
        model.reload()
        scheduleMidnight()
        LoginItem.enableByDefaultOnce()
        // Debug hooks used for screenshots and manual testing.
        let env = ProcessInfo.processInfo.environment
        // Present windows after launch finishes, so activation isn't swallowed by the launch itself.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.prefs.setupComplete && env["TODO_WIDGET_SKIP_SETUP"] != "1" && !E2E.enabled { self.showSetup() }
            if env["TODO_WIDGET_SETTINGS"] == "1" { self.showSettings() }
        }
        if env["TODO_WIDGET_OPEN"] == "1" { drawer.open() }
        if let dir = E2E.dir { e2e = E2EServer(dir: dir, services: self) }
    }

    func showSettings(tab: SettingsTab = .general) {
        // An unpinned drawer hands off to Settings; a pinned one stays open underneath it.
        if !prefs.pinned { drawer.close() }
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
        guard let w = settingsWindow else { return }
        w.contentView = NSHostingView(rootView: SettingsView(model: model, prefs: prefs, runner: runner, tab: tab).themed(prefs))
        // Share an always-on-top pinned drawer's level so Settings can sit above it.
        let drawerLevel = prefs.windowLevel.level
        w.level = prefs.pinned && drawerLevel > .normal ? drawerLevel : .normal
        present(w)
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
        }, step: SetupView.Step(rawValue: step) ?? .welcome).themed(prefs))
        w.center()
        setupWindow = w
        present(w)
    }

    func closeSetup() {
        setupWindow?.close()
        setupWindow = nil
    }

    /// Bring one of our windows to the front. While Settings or setup is open the app acts as a regular app
    /// (Dock icon, ⌘-Tab, app menu), which macOS needs before it lets a menu bar app come forward.
    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        // Activation is only a request since macOS 14; make sure the window is in front regardless.
        w.orderFrontRegardless()
        installSettingsMenuItem()
        guard !observedWindows.contains(ObjectIdentifier(w)) else { return }
        observedWindows.insert(ObjectIdentifier(w))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateActivationPolicy() } }
        }
    }

    /// Back to menu-bar-only once neither Settings nor setup is showing.
    private func updateActivationPolicy() {
        guard !isSettingsOpen, !isSetupOpen, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Put Settings… ⌘, in the app menu, which SwiftUI only adds itself for a `Settings` scene.
    private func installSettingsMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              !menu.items.contains(where: { $0.action == #selector(AppDelegate.openSettings(_:)) }) else { return }
        let item = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        item.target = NSApp.delegate
        let aboutIndex = menu.items.firstIndex { $0.title.hasPrefix("About") }
        let at = aboutIndex.map { $0 + 1 } ?? 0
        menu.insertItem(.separator(), at: at)
        menu.insertItem(item, at: at + 1)
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
    var settingsLevel: Int { settingsWindow?.level.rawValue ?? 0 }
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
    @objc func openSettings(_ sender: Any?) {
        MainActor.assumeIsolated { AppServices.shared?.showSettings() }
    }

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
            let key = s.prefs.key(.toggleWidget)
            Button("\(s.drawer.isOpen ? "Close drawer" : "Open drawer")\(key.doubleTap == nil ? "" : "  (\(key.spoken))")") { s.drawer.toggle() }
                .menuShortcut(s.prefs, .toggleWidget)
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
