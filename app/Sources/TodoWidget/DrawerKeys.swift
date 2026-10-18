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
    private var monitors: [Any] = []

    init(model: AppModel, prefs: Preferences, controller: DrawerController) {
        self.model = model
        self.prefs = prefs
        self.controller = controller
    }

    func install(for panel: NSPanel) {
        remove()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self, weak panel] event in
            guard let panel, event.window === panel, let b = KeyBinding(event: event) else { return event }
            let handled = MainActor.assumeIsolated { panel.isKeyWindow && self?.handle(b) == true }
            return handled ? nil : event
        }) { monitors.append(m) }
        // The mouse's back button (button 3). No key-window check: the click lands on the panel either way.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self, weak panel] event in
            guard let panel, event.window === panel, event.buttonNumber == 3 else { return event }
            let handled = MainActor.assumeIsolated { self?.mouseBack() == true }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    func remove() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// The mouse's back button: steps back out of a task's detail, like Esc. Does nothing on the list,
    /// so a stray click never closes the drawer.
    @discardableResult
    func mouseBack() -> Bool {
        guard model.selected != nil, model.rejecting == nil else { return false }
        return perform(.back)
    }

    /// True while a text field in the drawer is being edited.
    var typing: Bool { controller.firstResponderIsText }

    /// Run the action bound to `b`, if any. Returns false to let the key through (e.g. into a text field).
    @discardableResult
    func handle(_ b: KeyBinding) -> Bool {
        // The reject panel owns the keyboard: Return rejects, Esc cancels, other keys type the reason.
        if model.rejecting != nil {
            if b == KeyBinding("escape") { model.cancelReject(); return true }
            if b == KeyBinding("return") { model.confirmReject(); return true }
            return !typing
        }
        if typing {
            // Plain keys belong to the text field. In the list (quick add or search) Esc collapses the
            // drawer, keeping the draft, or clears the search; ↓ goes to the first task. In the editor Esc
            // cancels the edit; elsewhere it leaves the field.
            let inList = model.selected == nil
            if b == KeyBinding("escape") {
                if model.showShortcuts { model.showShortcuts = false }
                else if model.editingId != nil { cancelEdit() }
                else if inList && model.searching { controller.endTyping(); model.endSearch() }
                else if inList { controller.close() }
                else { controller.endTyping() }
                return true
            }
            if inList && b == KeyBinding("down") {
                controller.endTyping()
                model.highlightedId = model.visibleOrder.first?.id
                return true
            }
            guard b.hasCommandOrControl else { return false }
        }
        guard let action = prefs.keymap.action(for: b, inDetail: model.selected != nil) else { return false }
        return perform(action)
    }

    /// Leave edit mode without saving; the draft is dropped.
    private func cancelEdit() {
        controller.endTyping()
        model.editingId = nil
    }

    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        let m = model
        m.pointerAtKeyboard = NSEvent.mouseLocation
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
        case .openSource:
            guard let t = m.selected ?? m.highlighted, m.openSource(t) else { return false }
        case .back:
            if m.showShortcuts { m.showShortcuts = false }
            else if m.editingId != nil { cancelEdit() }
            else if m.selectedId != nil { m.select(nil) }
            else if m.searching { m.endSearch() }
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
        case .reject:
            guard let t = m.selected ?? m.highlighted, t.isAgentTask else { return false }
            m.beginReject(t)
        case .edit: m.wantsEdit = true
        case .save: m.wantsSave = true
        case .moveUp, .moveDown:
            guard let id = m.highlightedId, !m.isFiltering else { return false }
            m.nudge(id, by: action == .moveUp ? -1 : 1)
        case .priority1, .priority2, .priority3:
            guard let t = m.selected ?? m.highlighted, !t.isDone else { return false }
            m.setPriority(t, action == .priority1 ? 1 : action == .priority2 ? 2 : 3)
        case .newTask:
            m.select(nil)
            m.wantsQuickAdd = true
        case .search: m.beginSearch()
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
