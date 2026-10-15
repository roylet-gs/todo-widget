import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Recognises a double tap of one modifier key while holding exactly `holding` (often nothing): pressed
/// and released twice, quickly, with no other modifier or key in between (so ⌘C, ⌘⇧ and holding ⌘ never count).
struct DoubleTapDetector {
    var modifier: Mod
    var holding: Set<Mod>
    var interval: TimeInterval = 0.35
    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    init(modifier: Mod, holding: Set<Mod> = []) {
        self.modifier = modifier
        self.holding = holding.subtracting([modifier])
    }

    /// Feed the modifiers held after a flags change. Returns true when a double tap completes.
    mutating func flagsChanged(_ held: Set<Mod>, at t: TimeInterval) -> Bool {
        if held == holding.union([modifier]) {
            downAt = t
            return false
        }
        guard held == holding, let down = downAt else {
            reset()
            return false
        }
        downAt = nil
        guard t - down <= interval else {
            lastTapAt = nil
            return false
        }
        if let last = lastTapAt, t - last <= interval * 1.5 {
            lastTapAt = nil
            return true
        }
        lastTapAt = t
        return false
    }

    /// Any other key press cancels a tap in progress.
    mutating func keyDown() { reset() }

    mutating func reset() {
        downAt = nil
        lastTapAt = nil
    }
}

/// The system-wide "show or hide the widget" shortcut. A double tap of a modifier watches key
/// events in every app, which macOS only allows with Accessibility access; a normal combo is
/// registered as a system hotkey and needs no permission.
@MainActor
@Observable
final class HotkeyMonitor {
    private let prefs: Preferences
    private let onToggle: () -> Void
    private var monitors: [Any] = []
    private var detector: DoubleTapDetector?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var trustTimer: Timer?
    private(set) var accessibilityGranted = AXIsProcessTrusted()

    private static weak var current: HotkeyMonitor?

    init(prefs: Preferences, onToggle: @escaping () -> Void) {
        self.prefs = prefs
        self.onToggle = onToggle
        Self.current = self
        arm()
        observePrefs()
    }

    var binding: KeyBinding { prefs.key(.toggleWidget) }
    var needsAccessibility: Bool { binding.doubleTap != nil }

    private func observePrefs() {
        withObservationTracking {
            _ = prefs.keymap
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.arm()
                    self?.observePrefs()
                }
            }
        }
    }

    /// (Re)install whatever the current binding needs.
    func arm() {
        disarm()
        let b = binding
        if let m = b.doubleTap {
            detector = DoubleTapDetector(modifier: m, holding: Set(b.mods))
            let flags: (NSEvent) -> Void = { [weak self] e in
                MainActor.assumeIsolated { self?.flagsChanged(Mod.from(e.modifierFlags), at: e.timestamp) }
            }
            let key: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.detector?.keyDown() }
            }
            // Global monitors only see other apps' events, so ours need local ones too.
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(g) }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(l) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(l) }
            watchTrust()
        } else if let code = b.code {
            registerHotKey(code: code, mods: b.mods)
        }
    }

    private func disarm() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        detector = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        trustTimer?.invalidate()
        trustTimer = nil
    }

    /// Fed by the event monitors (and by e2e with synthetic timestamps).
    func flagsChanged(_ held: Set<Mod>, at t: TimeInterval) {
        if detector?.flagsChanged(held, at: t) == true { onToggle() }
    }

    func keyDown() { detector?.keyDown() }

    // MARK: Accessibility

    /// Ask macOS for Accessibility access (shows the system prompt the first time) and open the pane.
    func requestAccess() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watchTrust()
    }

    /// Global key monitors only start delivering once access is granted, so re-arm when it is.
    private func watchTrust() {
        accessibilityGranted = AXIsProcessTrusted()
        guard !accessibilityGranted, trustTimer == nil, !E2E.enabled else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityGranted = true
                self.arm()
            }
        }
    }

    // MARK: Combo hotkey

    private func registerHotKey(code: UInt16, mods: [Mod]) {
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { HotkeyMonitor.current?.onToggle() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        var carbon: UInt32 = 0
        for m in mods {
            switch m {
            case .command: carbon |= UInt32(cmdKey)
            case .option: carbon |= UInt32(optionKey)
            case .control: carbon |= UInt32(controlKey)
            case .shift: carbon |= UInt32(shiftKey)
            }
        }
        let id = EventHotKeyID(signature: OSType(0x5444_5754), id: 1)  // "TDWT"
        RegisterEventHotKey(UInt32(code), carbon, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
