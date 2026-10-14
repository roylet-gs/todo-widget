import SwiftUI
import TodoCore

/// First-run (and post-reset) setup: look & placement, sources, agents, schedule.
struct SetupView: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, placement, sources, agents, schedule, done
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .placement: "Look & placement"
            case .sources: "Sources"
            case .agents: "Connect agents"
            case .schedule: "Schedule"
            case .done: "All set"
            }
        }
    }

    struct Preset: Identifiable {
        let id: String
        let kind: String
        var instructions: String
        var on: Bool
    }

    @State private var step: Step = .welcome
    @State private var presets: [Preset] = [
        Preset(id: "Slack", kind: "Messages", instructions: "DMs, mentions, and threads where someone asks me for something.", on: true),
        Preset(id: "Gmail", kind: "Email", instructions: "Unread email from people (not newsletters) that needs a reply or action.", on: true),
        Preset(id: "Linear", kind: "Issues", instructions: "Issues assigned to me, and comments that mention me.", on: false),
        Preset(id: "GitHub", kind: "Code review", instructions: "PRs where my review is requested, and failing checks on my own PRs.", on: false),
        Preset(id: "Google Calendar", kind: "Calendar", instructions: "Meetings in the next 3 days that need prep or have an unanswered invite.", on: false),
    ]
    @State private var codeStatus: String?
    @State private var desktopStatus: String?
    @State private var hermesStatus: String?
    @State private var cliStatus: String?
    @State private var copied: String?
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 36).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 680, height: 580)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 36).padding(.top, 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .placement: placement
        case .sources: sources
        case .agents: agents
        case .schedule: schedule
        case .done: finished
        }
    }

    // MARK: steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checklist").font(.system(size: 44, weight: .semibold)).foregroundStyle(.tint)
            Text("Your list, kept current by your agents").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                bullet("sparkles", "Agents check your messages and work tools on a schedule, then add, complete and re-rank tasks.")
                bullet("bell.badge", "You get one notification per run, and changed tasks are marked unread.")
                bullet("arrow.uturn.backward", "Every change, yours or an agent's, can be undone.")
                bullet("rectangle.righthalf.inset.filled", "The list lives in a small glass tab on the edge of your screen. Click it to open; drag it anywhere.")
            }
            Text("Setup takes about a minute. You can change everything later in Settings.").foregroundStyle(.secondary)
        }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Look & placement", "Pick how the drawer looks and where it sits.")
            row("Appearance") {
                Picker("", selection: $prefs.appearance) { ForEach(Appearance.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            row("Screen edge") {
                Picker("", selection: $prefs.edge) { ForEach(Edge.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Window level").fontWeight(.semibold)
                Picker("", selection: $prefs.windowLevel) {
                    ForEach(WindowLevelPref.allCases) { l in
                        VStack(alignment: .leading) {
                            Text(l.label)
                            Text(l.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(l)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Sources", "Where should agents look for work? Agents read these through their own connectors. Edit the instructions in plain English.")
            ForEach($presets) { $p in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $p.on) {
                        HStack(spacing: 8) {
                            Text(p.id).fontWeight(.semibold)
                            Text(p.kind).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if p.on {
                        TextField("What to look for", text: $p.instructions, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    }
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            Text("You can add more sources later in Settings › Sources.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Connect agents", "Each agent launches the local `todo mcp` command. Add it to the tools you use.")
            agentRow("Claude Code", "Adds the MCP with claude mcp add (user scope). Needed for the built-in runner.", status: codeStatus) {
                codeStatus = Integrations.installClaudeCode().message
            }
            agentRow("Claude Desktop", "Adds \"todo\" to claude_desktop_config.json, with a backup. Restart Claude Desktop afterwards.", status: desktopStatus) {
                desktopStatus = Integrations.installClaudeDesktop().message
            }
            agentRow("Hermes", "Copies an MCP config to paste into Hermes’s MCP settings.", status: hermesStatus, action: "Copy config") {
                Integrations.copy(Integrations.mcpSnippet(agent: "Hermes"))
                hermesStatus = "Copied. Paste it into Hermes’s MCP settings."
            }
            agentRow("todo command", "Links the CLI into ~/.local/bin so you and your scripts can run `todo`.", status: cliStatus, action: "Install") {
                cliStatus = Integrations.installCLI().message
            }
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Schedule", "Who runs the agent? You can use both, and any number of agents can update the list.")
            Toggle(isOn: $prefs.runnerEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Todo Widget run Claude Code for me").fontWeight(.semibold)
                    Text("Runs `claude -p` in the background with your Claude Code login and connectors.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if prefs.runnerEnabled {
                HStack(spacing: 14) {
                    Picker("Days", selection: $prefs.runnerWeekdaysOnly) { Text("Weekdays").tag(true); Text("Every day").tag(false) }
                    Picker("Every", selection: $prefs.runnerIntervalMinutes) {
                        ForEach([30, 60, 120, 180, 240], id: \.self) { m in Text(m < 60 ? "\(m) min" : "\(m / 60) h").tag(m) }
                    }
                    Picker("From", selection: $prefs.runnerStartHour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    Picker("To", selection: $prefs.runnerEndHour) { ForEach(1..<25, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                }
                .fixedSize()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Using Claude Desktop or Hermes’s own scheduler?").fontWeight(.semibold)
                Text("Copy this prompt into its schedule builder. You can edit it later in Settings › Schedules.").font(.caption).foregroundStyle(.secondary)
                Text((try? model.store.renderSetupPrompt(agent: "Claude Desktop")) ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 14))
                HStack {
                    Button("Copy for Claude Desktop") { copySetup("Claude Desktop") }.buttonStyle(.glass)
                    Button("Copy for Hermes") { copySetup("Hermes") }.buttonStyle(.glass)
                    if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { try? model.store.setSetting(key: "schedule_text", value: prefs.scheduleText) }
        .onChange(of: prefs.scheduleText) { _, v in try? model.store.setSetting(key: "schedule_text", value: v) }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .semibold)).foregroundStyle(.tint)
            Text("You're set up").font(.system(size: 26, weight: .bold))
            Text("The tab is on the \(prefs.edge.rawValue) edge of your screen. Click it to open your list, and drag it to move it. It always snaps to the nearest side.")
            Text(prefs.runnerEnabled
                 ? "The first built-in run happens at the next scheduled time, or press Run now in the drawer."
                 : "Tasks will appear after your agent's first scheduled run. You can also add them yourself.")
                .foregroundStyle(.secondary)
            Toggle(isOn: $openAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Todo Widget when I log in").fontWeight(.semibold)
                    Text("So your list is always there. You can change this in Settings › General.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.top, 8)
        }
    }

    // MARK: chrome

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.buttonStyle(.glass)
            }
            Spacer()
            if step != .done {
                Button("Skip setup") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(step == .done ? "Open my list" : step == .welcome ? "Get started" : "Continue") {
                if step == .sources { saveSources() }
                if step == .done { finish() } else { go(1) }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36).padding(.vertical, 20)
    }

    private func go(_ d: Int) {
        withAnimation(.snappy) { step = Step(rawValue: step.rawValue + d) ?? step }
    }

    private func finish() {
        if openAtLogin != LoginItem.isEnabled { LoginItem.set(openAtLogin) }
        prefs.setupComplete = true
        onFinish()
    }

    private func saveSources() {
        let existing = Set(((try? model.store.listSources()) ?? []).map(\.name))
        for p in presets where p.on && !existing.contains(p.id) {
            _ = try? model.store.saveSource(source: Source(id: "", name: p.id, kind: p.kind, instructions: p.instructions, enabled: true, position: 0))
        }
    }

    private func copySetup(_ agent: String) {
        if let t = try? model.store.renderSetupPrompt(agent: agent) {
            Integrations.copy(t)
            copied = "Copied for \(agent)"
        }
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(.init(sub)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(title).fontWeight(.semibold); Spacer(); c() }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentRow(_ name: String, _ detail: String, status: String?, action: String = "Add", perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.semibold)
                Text(.init(detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status { Text(status).font(.caption).foregroundStyle(.tint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Button(action, action: perform).buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
