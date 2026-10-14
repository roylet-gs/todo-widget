import AppKit

/// Turns key presses in the drawer into actions, using the user's keymap.
///
/// A local event monitor rather than SwiftUI shortcuts: the drawer is a non-activating panel, where
/// SwiftUI focus is unreliable, and one dispatcher keeps every binding configurable.
@MainActor
final class DrawerKeys {
    private let model: AppModel
    private let prefs: Preferences
    private unowned let controller: DrawerController
    private var monitor: Any?

    init(model: AppModel, prefs: Preferences, controller: DrawerController) {
        self.model = model
        self.prefs = prefs
        self.controller = controller
    }

    func install(for panel: NSPanel) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let panel, event.window === panel, let b = KeyBinding(event: event) else { return event }
            let handled = MainActor.assumeIsolated { panel.isKeyWindow && self?.handle(b) == true }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True while a text field in the drawer is being edited.
    var typing: Bool { controller.firstResponderIsText }

    /// Run the action bound to `b`, if any. Returns false to let the key through (e.g. into a text field).
    @discardableResult
    func handle(_ b: KeyBinding) -> Bool {
        if typing {
            // Plain keys belong to the text field; Esc leaves it.
            if b == KeyBinding("escape") {
                controller.endTyping()
                return true
            }
            guard b.hasCommandOrControl else { return false }
        }
        guard let action = prefs.keymap.action(for: b, inDetail: model.selected != nil) else { return false }
        return perform(action)
    }

    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        let m = model
        if m.showShortcuts && action != .shortcuts && action != .back && action != .toggleWidget {
            m.showShortcuts = false
        }
        switch action {
        case .toggleWidget: controller.toggle()
        case .previous: m.moveHighlight(by: -1)
        case .next: m.moveHighlight(by: 1)
        case .first: m.highlightEnd(last: false)
        case .last: m.highlightEnd(last: true)
        case .open:
            guard let t = m.highlighted else { return false }
            m.select(t)
        case .back:
            if m.showShortcuts { m.showShortcuts = false }
            else if m.selectedId != nil { m.select(nil) }
            else { controller.close() }
        case .toggleDone:
            guard let t = m.selected ?? m.highlighted else { return false }
            // Finishing a task moves the cursor on; reopening one from its detail keeps it there.
            let next = m.selected != nil && t.isDone ? t.id : m.neighbor(of: t.id)
            m.toggleDone(t)
            m.highlightedId = next
        case .delete:
            guard let t = m.selected ?? m.highlighted else { return false }
            let next = m.neighbor(of: t.id)
            m.delete(t)
            m.highlightedId = next
        case .edit: m.wantsEdit = true
        case .save: m.wantsSave = true
        case .moveUp, .moveDown:
            guard let id = m.highlightedId else { return false }
            m.nudge(id, by: action == .moveUp ? -1 : 1)
        case .newTask:
            m.select(nil)
            m.wantsQuickAdd = true
        case .toggleDoneSection:
            m.doneExpanded.toggle()
            m.ensureHighlight()
        case .undo: m.undo()
        case .redo: m.redo()
        case .pin: prefs.pinned.toggle()
        case .runNow:
            guard prefs.runnerEnabled, let runner = AppServices.shared?.runner, !runner.isRunning else { return false }
            runner.runNow()
            m.showToast("Run started: Claude Code (built-in runner)", undoable: false)
        case .settings: AppServices.shared?.showSettings()
        case .shortcuts: m.showShortcuts.toggle()
        }
        return true
    }
}
