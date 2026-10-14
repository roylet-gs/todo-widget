import AppKit
import Foundation

typealias TodoTask = TodoItem

struct Toast: Equatable {
    var text: String
    var undoable: Bool
    var id = UUID()
}

/// Shared app state. All store calls are synchronous SQLite operations and fast enough for the main actor.
@MainActor
@Observable
final class AppModel {
    let store: TodoStore
    let prefs: Preferences

    private(set) var open: [TodoTask] = []
    private(set) var done: [TodoTask] = []
    /// Agent runs since the user last dismissed the "what changed" strip.
    private(set) var recentRuns: [ChangeGroup] = []
    private(set) var lastSeenAt: Int64 = 0
    private(set) var lastRunAt: Int64?
    /// Sources the agent manages through the MCP; shown read-only and refreshed live.
    private(set) var sources: [Source] = []

    var selectedId: String?
    /// The keyboard cursor in the list (separate from `selectedId`, which shows a task's detail).
    var highlightedId: String?
    /// Where the pointer was when the keyboard last moved the cursor. Rows sliding under a still
    /// pointer (scrolling, reordering, the drawer opening) mustn't steal the cursor back.
    @ObservationIgnored var pointerAtKeyboard: NSPoint?
    var doneExpanded = false
    /// The keyboard shortcuts overlay.
    var showShortcuts = false
    /// Requests from the keyboard handler to views that own the focus and edit state.
    var wantsQuickAdd = false
    var wantsEdit = false
    var wantsSave = false
    var toast: Toast?
    var error: String?

    /// Bumped on every reload so secondary views (settings) can refresh.
    private(set) var revision = 0

    var onRunsFinished: (([ChangeGroup]) -> Void)?

    private var observer: DarwinObserver?
    private var toastTask: _Concurrency.Task<Void, Never>?

    init(prefs: Preferences) throws {
        self.prefs = prefs
        store = try TodoStore.open(path: nil)
        if (try? store.getSetting(key: "last_seen_at")) == nil {
            try? store.markSeen()
        }
        observer = DarwinObserver { [weak self] in self?.reload() }
        archiveIfNeeded()
        reload()
    }

    var unreadCount: Int { open.filter(\.unread).count }
    var selected: TodoTask? { (open + done).first { $0.id == selectedId } }
    var highlighted: TodoTask? { (open + done).first { $0.id == highlightedId } }

    // MARK: keyboard cursor

    /// Rows in the order they appear in the list.
    var visibleOrder: [TodoTask] { open + (doneExpanded ? done : []) }

    func moveHighlight(by delta: Int) {
        let rows = visibleOrder
        guard !rows.isEmpty else { highlightedId = nil; return }
        guard let i = rows.firstIndex(where: { $0.id == highlightedId }) else {
            highlightedId = (delta >= 0 ? rows.first : rows.last)?.id
            return
        }
        highlightedId = rows[min(max(i + delta, 0), rows.count - 1)].id
    }

    /// Hovering a row moves the cursor there, but only once the pointer has actually moved.
    func hoverHighlight(_ id: String) {
        // e2e drives the cursor itself; the real pointer of whoever is at the Mac mustn't move it.
        if E2E.enabled { return }
        if let p = pointerAtKeyboard, p == NSEvent.mouseLocation { return }
        pointerAtKeyboard = nil
        highlightedId = id
    }

    func highlightEnd(last: Bool) {
        highlightedId = (last ? visibleOrder.last : visibleOrder.first)?.id
    }

    /// Keep the cursor on a visible row (the first one if it has gone).
    func ensureHighlight() {
        if !visibleOrder.contains(where: { $0.id == highlightedId }) { highlightedId = visibleOrder.first?.id }
    }

    /// The row the cursor should land on once `id` leaves its place: the next one, else the previous.
    func neighbor(of id: String) -> String? {
        let rows = visibleOrder
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < rows.count { return rows[i + 1].id }
        return i > 0 ? rows[i - 1].id : nil
    }

    func reload() {
        do {
            let all = try store.listTasks(includeDone: true)
            open = all.filter { $0.status == "open" }
            done = all.filter { $0.status == "done" }
            lastSeenAt = Int64(try store.getSetting(key: "last_seen_at") ?? "") ?? 0
            recentRuns = try store.runsSince(sinceMs: lastSeenAt)
                .filter { $0.kind == "run" && !$0.events.isEmpty && !$0.undone }
            lastRunAt = try store.lastRunAt()
            sources = try store.listSources()
            _ = try store.closeStaleRuns(idleMs: 5 * 60 * 1000)
            onRunsFinished?(try store.runsSince(sinceMs: Int64(Date().timeIntervalSince1970 * 1000) - 86_400_000))
            revision += 1
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: actions (all as the user)

    func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        perform("Added “\(t)”") {
            _ = try $0.addTask(
                input: TaskInput(title: t, priority: nil, due: nil, summary: nil, rationale: nil, source: nil, sourceRef: nil, sourceUrl: nil, excerpt: nil, sourceFrom: nil),
                actor: "You", runId: nil)
        }
    }

    func toggleDone(_ task: TodoTask) {
        let done = task.status != "done"
        // Finishing the task you're looking at takes you back to the list.
        if done && selectedId == task.id { selectedId = nil }
        perform("\(done ? "Completed" : "Reopened") “\(task.title)”") {
            _ = try $0.setDone(id: task.id, done: done, actor: "You", runId: nil, reason: nil)
        }
    }

    func delete(_ task: TodoTask) {
        if selectedId == task.id { selectedId = nil }
        perform("Deleted “\(task.title)”") { _ = try $0.deleteTask(id: task.id, actor: "You", runId: nil, reason: nil) }
    }

    func update(_ task: TodoTask, patch: TaskPatch) {
        perform("Edited “\(task.title)”") { _ = try $0.updateTask(id: task.id, patch: patch, actor: "You", runId: nil) }
    }

    /// Drag-and-drop: move `id` to `index` in the open list.
    func move(_ id: String, to index: Int) {
        guard let t = open.first(where: { $0.id == id }), let from = open.firstIndex(where: { $0.id == id }), from != index else { return }
        perform("Moved “\(t.title)”") { _ = try $0.moveTask(id: id, newIndex: UInt32(max(0, index))) }
    }

    func nudge(_ id: String, by delta: Int) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < open.count else { return }
        move(id, to: j)
    }

    func select(_ task: TodoTask?) {
        selectedId = task?.id
        if let task { highlightedId = task.id }
        if let task, task.unread { try? store.markRead(id: task.id) }
    }

    /// Open the task's source link, in its desktop app when installed. False when it has no link.
    @discardableResult
    func openSource(_ task: TodoTask) -> Bool {
        guard let s = task.sourceUrl, let url = URL(string: s) else { return false }
        SourceOpener.open(url)
        if task.unread { try? store.markRead(id: task.id) }
        // The source app comes forward; get out of its way unless pinned, as a click outside would.
        if !prefs.pinned { AppServices.shared?.drawer.close() }
        return true
    }

    func undo() {
        do {
            if let label = try store.undoLast() { showToast("Undid: \(label)", undoable: false) }
        } catch { self.error = "\(error)" }
    }

    func redo() {
        do {
            if let label = try store.redoLast() { showToast("Redid: \(label)", undoable: false) }
        } catch { self.error = "\(error)" }
    }

    func undoGroup(_ id: String) {
        do {
            let label = try store.undoGroup(groupId: id)
            showToast("Undid: \(label)", undoable: false)
        } catch { self.error = "\(error)" }
    }

    func undoRecentRuns() {
        for run in recentRuns.reversed() { _ = try? store.undoGroup(groupId: run.id) }
        try? store.markSeen()
        showToast("Undid \(recentRuns.count) run\(recentRuns.count == 1 ? "" : "s")", undoable: false)
    }

    func dismissRecentRuns() {
        try? store.markSeen()
    }

    /// Clear done tasks according to the preference. Called on launch, drawer open and at midnight.
    func archiveIfNeeded() {
        let cutoff: Int64? = switch prefs.clearDone {
        case .midnight: localMidnightMs()
        case .day: Int64(Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000)
        case .never: nil
        }
        if let cutoff { _ = try? store.archiveDone(cutoffMs: cutoff) }
    }

    func showToast(_ text: String, undoable: Bool) {
        toast = Toast(text: text, undoable: undoable)
        toastTask?.cancel()
        toastTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(5))
            guard !_Concurrency.Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func perform(_ label: String, _ body: (TodoStore) throws -> Void) {
        do {
            try body(store)
            showToast(label, undoable: true)
        } catch {
            self.error = "\(error)"
            showToast("\(error)", undoable: false)
        }
    }
}

// MARK: - formatting helpers

extension TodoTask {
    var isDone: Bool { status == "done" }

    var meta: String {
        [source, due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func chip(lastSeen: Int64) -> String? {
        if isDone { return nil }
        if unread && addedBy != "You" && createdAt >= lastSeen { return "new" }
        if lastMove > 0 { return "↑\(lastMove)" }
        if lastMove < 0 { return "↓\(-lastMove)" }
        return nil
    }
}

extension ChangeGroup {
    var statsText: String {
        var parts: [String] = []
        if stats.added > 0 { parts.append("\(stats.added) new") }
        if stats.done > 0 { parts.append("\(stats.done) done") }
        if stats.reordered > 0 { parts.append("\(stats.reordered) moved") }
        if stats.updated > 0 { parts.append("\(stats.updated) updated") }
        if stats.deleted > 0 { parts.append("\(stats.deleted) removed") }
        return parts.isEmpty ? "no changes" : parts.joined(separator: " · ")
    }

    var displayLabel: String {
        if kind == "run" { return summary ?? statsText }
        return label
    }
}

func clockTime(_ ms: Int64) -> String {
    let d = Date(timeIntervalSince1970: Double(ms) / 1000)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "H:mm" : "EEE H:mm"
    return f.string(from: d)
}
