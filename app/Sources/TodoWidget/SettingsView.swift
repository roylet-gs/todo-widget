import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, themes, keyboard, sources, prompt, schedule, learning, history
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .themes: "paintpalette"
        case .keyboard: "keyboard"
        case .sources: "tray.2"
        case .prompt: "text.quote"
        case .schedule: "clock"
        case .learning: "lightbulb"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    let prefs: Preferences
    let runner: Runner
    @State var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(190)
            .e2eOpaque(.controlBackgroundColor)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general: GeneralPane(model: model, prefs: prefs)
                    case .themes: ThemesPane(prefs: prefs)
                    case .keyboard: KeyboardPane(prefs: prefs)
                    case .sources: SourcesPane(model: model)
                    case .prompt: PromptPane(model: model)
                    case .schedule: SchedulePane(model: model, prefs: prefs, runner: runner)
                    case .learning: LearningPane(model: model)
                    case .history: HistoryPane(model: model)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(tab.title)
            .e2eOpaque()
            .themedWindowBackground()
        }
        .frame(minWidth: 820, minHeight: 600)
        .e2eOpaque()
    }
}

// MARK: - shared bits

struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 4)
            .liquidGlass(.regular, in: .rect(cornerRadius: 20))
    }
}

struct CardRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

// MARK: - General

struct GeneralPane: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginMessage: String?
    @State private var confirmReset = false
    @Environment(\.theme) private var theme

    var body: some View {
        PaneHeader(title: "General", subtitle: "How the drawer looks and behaves.")
        Card {
            CardRow(title: "Appearance", detail: "Applies to the drawer, the tab and this window. Colors are in Themes.") {
                Picker("", selection: $prefs.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 240).labelsHidden()
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Window level").fontWeight(.semibold)
                HStack(spacing: 10) {
                    ForEach(WindowLevelPref.allCases) { l in
                        Button { prefs.windowLevel = l } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(l.label).fontWeight(.semibold)
                                Text(l.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .padding(12)
                            .background(prefs.windowLevel == l ? theme.accent.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(prefs.windowLevel == l ? theme.accent : Color.secondary.opacity(0.25), lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(prefs.windowLevel == l ? .isSelected : [])
                    }
                }
            }
            .padding(16)
            Divider()
            CardRow(title: "Screen edge", detail: "Or drag the tab to either side.") {
                Picker("", selection: $prefs.edge) { ForEach(Edge.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            Divider()
            CardRow(title: "Keep drawer open", detail: "Otherwise clicking anywhere outside the drawer closes it.") {
                Toggle("", isOn: $prefs.pinned).toggleStyle(.switch).labelsHidden()
            }
        }
        Card {
            CardRow(title: "Order tasks by priority", detail: "P1 tasks first, then P2, then P3. Dragging a task into another priority's group changes its priority.") {
                Toggle("", isOn: Binding(get: { model.orderByPriority }, set: { model.setOrderByPriority($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            CardRow(title: "Let agents complete and delete tasks", detail: "When off, agents can add and update tasks, but only you can mark them done or delete them.") {
                Toggle("", isOn: Binding(get: { !model.protectTasks }, set: { model.setProtectTasks(!$0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }
        Card {
            CardRow(title: "Clear done tasks", detail: "Cleared tasks stay in History and can be restored.") {
                Picker("", selection: $prefs.clearDone) { ForEach(ClearDone.allCases) { Text($0.label).tag($0) } }
                    .frame(width: 170).labelsHidden()
            }
            Divider()
            CardRow(title: "Open at login", detail: loginMessage ?? "Start Todo Widget automatically when you log in to your Mac.") {
                HStack(spacing: 10) {
                    if LoginItem.needsApproval {
                        Button("Open Login Items") { LoginItem.openSystemSettings() }.glassButton().controlSize(.small)
                    }
                    Toggle("", isOn: $loginItem).toggleStyle(.switch).labelsHidden()
                        .onChange(of: loginItem) { _, on in
                            loginMessage = LoginItem.set(on)
                            loginItem = LoginItem.isEnabled || LoginItem.needsApproval
                        }
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Status").fontWeight(.semibold)
                statusRow("MCP command", "\(Integrations.todoPath) mcp")
                statusRow("Last agent run", model.lastRunAt.map(clockTime) ?? "never")
                statusRow("Database", model.store.path())

            }
            .padding(16)
        }
        Card {
            CardRow(title: "Setup", detail: "Connect agents, rediscover sources or set up the schedule again. Your tasks are kept.") {
                Button("Run setup again") { AppServices.shared?.showSetup() }.glassButton()
            }
        }
        if let updater = AppServices.shared?.updater { UpdatesCard(updater: updater) }
        Card {
            CardRow(title: "Reset Todo Widget", detail: "Clears settings, sources and prompts, then runs setup again. You choose whether to keep your tasks.") {
                Button("Reset…", role: .destructive) { confirmReset = true }
                    .glassButton()
            }
        }
        .confirmationDialog("Reset Todo Widget?", isPresented: $confirmReset) {
            Button("Reset settings, keep my tasks") { AppServices.shared?.reset(eraseTasks: false) }
            Button("Erase everything, including tasks and history", role: .destructive) { AppServices.shared?.reset(eraseTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MCP connections you added to your agents are left as they are. Setup will walk you through the rest.")
        }
    }

    private func statusRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(v).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
        }
        .font(.callout)
    }
}

// MARK: - Keyboard

struct KeyboardPane: View {
    @Bindable var prefs: Preferences

    var body: some View {
        PaneHeader(title: "Keyboard", subtitle: "Run the widget without the mouse. Click a shortcut, then press the keys you want.")
        Card {
            CardRow(title: KeyAction.toggleWidget.title, detail: "Works from any app.") {
                HStack(spacing: 10) {
                    Picker("", selection: toggleStyle) {
                        ForEach(Self.doubleTaps, id: \.self) { b in Text(b.spoken).tag(Optional(b)) }
                        Divider()
                        Text("Shortcut").tag(KeyBinding?.none)
                    }
                    .labelsHidden().frame(width: 190)
                    if prefs.key(.toggleWidget).doubleTap == nil {
                        ShortcutRecorder(prefs: prefs, action: .toggleWidget)
                    }
                }
            }
            if prefs.key(.toggleWidget).doubleTap != nil, let hotkey = AppServices.shared?.hotkey {
                Divider()
                CardRow(title: "Accessibility access",
                        detail: hotkey.accessibilityGranted
                            ? "Allowed. macOS lets the widget see the double tap while you use other apps."
                            : "macOS needs this before the widget can see a double tap while you use other apps. A shortcut doesn't need it.") {
                    if hotkey.accessibilityGranted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant access") { hotkey.requestAccess() }.glassButton()
                    }
                }
            }
        }
        ForEach(KeyGroup.allCases.filter { $0 != .global }, id: \.self) { g in
            Text(g.rawValue).font(.headline).padding(.top, 4)
            Card {
                let actions = KeyAction.allCases.filter { $0.group == g }
                ForEach(Array(actions.enumerated()), id: \.element) { i, a in
                    if i > 0 { Divider() }
                    CardRow(title: a.title, detail: conflictText(a)) {
                        ShortcutRecorder(prefs: prefs, action: a)
                    }
                }
            }
        }
        Card {
            CardRow(title: "Show key hints", detail: "Key caps on buttons and a row of shortcuts along the bottom of the list.") {
                Toggle("", isOn: $prefs.showKeyHints).toggleStyle(.switch).labelsHidden()
            }
            Divider()
            CardRow(title: "Restore default shortcuts") {
                Button("Restore defaults") { prefs.keymap = Keymap() }
                    .glassButton()
                    .disabled(prefs.keymap == Keymap())
            }
        }
    }

    private func conflictText(_ a: KeyAction) -> String? {
        let c = prefs.keymap.conflicts(for: a)
        guard !c.isEmpty else { return nil }
        return "⚠︎ Also used by \(c.map(\.title).joined(separator: ", ")). Only one of them will run."
    }

    /// The double taps offered for the global toggle: the default (⌃ + double-tap ⌘) first, then each lone modifier.
    private static let doubleTaps = [KeyAction.toggleWidget.defaultBinding] + Mod.allCases.reversed().map { KeyBinding(doubleTap: $0) }

    /// The double tap in use, or nil for an ordinary shortcut.
    private var toggleStyle: Binding<KeyBinding?> {
        Binding {
            let b = prefs.key(.toggleWidget)
            return b.doubleTap == nil ? nil : b
        } set: { b in
            if let b {
                prefs.keymap.set(b, for: .toggleWidget)
            } else if prefs.key(.toggleWidget).doubleTap != nil {
                prefs.keymap.set(KeyBinding("space", [.control, .option]), for: .toggleWidget)
            }
        }
    }
}

/// Shows an action's keys; click it, then press new ones. Esc cancels.
struct ShortcutRecorder: View {
    @Bindable var prefs: Preferences
    let action: KeyAction
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : prefs.key(action).spoken)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 90)
            }
            .glassButton(prominent: recording)
            .accessibilityLabel("\(action.title) shortcut: \(prefs.key(action).spoken)")
            .accessibilityHint("Click, then press the new keys")
            Button { prefs.keymap.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Reset to \(action.defaultBinding.spoken)")
                .accessibilityLabel("Reset to default")
                .opacity(prefs.keymap.isDefault(action) ? 0 : 1)
                .disabled(prefs.keymap.isDefault(action))
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let b = event.keyCode == 53 ? nil : KeyBinding(event: event)  // Esc cancels
            MainActor.assumeIsolated { record(b) }
            return nil
        }
    }

    private func record(_ b: KeyBinding?) {
        guard let b else { stop(); return }
        if action == .toggleWidget && b.mods.filter({ $0 != .shift }).isEmpty {
            message = "Add ⌘, ⌥ or ⌃ so typing isn't affected"
            return
        }
        prefs.keymap.set(b, for: action)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

// MARK: - Sources (added by agents, editable here)

struct SourcesPane: View {
    let model: AppModel
    @State private var confirmDelete: Source?

    var body: some View {
        PaneHeader(title: "Sources", subtitle: "Agents add these with the discovery prompt. Edit or delete them here, or ask your agent. Every scheduled run checks them.")
        Card {
            if model.sources.isEmpty {
                Text("No sources yet. Run the discovery prompt below in your agent.")
                    .foregroundStyle(.secondary).padding(16)
            }
            ForEach(Array(model.sources.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                SourceRow(source: s, model: model) { confirmDelete = s }
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { model.deleteSource(s) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scheduled runs stop checking it. Your agent can add it again.")
        }
        PromptBlock(title: "Discovery prompt", subtitle: "Paste this into any agent connected to the todo MCP. It will ask you which sources to check and save them here.",
                    text: model.store.renderDiscoveryPrompt())
    }
}

/// A source as the agent saved it, read-only (setup shows these as they arrive).
struct SourceSummary: View {
    let source: Source

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(source.enabled ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                .accessibilityLabel(source.enabled ? "Enabled" : "Disabled")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(source.name).fontWeight(.semibold)
                    Text(source.kind).font(.caption).foregroundStyle(.secondary)
                }
                if !source.instructions.isEmpty {
                    Text(source.instructions).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One source, edited in place; text saves on Return or when a field loses focus.
struct SourceRow: View {
    let source: Source
    let model: AppModel
    let onDelete: () -> Void
    @State private var name = ""
    @State private var kind = ""
    @State private var instructions = ""
    @FocusState private var focus: Field?

    private enum Field { case name, kind, instructions }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("Name", text: $name)
                        .fontWeight(.semibold).fixedSize()
                        .focused($focus, equals: .name)
                        .accessibilityLabel("Source name")
                    TextField("Kind", text: $kind)
                        .font(.caption).foregroundStyle(.secondary)
                        .focused($focus, equals: .kind)
                        .accessibilityLabel("Kind")
                }
                TextField("What to look for", text: $instructions, axis: .vertical)
                    .font(.callout).foregroundStyle(.secondary)
                    .focused($focus, equals: .instructions)
                    .accessibilityLabel("Instructions")
            }
            .textFieldStyle(.plain)
            .onSubmit(save)
            .onChange(of: focus) { old, new in if old != nil && old != new { save() } }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { source.enabled }, set: { on in
                model.updateSource(Source(id: source.id, name: source.name, kind: source.kind,
                                          instructions: source.instructions, enabled: on, position: source.position))
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .help(source.enabled ? "Checked on every run" : "Skipped by runs")
            .accessibilityLabel("Check \(source.name) on every run")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Delete source")
                .accessibilityLabel("Delete \(source.name)")
        }
        .onAppear(perform: sync)
        .onChange(of: source) { _, _ in if focus == nil { sync() } }
    }

    private func sync() {
        name = source.name
        kind = source.kind
        instructions = source.instructions
    }

    private func save() {
        let edited = Source(id: source.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            kind: kind.trimmingCharacters(in: .whitespacesAndNewlines),
                            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                            enabled: source.enabled, position: source.position)
        guard edited != source else { return }
        // An empty or clashing name puts the stored one back.
        if edited.name.isEmpty || !model.updateSource(edited) { sync() }
    }
}

// MARK: - Prompt (read-only)

struct PromptPane: View {
    let model: AppModel

    var body: some View {
        PaneHeader(title: "Prompt", subtitle: "What every scheduled run is told. Agents fetch it fresh through get_instructions, so changes to your sources reach the next run.")
        PromptBlock(title: "Run prompt", subtitle: "Rendered with your current sources and last run time.",
                    text: (try? model.store.renderPrompt()) ?? "", minHeight: 420)
            .id(model.revision)
    }
}

// MARK: - Schedule

struct SchedulePane: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let runner: Runner

    private struct ActorRun: Identifiable { let id: String; let last: Int64; let count: Int }

    /// Last run per agent name, from run history (agents name themselves; nothing is registered).
    private var recentRuns: [ActorRun] {
        let runs = (try? model.store.runsSince(sinceMs: 0)) ?? []
        var by: [String: (Int64, Int)] = [:]
        for r in runs where r.kind == "run" {
            let cur = by[r.actor] ?? (0, 0)
            by[r.actor] = (max(cur.0, r.createdAt), cur.1 + 1)
        }
        return by.map { ActorRun(id: $0.key, last: $0.value.0, count: $0.value.1) }.sorted { $0.last > $1.last }
    }

    var body: some View {
        PaneHeader(title: "Schedule", subtitle: "Paste the schedule prompt into your agent's scheduler once. Each run fetches its instructions from the app, so later changes don't need a new schedule.")
        Card {
            CardRow(title: "Working hours", detail: "Used by the schedule prompt and the built-in runner.") { EmptyView() }
            ScheduleEditor(model: model).padding(.horizontal, 16).padding(.bottom, 14)
        }
        PromptBlock(title: "Schedule prompt", subtitle: "Paste this into your agent's scheduler as a recurring task.",
                    text: (try? model.store.renderSetupPrompt()) ?? "")
            .id(model.revision)

        if !recentRuns.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent runs").font(.headline)
                Text("The last run from each agent, by the name it gave. Check here if a schedule stops firing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card {
                ForEach(Array(recentRuns.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { Divider() }
                    CardRow(title: a.id, detail: "\(a.count) run\(a.count == 1 ? "" : "s")") {
                        Text("Last run \(clockTime(a.last))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }

        Card {
            CardRow(title: "Built-in runner (optional)", detail: prefs.runnerEnabled
                    ? "Runs claude -p in your working hours. Next run \(runner.nextRun.map { clockTime(Int64($0.timeIntervalSince1970 * 1000)) } ?? "—")."
                    : "Instead of your agent's scheduler, the app can run Claude Code's claude -p for you.") {
                Toggle("", isOn: $prefs.runnerEnabled).toggleStyle(.switch).labelsHidden()
            }
            if prefs.runnerEnabled {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Model", selection: $prefs.runnerModel) { Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku") }
                        .fixedSize()
                    Text("Allowed tools").fontWeight(.semibold)
                    Text("Runs are unattended, so only these tools are allowed. Keep source tools read-only.").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $prefs.runnerAllowedTools, axis: .vertical).font(.caption.monospaced()).textFieldStyle(.roundedBorder).lineLimit(2...5)
                    HStack {
                        Button(runner.isRunning ? "Running…" : "Run now") { runner.runNow() }.glassButton(prominent: true).disabled(runner.isRunning)
                        Button("Copy command") { Integrations.copy(runner.commandPreview) }.glassButton()
                    }
                }
                .padding(16)
                if !runner.log.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(runner.log.prefix(6)) { e in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(clockTime(Int64(e.startedAt.timeIntervalSince1970 * 1000))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                Text(e.ok ? "OK" : "Failed").font(.caption.weight(.semibold)).foregroundStyle(e.ok ? .green : .red).frame(width: 48, alignment: .leading)
                                Text(e.message).font(.caption).lineLimit(2)
                                Spacer()
                                Text("\(Int(e.duration))s").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// MARK: - Learning

/// What agents have learned about which tasks you want, and the feedback the next run will learn from.
struct LearningPane: View {
    let model: AppModel
    @State private var notes: [Learning] = []
    @State private var feedback: [Feedback] = []
    @State private var newNote = ""
    @State private var confirmClear: ClearTarget?
    @FocusState private var addFocused: Bool
    @Environment(\.theme) private var theme

    private enum ClearTarget: Identifiable {
        case notes, feedback
        var id: Self { self }
    }

    var body: some View {
        PaneHeader(title: "Learning", subtitle: "Agents learn which tasks you want from the ones you complete and the ones you reject. At the end of each run they turn new feedback into the notes below and clear it. The notes go into every run's prompt.")

        Card {
            HStack(spacing: 10) {
                Text("Notes").fontWeight(.semibold)
                Text("\(notes.count) of 25").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add note") { addFocused = true }.glassButton().controlSize(.small)
                Button("Clear all", role: .destructive) { confirmClear = .notes }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.red)
                    .disabled(notes.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if notes.isEmpty {
                Divider()
                Text("No notes yet. They appear after an agent's first run with feedback, or add your own.")
                    .foregroundStyle(.secondary).padding(16)
            }
            ForEach(notes, id: \.id) { n in
                Divider()
                NoteRow(note: n, model: model)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("Add a note, e.g. Never add tasks from #random", text: $newNote)
                    .textFieldStyle(.plain)
                    .focused($addFocused)
                    .onSubmit(addNote)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }

        Card {
            HStack(spacing: 10) {
                Text("Waiting for the next run").fontWeight(.semibold)
                Text(feedback.count == 1 ? "1 item" : "\(feedback.count) items").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear all", role: .destructive) { confirmClear = .feedback }
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.red)
                    .disabled(feedback.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if feedback.isEmpty {
                Divider()
                Text("Nothing new. Complete or reject tasks that agents add and they show up here until the next run learns from them.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(16)
            }
            ForEach(feedback, id: \.id) { f in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(f.kind == "good" ? "Completed" : "Rejected")
                        .font(.caption.weight(.semibold))
                        .frame(width: 76)
                        .padding(.vertical, 3)
                        .background((f.kind == "good" ? theme.done : Color.red).opacity(0.16), in: Capsule())
                        .foregroundStyle(f.kind == "good" ? theme.done : Color.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).fontWeight(.semibold).lineLimit(1)
                        Text([f.source, "added by \(f.addedBy)"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let r = f.reason { Text("“\(r)”").foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                    Button { remove { try $0.deleteFeedback(id: f.id) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove: the next run won't learn from it")
                        .accessibilityLabel("Remove feedback")
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in load() }
        .confirmationDialog(confirmClear == .notes ? "Clear all notes?" : "Clear all feedback?", isPresented: Binding(
            get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("Clear all", role: .destructive) {
                let target = confirmClear
                remove { target == .notes ? try $0.clearLearnings() : try $0.clearFeedback() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmClear == .notes
                 ? "Agents start learning your preferences from scratch."
                 : "The next run won't learn from these completed and rejected tasks.")
        }
    }

    private func load() {
        notes = (try? model.store.listLearnings()) ?? []
        feedback = (try? model.store.listFeedback()) ?? []
    }

    private func addNote() {
        let t = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        remove { _ = try $0.addLearning(text: t) }
        newNote = ""
    }

    /// Run a store change, then refresh (the change notification also reloads the model).
    private func remove(_ body: (TodoStore) throws -> Void) {
        do { try body(model.store) } catch { model.showToast("\(error)", undoable: false) }
        load()
    }
}

/// One note, edited in place; saved on Return or when the field loses focus.
private struct NoteRow: View {
    let note: Learning
    let model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(save)
                    .onChange(of: focused) { _, f in if !f { save() } }
                Text(note.author == "You" ? "Written by you · agents keep it" : "Learned by \(note.author) · \(clockTime(note.updatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { try? model.store.deleteLearning(id: note.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Delete note")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onAppear { text = note.text }
        .onChange(of: note.text) { _, t in if !focused { text = t } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != note.text else { return }
        if t.isEmpty { text = note.text; return }
        do { try model.store.updateLearning(id: note.id, text: t) } catch { text = note.text; model.showToast("\(error)", undoable: false) }
    }
}

// MARK: - History

struct HistoryPane: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var groups: [ChangeGroup] = []

    var body: some View {
        PaneHeader(title: "History", subtitle: "Every change you or an agent made, including done tasks cleared at midnight. You can undo any group, even an older one. ⌘Z undoes the most recent.")
        ForEach(groups, id: \.id) { g in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(g.kind == "user" ? "You" : g.actor)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(g.kind == "run" ? theme.accent.opacity(0.16) : Color.secondary.opacity(0.15), in: Capsule())
                    Text(clockTime(g.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(g.displayLabel).lineLimit(1)
                    Spacer()
                    if g.undone {
                        Text("Undone").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(g.kind == "system" ? "Restore" : "Undo") { model.undoGroup(g.id) }.glassButton().controlSize(.small)
                    }
                }
                ForEach(g.events.prefix(6), id: \.id) { e in
                    HStack(spacing: 8) {
                        Text(symbol(e.op)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 16)
                        Text(e.taskTitle).font(.caption).strikethrough(e.undone).lineLimit(1)
                        if let r = e.reason { Text("· \(r)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                if g.events.count > 6 { Text("and \(g.events.count - 6) more").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(.regular, in: .rect(cornerRadius: 20))
        }
        .onAppear(perform: load)
        .onChange(of: model.revision) { _, _ in load() }
    }

    private func load() { groups = (try? model.store.history(limit: 60)) ?? [] }

    private func symbol(_ op: String) -> String {
        switch op {
        case "create": "+"
        case "done": "✓"
        case "reopen": "↺"
        case "reorder", "move": "↕"
        case "delete": "−"
        case "archive": "⌫"
        default: "✎"
        }
    }
}

// MARK: - Updates

struct UpdatesCard: View {
    let updater: Updater
    @State private var copied = false

    var body: some View {
        Card {
            CardRow(title: "Version \(updater.current)", detail: detail) {
                HStack(spacing: 8) {
                    Button(updater.checking ? "Checking…" : "Check now") { updater.check(force: true) }
                        .glassButton().disabled(updater.checking)
                    if updater.updateAvailable {
                        if updater.method == .homebrew {
                            Button(updater.updating ? "Updating…" : "Update to \(updater.latest ?? "")") { updater.updateNow() }
                                .glassButton(prominent: true).disabled(updater.updating)
                        } else {
                            Button("Get \(updater.latest ?? "")") { updater.openReleasePage() }.glassButton(prominent: true)
                        }
                    }
                }
            }
            if updater.updateAvailable {
                Divider()
                HStack {
                    Text(updater.method.hint).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        Integrations.copy(updater.method.hint)
                        copied = true
                    }
                    .buttonStyle(.plain).foregroundStyle(.tint).font(.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var detail: String {
        if updater.updating { return "Updating with Homebrew. The app will restart when it's done." }
        if let error = updater.updateError { return "\(error). Homebrew's output is in \(Updater.logPath)." }
        if updater.updateAvailable { return "Version \(updater.latest ?? "") is available." }
        if let checked = updater.lastChecked {
            return "Up to date. Checked \(clockTime(Int64(checked.timeIntervalSince1970 * 1000)))."
        }
        return "Checks GitHub for new releases every 6 hours."
    }
}
