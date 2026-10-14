import ServiceManagement
import SwiftUI
import TodoCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, sources, prompt, schedules, agents, history
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .sources: "tray.2"
        case .prompt: "text.quote"
        case .schedules: "clock"
        case .agents: "point.3.connected.trianglepath.dotted"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    let prefs: Preferences
    let runner: Runner
    @State private var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $tab) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general: GeneralPane(model: model, prefs: prefs)
                    case .sources: SourcesPane(model: model)
                    case .prompt: PromptPane(model: model)
                    case .schedules: SchedulesPane(model: model, prefs: prefs, runner: runner)
                    case .agents: AgentsPane(model: model)
                    case .history: HistoryPane(model: model)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(tab.title)
        }
        .frame(minWidth: 820, minHeight: 600)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
    @State private var cliMessage: String?
    @State private var confirmReset = false

    var body: some View {
        PaneHeader(title: "General", subtitle: "How the drawer looks and behaves.")
        Card {
            CardRow(title: "Appearance", detail: "Applies to the drawer, the tab and this window.") {
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
                            .background(prefs.windowLevel == l ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(prefs.windowLevel == l ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1.5))
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
            CardRow(title: "Clear done tasks", detail: "Cleared tasks stay in History and can be restored.") {
                Picker("", selection: $prefs.clearDone) { ForEach(ClearDone.allCases) { Text($0.label).tag($0) } }
                    .frame(width: 170).labelsHidden()
            }
            Divider()
            CardRow(title: "Open at login", detail: loginMessage ?? "Start Todo Widget automatically when you log in to your Mac.") {
                HStack(spacing: 10) {
                    if LoginItem.needsApproval {
                        Button("Open Login Items") { LoginItem.openSystemSettings() }.buttonStyle(.glass).controlSize(.small)
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
                HStack {
                    Button("Install `todo` command in ~/.local/bin") { cliMessage = Integrations.installCLI().message }
                        .buttonStyle(.glass)
                    if let cliMessage { Text(cliMessage).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.top, 6)
            }
            .padding(16)
        }
        if let updater = AppServices.shared?.updater { UpdatesCard(updater: updater) }
        Card {
            CardRow(title: "Reset Todo Widget", detail: "Clears settings, sources and prompts, then runs setup again. You choose whether to keep your tasks.") {
                Button("Reset…", role: .destructive) { confirmReset = true }
                    .buttonStyle(.glass)
            }
        }
        .confirmationDialog("Reset Todo Widget?", isPresented: $confirmReset) {
            Button("Reset settings, keep my tasks") { AppServices.shared?.reset(eraseTasks: false) }
            Button("Erase everything, including tasks and history", role: .destructive) { AppServices.shared?.reset(eraseTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agent connections in Claude Code, Claude Desktop and Hermes are left as they are. Setup will walk you through the rest.")
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

// MARK: - Sources

struct SourcesPane: View {
    let model: AppModel
    @State private var sources: [Source] = []

    var body: some View {
        HStack(alignment: .top) {
            PaneHeader(title: "Sources", subtitle: "Where agents should look for new work. Enabled sources are added to the prompt, and each agent reads them through its own connectors.")
            Spacer()
            Button("Add source") {
                if let s = try? model.store.saveSource(source: Source(id: "", name: "New source", kind: "Messages", instructions: "", enabled: true, position: 0)) {
                    sources.append(s)
                }
            }
            .buttonStyle(.glassProminent)
        }
        Card {
            if sources.isEmpty {
                Text("No sources yet. Add Slack, Gmail, Linear, GitHub, Calendar… and describe what to look for.")
                    .foregroundStyle(.secondary).padding(16)
            }
            ForEach($sources, id: \.id) { $s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $s.enabled).toggleStyle(.switch).labelsHidden()
                        TextField("Name", text: $s.name).textFieldStyle(.plain).fontWeight(.semibold).frame(maxWidth: 200)
                        Picker("", selection: $s.kind) {
                            ForEach(["Messages", "Email", "Issues", "Code review", "Calendar", "Docs", "Other"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                        Spacer()
                        Button(role: .destructive) {
                            try? model.store.deleteSource(id: s.id)
                            sources.removeAll { $0.id == s.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(s.name)")
                    }
                    TextField("What to look for, e.g. DMs and mentions in #team where someone asks me for something", text: $s.instructions, axis: .vertical)
                        .textFieldStyle(.plain).foregroundStyle(.secondary).lineLimit(1...4)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .onChange(of: s) { _, new in _ = try? model.store.saveSource(source: new) }
                Divider()
            }
        }
        .onAppear { sources = (try? model.store.listSources()) ?? [] }
    }
}

// MARK: - Prompt

struct PromptPane: View {
    let model: AppModel
    @State private var draft = ""
    @State private var saved = ""
    @State private var preview: String?
    @State private var versions: [PromptVersion] = []

    var body: some View {
        HStack(alignment: .top) {
            PaneHeader(title: "Prompt", subtitle: "What every agent is told on each run. Agents fetch it live through get_instructions, so you don't need to update their schedules after editing it.")
            Spacer()
            Menu(versions.isEmpty ? "No versions" : "v\(versions.first!.version) · \(clockTime(versions.first!.createdAt))") {
                ForEach(versions, id: \.version) { v in
                    Button("v\(v.version) · \(clockTime(v.createdAt))") { draft = v.body }
                }
            }
            .fixedSize()
            Button("Save") {
                try? model.store.setPrompt(body: draft)
                load()
            }
            .buttonStyle(.glassProminent)
            .disabled(draft == saved)
        }
        HStack(alignment: .top, spacing: 16) {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 440)
                .background(.fill.quaternary, in: .rect(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 12) {
                Text("VARIABLES").font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                ForEach([("{{sources}}", "Enabled sources and their instructions"), ("{{last_run}}", "When the last run finished, from any agent"), ("{{now}}", "Current local time"), ("{{agent}}", "Name of the running agent")], id: \.0) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.0).font(.caption.monospaced()).foregroundStyle(.tint)
                        Text(v.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Preview rendered prompt") { preview = try? model.store.renderPrompt(agent: "Claude Code") }
                    .buttonStyle(.glass)
                Button("Reset to default") { draft = model.store.defaultPrompt() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }
            .frame(width: 210)
        }
        .onAppear(perform: load)
        .sheet(item: Binding(get: { preview.map { IdentifiedText(text: $0) } }, set: { preview = $0?.text })) { p in
            VStack(alignment: .leading) {
                ScrollView { Text(p.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Copy") { Integrations.copy(p.text) }; Button("Done") { preview = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 640, height: 520)
        }
    }

    private func load() {
        saved = (try? model.store.getPrompt()) ?? ""
        draft = saved
        versions = (try? model.store.promptVersions()) ?? []
    }
}

struct IdentifiedText: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - Schedules

struct SchedulesPane: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let runner: Runner
    @State private var setupDraft = ""
    @State private var copied: String?

    private struct AgentSeen: Identifiable { let id: String; let last: Int64; let count: Int }

    private var externalAgents: [AgentSeen] {
        let runs = (try? model.store.runsSince(sinceMs: 0)) ?? []
        var by: [String: (Int64, Int)] = [:]
        for r in runs where r.actor != Runner.agentName {
            let cur = by[r.actor] ?? (0, 0)
            by[r.actor] = (max(cur.0, r.createdAt), cur.1 + 1)
        }
        return by.map { AgentSeen(id: $0.key, last: $0.value.0, count: $0.value.1) }.sorted { $0.last > $1.last }
    }

    var body: some View {
        PaneHeader(title: "Schedules", subtitle: "Any number of agents and schedules can update the list. The widget only stores it.")

        Card {
            CardRow(title: "Built-in runner (claude -p)", detail: runnerDetail) {
                Toggle("", isOn: $prefs.runnerEnabled).toggleStyle(.switch).labelsHidden()
            }
            if prefs.runnerEnabled {
                Divider()
                HStack(spacing: 14) {
                    Picker("Days", selection: $prefs.runnerWeekdaysOnly) { Text("Weekdays").tag(true); Text("Every day").tag(false) }
                    Picker("Every", selection: $prefs.runnerIntervalMinutes) {
                        ForEach([30, 60, 120, 180, 240], id: \.self) { m in Text(m < 60 ? "\(m) min" : "\(m / 60) h").tag(m) }
                    }
                    Picker("From", selection: $prefs.runnerStartHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("To", selection: $prefs.runnerEndHour) { ForEach(1..<25, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("Model", selection: $prefs.runnerModel) { Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku") }
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allowed tools").fontWeight(.semibold)
                    Text("Runs are unattended, so only these tools are allowed. Keep source tools read-only.").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $prefs.runnerAllowedTools, axis: .vertical).font(.caption.monospaced()).textFieldStyle(.roundedBorder).lineLimit(2...5)
                    HStack {
                        Button(runner.isRunning ? "Running…" : "Run now") { runner.runNow() }.buttonStyle(.glassProminent).disabled(runner.isRunning)
                        Button("Copy command") { Integrations.copy(runner.commandPreview) }.buttonStyle(.glass)
                    }
                    .padding(.top, 4)
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

        if !externalAgents.isEmpty {
            Card {
                ForEach(externalAgents) { a in
                    CardRow(title: a.id, detail: "\(a.count) run\(a.count == 1 ? "" : "s") recorded") {
                        Text("Last run \(clockTime(a.last))").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule setup prompt").font(.headline)
                    Text("Paste this into Claude Desktop or Hermes when you create a scheduled task. It's generated from your settings, and you can edit it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to generated") {
                    try? model.store.setSetupPrompt(body: nil)
                    loadSetup()
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }
            TextEditor(text: $setupDraft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 140)
                .background(.fill.quaternary, in: .rect(cornerRadius: 18))
                .onChange(of: setupDraft) { _, v in try? model.store.setSetupPrompt(body: v) }
            HStack {
                Button("Copy and open Claude Desktop") {
                    copySetup(agent: "Claude Desktop")
                    Integrations.openClaudeDesktop()
                }
                .buttonStyle(.glassProminent)
                Button("Copy for Hermes") { copySetup(agent: "Hermes") }.buttonStyle(.glass)
                if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            try? model.store.setSetting(key: "schedule_text", value: prefs.scheduleText)
            loadSetup()
        }
    }

    private var runnerDetail: String {
        guard prefs.runnerEnabled else { return "Off. The widget runs Claude Code on a schedule using your login and connectors." }
        let next = runner.nextRun.map { clockTime(Int64($0.timeIntervalSince1970 * 1000)) } ?? "—"
        return "\(prefs.scheduleText.capitalizedFirst) · next run \(next)"
    }

    private func loadSetup() { setupDraft = (try? model.store.getSetupPrompt()) ?? "" }

    private func copySetup(agent: String) {
        if let text = try? model.store.renderSetupPrompt(agent: agent) {
            Integrations.copy(text)
            copied = "Copied for \(agent)"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Agents

struct AgentsPane: View {
    let model: AppModel
    @State private var codeOK = false
    @State private var desktopOK = false
    @State private var message: String?

    var body: some View {
        PaneHeader(title: "Connect agents", subtitle: "Each agent launches the local command todo mcp, so nothing needs to keep running in the background.")
        HStack(alignment: .top, spacing: 12) {
            agentCard("Claude Code", ok: codeOK, how: "Runs claude mcp add --scope user todo. The built-in runner uses it.", action: codeOK ? "Reinstall" : "Add") {
                let r = Integrations.installClaudeCode()
                message = r.message
                refresh()
            }
            agentCard("Claude Desktop", ok: desktopOK, how: "Adds \"todo\" to claude_desktop_config.json, with a backup of the old file. Restart Claude Desktop afterwards.", action: desktopOK ? "Reinstall" : "Add") {
                message = Integrations.installClaudeDesktop().message
                refresh()
            }
            agentCard("Hermes", ok: hermesSeen, how: "Paste the config below into Hermes’s MCP settings. It shows as connected after its first run.", action: "Copy config") {
                Integrations.copy(Integrations.mcpSnippet(agent: "Hermes"))
                message = "Hermes config copied."
            }
        }
        if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("For any other MCP client, paste this config:").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Integrations.copy(Integrations.mcpSnippet(agent: "Agent")) }.buttonStyle(.glass).controlSize(.small)
            }
            Text(Integrations.mcpSnippet(agent: "Agent"))
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 16))
                .foregroundStyle(.white)
        }
        .onAppear(perform: refresh)
    }

    private var hermesSeen: Bool {
        ((try? model.store.runsSince(sinceMs: 0)) ?? []).contains { $0.actor.localizedCaseInsensitiveContains("hermes") }
    }

    private func refresh() {
        desktopOK = Integrations.claudeDesktopInstalled()
        DispatchQueue.global().async {
            let ok = Integrations.claudeCodeInstalled()
            DispatchQueue.main.async { codeOK = ok }
        }
    }

    private func agentCard(_ name: String, ok: Bool, how: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).fontWeight(.semibold)
                Spacer()
                Text(ok ? "Connected" : "Not set up")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ok ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(ok ? Color.green : .secondary)
            }
            Text(how).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform).buttonStyle(.glass)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

// MARK: - History

struct HistoryPane: View {
    let model: AppModel
    @State private var groups: [ChangeGroup] = []

    var body: some View {
        PaneHeader(title: "History", subtitle: "Every change you or an agent made, including done tasks cleared at midnight. You can undo any group, even an older one. ⌘Z undoes the most recent.")
        ForEach(groups, id: \.id) { g in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(g.kind == "user" ? "You" : g.actor)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(g.kind == "run" ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.15), in: Capsule())
                    Text(clockTime(g.createdAt)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(g.displayLabel).lineLimit(1)
                    Spacer()
                    if g.undone {
                        Text("Undone").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(g.kind == "system" ? "Restore" : "Undo") { model.undoGroup(g.id) }.buttonStyle(.glass).controlSize(.small)
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
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
                        .buttonStyle(.glass).disabled(updater.checking)
                    if updater.updateAvailable {
                        if updater.method == .homebrew {
                            Button(updater.updating ? "Updating…" : "Update to \(updater.latest ?? "")") { updater.updateNow() }
                                .buttonStyle(.glassProminent).disabled(updater.updating)
                        } else {
                            Button("Get \(updater.latest ?? "")") { updater.openReleasePage() }.buttonStyle(.glassProminent)
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
        if updater.updateAvailable { return "Version \(updater.latest ?? "") is available." }
        if let checked = updater.lastChecked {
            return "Up to date. Checked \(clockTime(Int64(checked.timeIntervalSince1970 * 1000)))."
        }
        return "Checks GitHub for new releases every 6 hours."
    }
}
