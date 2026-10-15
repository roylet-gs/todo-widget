import SwiftUI

enum Palette {
    static func priority(_ p: UInt8) -> Color {
        switch p {
        case 1: .orange
        case 2: .accentColor
        default: .secondary
        }
    }
}

// MARK: - Collapsed tab

struct EdgeTabView: View {
    let model: AppModel
    let prefs: Preferences
    let controller: DrawerController
    @State private var hovering = false

    var body: some View {
        let right = prefs.edge == .right
        // Flat against the edge while attached; fully rounded once pulled free.
        let r: CGFloat = 16
        let flat: CGFloat = controller.isFree ? r : 0
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: right ? r : flat, bottomLeadingRadius: right ? r : flat,
            bottomTrailingRadius: right ? flat : r, topTrailingRadius: right ? flat : r,
            style: .continuous)
        ZStack {
            VStack(spacing: 7) {
                Text("\(model.unreadCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(model.unreadCount > 0 ? Color.accentColor : Color.secondary))
                VStack(spacing: 4) {
                    ForEach(model.open.prefix(3), id: \.id) { t in
                        Capsule().fill(Palette.priority(t.priority))
                            .frame(width: 14, height: 3)
                            .opacity(t.unread ? 1 : 0.45)
                    }
                }
                // Points the way the drawer opens; brightens on hover to signal it's clickable.
                Image(systemName: right ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .offset(x: hovering ? (right ? -2 : 2) : 0)
                    .animation(.snappy(duration: 0.18), value: hovering)
            }
            .frame(width: DrawerController.tabSize.width, height: DrawerController.tabSize.height)
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { hovering = $0 && !controller.isDraggingTab }
            .onTapGesture { controller.open() }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in controller.dragTab() }
                    .onEnded { _ in controller.endTabDrag() }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(.regular.interactive(), in: shape)
        .help("Click to open · drag to move")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open todo drawer, \(model.unreadCount) unread")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Drawer

struct DrawerView: View {
    let model: AppModel
    let prefs: Preferences
    let updater: Updater
    let controller: DrawerController

    var body: some View {
        ZStack {
            if let task = model.selected {
                TaskDetailView(model: model, prefs: prefs, controller: controller, task: task)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                TaskListView(model: model, prefs: prefs, updater: updater, controller: controller)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.selectedId)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.showShortcuts {
                ShortcutsSheet(model: model, prefs: prefs)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.snappy(duration: 0.18), value: model.showShortcuts)
        .liquidGlass(.regular, in: .rect(cornerRadius: 26))
        .overlay(alignment: prefs.edge == .right ? .leading : .trailing) { resizeHandle }
        // Keys are handled by `DrawerKeys`; ⌘W isn't configurable, so it stays a plain shortcut.
        .background(
            Button("Close") { controller.close() }.keyboardShortcut("w", modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        )
    }

    /// An invisible strip on the drawer's inner edge; drag it to make the drawer wider or narrower.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .padding(.vertical, 26)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: prefs.edge == .right ? .leading : .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in controller.resizeDrawer() }
                    .onEnded { _ in controller.endResize() }
            )
            .accessibilityHidden(true)
    }
}

/// Every binding, grouped, over the drawer. Opened with ? (by default) or the footer link.
struct ShortcutsSheet: View {
    let model: AppModel
    let prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { model.showShortcuts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyHelp(prefs, "Close", .back)
                    .accessibilityLabel("Close")
            }
            .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(KeyGroup.allCases, id: \.self) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                            ForEach(KeyAction.allCases.filter { $0.group == g }) { a in
                                HStack {
                                    Text(a.title).font(.callout)
                                    Spacer()
                                    KeyCap(prefs.key(a).spoken)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Button("Change shortcuts in Settings…") {
                model.showShortcuts = false
                AppServices.shared?.showSettings(tab: .keyboard)
            }
            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            .padding(.top, 8)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor).opacity(E2E.flatGlass ? 1 : 0.92), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(14)
    }
}

struct TaskListView: View {
    let model: AppModel
    let prefs: Preferences
    let updater: Updater
    let controller: DrawerController

    @State private var runsExpanded = false
    @State private var dragging: String?
    @State private var dropTarget: String?
    @FocusState private var addFocused: Bool

    private let todayCount = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            if updater.updateAvailable { updateBanner }
            if !model.recentRuns.isEmpty { runStrip }
            quickAdd
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.open.prefix(todayCount).enumerated()), id: \.element.id) { i, t in row(t, index: i) }
                    if model.open.count > todayCount {
                        sectionDivider("Later")
                        ForEach(Array(model.open.dropFirst(todayCount).enumerated()), id: \.element.id) { i, t in
                            row(t, index: i + todayCount).opacity(0.78)
                        }
                    }
                    if model.open.isEmpty {
                        Text("Nothing to do. Agents will add tasks here.")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 40)
                    }
                    if !model.done.isEmpty { doneSection }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .onChange(of: model.highlightedId) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(id) }
            }
            }
            if let toast = model.toast { toastView(toast) }
            if prefs.showKeyHints { keyFooter }
        }
        .onChange(of: model.wantsQuickAdd) { _, w in if w { focusQuickAdd() } }
        .onAppear { if model.wantsQuickAdd { focusQuickAdd() } }
    }

    private func focusQuickAdd() {
        model.wantsQuickAdd = false
        controller.engage()
        addFocused = true
    }

    /// What the keyboard can do right now, along the bottom of the list.
    /// As the drawer narrows, the Shortcuts label goes first (its ? key stays), then the Delete hint, then the
    /// global toggle hint.
    private var keyFooter: some View {
        ViewThatFits(in: .horizontal) {
            keyFooterRow(showToggle: true, shortcutsLabel: true)
            keyFooterRow(showToggle: true, shortcutsLabel: false)
            keyFooterRow(showToggle: true, shortcutsLabel: false, showDelete: false)
            keyFooterRow(showToggle: false, shortcutsLabel: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }

    private func keyFooterRow(showToggle: Bool, shortcutsLabel: Bool, showDelete: Bool = true) -> some View {
        HStack(spacing: 8) {
            footerHint(prefs.key(.previous).display + prefs.key(.next).display, "Select")
            footerHint(prefs.key(.open).display, "Open")
            footerHint(prefs.key(.toggleDone).display, "Done")
            if showDelete { footerHint(prefs.key(.delete).display, "Delete") }
            if showToggle {
                footerHint(prefs.key(.toggleWidget).display, "Hide")
                    .keyHelp(prefs, "Show or hide the widget from any app", .toggleWidget)
            }
            Spacer(minLength: 4)
            Button { model.showShortcuts = true } label: {
                HStack(spacing: 4) {
                    KeyCap(prefs.key(.shortcuts).display)
                    if shortcutsLabel { Text("Shortcuts") }
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .keyHelp(prefs, "Show all keyboard shortcuts", .shortcuts)
            .accessibilityLabel("Shortcuts")
        }
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(key)
            Text(label)
        }
        .fixedSize()
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Today").font(.system(size: 20, weight: .bold))
                Text("\(model.open.count) open · \(model.unreadCount) unread")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    if prefs.runnerEnabled, let runner = AppServices.shared?.runner {
                        Button {
                            runner.runNow()
                            model.showToast("Run started: Claude Code (built-in runner)", undoable: false)
                        } label: {
                            Label(runner.isRunning ? "Running…" : "Run now", systemImage: "play.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .glassButton(prominent: true)
                        .disabled(runner.isRunning)
                        .keyHelp(prefs, "Run the agent now", .runNow)
                    }
                    Button { prefs.pinned.toggle() } label: {
                        Image(systemName: prefs.pinned ? "pin.fill" : "pin").frame(width: 16, height: 16)
                    }
                    .glassButton()
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .focusEffectDisabled()
                    .keyHelp(prefs, prefs.pinned ? "Unpin: close when the pointer leaves" : "Pin the drawer open", .pin)
                    .accessibilityLabel(prefs.pinned ? "Unpin drawer" : "Pin drawer open")
                    Button { AppServices.shared?.showSettings() } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 16, height: 16)
                    }
                        .glassButton()
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                        .focusEffectDisabled()
                        .keyHelp(prefs, "Settings", .settings)
                        .accessibilityLabel("Settings")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    // MARK: update

    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            Text(updater.updateError ?? "Todo Widget \(updater.latest ?? "") is available").font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            Button(updater.updating ? "Updating…" : (updater.method == .homebrew ? "Update" : "Get it")) {
                if updater.method == .homebrew { updater.updateNow() } else { updater.openReleasePage() }
            }
            .glassButton().controlSize(.small).disabled(updater.updating)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .liquidGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: what changed

    private var runStrip: some View {
        let runs = model.recentRuns
        var counts: [String: Int] = [:]
        var order: [String] = []
        for r in runs {
            if counts[r.actor] == nil { order.append(r.actor) }
            counts[r.actor, default: 0] += 1
        }
        let who = order.map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: ", ")
        let total = runs.reduce(into: RunStats(added: 0, updated: 0, done: 0, reordered: 0, deleted: 0)) { acc, r in
            acc.added += r.stats.added; acc.done += r.stats.done; acc.reordered += r.stats.reordered
            acc.updated += r.stats.updated; acc.deleted += r.stats.deleted
        }
        let totalText = ChangeGroup(id: "", kind: "run", actor: "", label: "", createdAt: 0, finishedAt: nil, summary: nil, stats: total, undone: false, events: []).statsText
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { runsExpanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").font(.caption)
                            Text("Since \(clockTime(runs.first?.createdAt ?? 0)) · \(who)").font(.caption.weight(.semibold))
                            Image(systemName: runsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        Text(totalText).font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(runsExpanded ? "Collapse runs" : "Show each run")
                Button("Undo all") { model.undoRecentRuns() }
                    .glassButton().controlSize(.small)
                Button { model.dismissRecentRuns() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Mark changes seen")
            }
            if runsExpanded {
                VStack(spacing: 0) {
                    ForEach(runs, id: \.id) { r in
                        Divider().opacity(0.5)
                        HStack(spacing: 8) {
                            Text(clockTime(r.createdAt)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .leading)
                            Text(r.actor).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(r.statsText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Button("Undo") { model.undoGroup(r.id) }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .liquidGlass(.regular.tint(.accentColor.opacity(0.18)), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: quick add

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(.secondary)
            TextField("Add task…", text: Bindable(model).quickAddDraft)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .onSubmit {
                    model.add(model.quickAddDraft)
                    model.quickAddDraft = ""
                }
                .onChange(of: addFocused) { _, f in if f { controller.engage() } }
            if prefs.showKeyHints { KeyCap(prefs.key(.newTask).display) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
        .overlay {
            // Same ring as the highlighted row: the keyboard is here, not on the list.
            if addFocused {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .keyHelp(prefs, "New task", .newTask)
    }

    // MARK: rows

    private func row(_ t: TodoTask, index: Int) -> some View {
        let fromIndex = dragging.flatMap { id in model.open.firstIndex { $0.id == id } }
        let movingDown = (fromIndex ?? 0) < index
        let isTarget = dropTarget == t.id && dragging != t.id
        return TaskRow(task: t, chip: t.chip(lastSeen: model.lastSeenAt), highlighted: model.highlightedId == t.id && !addFocused,
                       prefs: prefs, onToggle: { model.toggleDone(t) }, onOpen: {
            controller.engage()
            model.select(t)
        })
        .opacity(dragging == t.id ? 0.35 : 1)
        .overlay(alignment: movingDown ? .bottom : .top) {
            if isTarget { Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 6) }
        }
        .onHover { if $0 { model.hoverHighlight(t.id) } }
        .onDrag {
            dragging = t.id
            return NSItemProvider(object: t.id as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            defer { dragging = nil; dropTarget = nil }
            guard let id = items.first, id != t.id else { return false }
            model.move(id, to: index)
            return true
        } isTargeted: { inside in
            if inside { dropTarget = t.id } else if dropTarget == t.id { dropTarget = nil }
        }
        .contextMenu {
            Button("Open") { model.select(t) }.menuShortcut(prefs, .open)
            if t.sourceUrl != nil {
                Button("Open in \(t.source ?? "source")") { model.openSource(t) }.menuShortcut(prefs, .openSource)
            }
            Button("Mark done") { model.toggleDone(t) }.menuShortcut(prefs, .toggleDone)
            Button("Move up") { model.nudge(t.id, by: -1) }.menuShortcut(prefs, .moveUp).disabled(index == 0)
            Button("Move down") { model.nudge(t.id, by: 1) }.menuShortcut(prefs, .moveDown)
            Divider()
            Button("Delete", role: .destructive) { model.delete(t) }.menuShortcut(prefs, .delete)
        }
    }

    private func sectionDivider(_ title: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.tertiary)
            Rectangle().fill(.separator).frame(height: 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var doneSection: some View {
        VStack(spacing: 2) {
            Button { withAnimation(.snappy) { model.doneExpanded.toggle() } } label: {
                HStack {
                    Text("Done today · \(model.done.count)").font(.caption.weight(.semibold))
                    Image(systemName: model.doneExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Spacer()
                    Text(prefs.clearDone == .never ? "" : prefs.clearDone == .midnight ? "Clears at midnight" : "Clears after 24 h")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyHelp(prefs, model.doneExpanded ? "Hide done tasks" : "Show done tasks", .toggleDoneSection)
            .padding(.top, 10)
            if model.doneExpanded {
                ForEach(model.done, id: \.id) { t in
                    TaskRow(task: t, chip: nil, highlighted: model.highlightedId == t.id && !addFocused, prefs: prefs,
                            onToggle: { model.toggleDone(t) }, onOpen: { controller.engage(); model.select(t) })
                        .onHover { if $0 { model.hoverHighlight(t.id) } }
                }
            }
        }
    }

    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            Text(toast.text).font(.caption).lineLimit(2)
            Spacer(minLength: 4)
            if toast.undoable {
                Button("Undo \(prefs.key(.undo).display)") { model.undo() }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .liquidGlass(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .id(toast.id)
    }
}

struct TaskRow: View {
    let task: TodoTask
    let chip: String?
    var highlighted = false
    let prefs: Preferences
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hover && !task.isDone ? 1 : 0)
                .accessibilityHidden(true)
            Button(action: onToggle) {
                ZStack {
                    Circle().strokeBorder(Color.secondary.opacity(task.isDone ? 0.35 : 0.6), lineWidth: 1.5)
                    if task.isDone {
                        // Muted so completed rows recede instead of drawing the eye.
                        Circle().fill(Color.green.opacity(0.32))
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.primary.opacity(0.6))
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark not done" : "Mark done")
            .keyHelp(prefs, task.isDone ? "Mark not done" : "Mark done", .toggleDone)
            if !task.isDone {
                Capsule().fill(Palette.priority(task.priority)).frame(width: 4, height: 26).accessibilityHidden(true)
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 13, weight: task.unread && !task.isDone ? .semibold : .regular))
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .lineLimit(1)
                    if !task.meta.isEmpty && !task.isDone {
                        Text(task.meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyHelp(prefs, "Open", .open)
            if let chip {
                Text(chip)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(chip == "new" ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(chip == "new" ? Color.accentColor : .secondary)
            }
            if task.unread && !task.isDone {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).accessibilityLabel("Unread")
            }
        }
        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 8)
        .frame(minHeight: 46)
        .background {
            if task.unread && !task.isDone {
                RoundedRectangle(cornerRadius: 14).fill(.fill.secondary)
            } else if hover || highlighted {
                RoundedRectangle(cornerRadius: 14).fill(.fill.quaternary)
            }
        }
        .overlay {
            // The keyboard cursor.
            if highlighted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.5)
            }
        }
        .onHover { hover = $0 }
    }
}
