import SwiftUI

/// First-run (and "Run setup again") flow:
/// connect the MCP and grant permissions → let an agent discover sources → set up the schedule.
/// Only the connect step knows about specific agents (to write their MCP config correctly).
struct SetupView: View {
    let model: AppModel
    @Bindable var prefs: Preferences
    let onFinish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, theme, connect, sources, schedule, done
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .theme: "Theme"
            case .connect: "Connect"
            case .sources: "Sources"
            case .schedule: "Schedule"
            case .done: "All set"
            }
        }
    }

    @State var step: Step = .welcome
    @Environment(\.theme) private var theme

    // connect step
    @State private var codeStatus: String?
    @State private var codeOK = false
    @State private var desktopStatus: String?
    @State private var desktopOK = Integrations.claudeDesktopInstalled()
    @State private var otherCopied = false
    @State private var connectMyself = false
    @State private var cliStatus: String?
    @State private var notificationsOK = false
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            progress
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 36).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 720, height: 640)
        .e2eOpaque()
        .themedWindowBackground()
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? theme.accent : Color.secondary.opacity(0.25))
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
        case .theme: themeStep
        case .connect: connect
        case .sources: sources
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
                bullet("point.3.connected.trianglepath.dotted", "Connect the todo MCP to the AI agent you use. Any MCP-capable agent works.")
                bullet("sparkles", "Run one prompt in your agent. It works out with you which sources to check and saves them here.")
                bullet("clock", "Paste a schedule prompt into your agent. Every hour in your working hours it updates and re-ranks your list.")
                bullet("arrow.uturn.backward", "Every change shows who made it, and you can undo any of them.")
            }
            Text("Setup takes a few minutes. You can run it again from Settings › General.").foregroundStyle(.secondary)
        }
    }

    private var themeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Pick a theme", "Choose the colors for your drawer. You can change it, or build your own, in Settings › Themes.")
            ThemePicker(prefs: prefs)
            HStack {
                Text("Appearance").fontWeight(.semibold)
                Spacer()
                Picker("", selection: $prefs.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 240).labelsHidden()
            }
            .padding(14)
            .liquidGlass(in: .rect(cornerRadius: 16))
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Connect & permissions", "Add the todo MCP to the agent you use, then allow what the app needs.")
            Text("ADD THE MCP TO").font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
            row("Claude Code", "Runs `claude mcp add` for your user.", status: codeStatus, ok: codeOK, action: codeOK ? "Re-add" : "Add") {
                let r = Integrations.installClaudeCode()
                codeStatus = r.message
                codeOK = r.ok
            }
            row("Claude Desktop", "Adds todo to claude_desktop_config.json (backed up first). Restart Claude Desktop afterwards.",
                status: desktopStatus, ok: desktopOK, action: desktopOK ? "Re-add" : "Add") {
                let r = Integrations.installClaudeDesktop()
                desktopStatus = r.message
                desktopOK = r.ok
            }
            row("Any other agent", "Copies a standard MCP config to paste into your agent's MCP settings.",
                status: otherCopied ? "Copied. Paste it into your agent's MCP settings." : nil, ok: otherCopied, action: "Copy config") {
                Integrations.copy(Integrations.mcpSnippet())
                otherCopied = true
            }
            Toggle("I'll connect it myself", isOn: $connectMyself).toggleStyle(.checkbox).font(.caption)

            Text("PERMISSIONS").font(.system(size: 10, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary).padding(.top, 6)
            row("Notifications", "One notification when an agent run changes your list.", status: nil, ok: notificationsOK,
                action: notificationsOK ? "Allowed" : "Allow") {
                Notifier.requestPermission { notificationsOK = $0 }
            }
            if let hotkey = AppServices.shared?.hotkey, hotkey.needsAccessibility {
                row("Keyboard", "\(prefs.key(.toggleWidget).spoken) in any app to show or hide the widget. Needs Accessibility access.",
                    status: nil, ok: hotkey.accessibilityGranted, action: hotkey.accessibilityGranted ? "Allowed" : "Allow") {
                    hotkey.requestAccess()
                }
            }
            row("todo command", "Links the CLI into ~/.local/bin for you and your scripts.", status: cliStatus, ok: cliStatus?.hasPrefix("Linked") == true,
                action: "Install") {
                cliStatus = Integrations.installCLI().message
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open at login").fontWeight(.semibold)
                    Text(loginMessage ?? "Start Todo Widget when you log in, so your list is always there.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if LoginItem.needsApproval {
                    Button("Open Login Items") { LoginItem.openSystemSettings() }.glassButton()
                }
                Toggle("", isOn: $loginItem).toggleStyle(.switch).labelsHidden()
                    .onChange(of: loginItem) { _, on in
                        loginMessage = LoginItem.set(on)
                        loginItem = LoginItem.isEnabled || LoginItem.needsApproval
                    }
            }
            .padding(14)
            .liquidGlass(in: .rect(cornerRadius: 16))
        }
        .onAppear {
            Notifier.permissionGranted { notificationsOK = $0 }
            DispatchQueue.global().async {
                let ok = Integrations.claudeCodeInstalled()
                DispatchQueue.main.async { codeOK = ok }
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Discover your sources", "Paste this prompt into your agent. It will ask which tools to check and what matters in each, then save the sources here. This list updates as it does.")
            PromptBlock(title: "Discovery prompt", subtitle: "Works in any agent connected to the todo MCP.",
                        text: model.store.renderDiscoveryPrompt(), minHeight: 120, maxHeight: 150)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Sources").font(.headline)
                    Spacer()
                    if model.sources.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your agent…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(model.sources.count) saved").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
                ForEach(model.sources, id: \.id) { s in
                    SourceRow(source: s).padding(.vertical, 6)
                }
            }
            .padding(14)
            .liquidGlass(in: .rect(cornerRadius: 16))
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Set up the schedule", "Paste this prompt into your agent's scheduler once. Each run fetches its instructions from the app, so changes to your sources apply automatically.")
            VStack(alignment: .leading, spacing: 8) {
                Text("Working hours").font(.headline)
                ScheduleEditor(model: model)
            }
            PromptBlock(title: "Schedule prompt", subtitle: "Create a recurring task in your agent with this prompt.",
                        text: (try? model.store.renderSetupPrompt()) ?? "", minHeight: 150, maxHeight: 210)
                .id(model.revision)
            Toggle(isOn: $prefs.runnerEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Or let Todo Widget run it with Claude Code").fontWeight(.semibold)
                    Text("Runs `claude -p` in your working hours instead of your agent's scheduler.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .semibold)).foregroundStyle(.tint)
            Text("You're set up").font(.system(size: 26, weight: .bold))
            Text("The tab is on the \(prefs.edge.rawValue) edge of your screen. Click it to open your list, and drag it to move it.")
            Text(model.sources.isEmpty
                 ? "No sources yet. Run the discovery prompt any time from Settings › Sources."
                 : "Your agent will check \(model.sources.map(\.name).joined(separator: ", ")) on each run.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: chrome

    private var canContinue: Bool {
        switch step {
        case .connect: codeOK || desktopOK || otherCopied || connectMyself
        case .sources: !model.sources.isEmpty
        default: true
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(-1) }.glassButton()
            }
            Spacer()
            if step == .sources && model.sources.isEmpty {
                Button("Skip for now") { go(1) }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if step != .done {
                Button("Skip setup") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(step == .done ? "Open my list" : step == .welcome ? "Get started" : "Continue") {
                if step == .done { finish() } else { go(1) }
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 36).padding(.vertical, 20)
    }

    private func go(_ d: Int) {
        withAnimation(.snappy) { step = Step(rawValue: step.rawValue + d) ?? step }
    }

    private func finish() {
        prefs.setupComplete = true
        onFinish()
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(.init(sub)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ name: String, _ detail: String, status: String?, ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? theme.done : Color.secondary)
                .accessibilityLabel(ok ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.semibold)
                Text(.init(detail)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status { Text(status).font(.caption).foregroundStyle(.tint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Button(action, action: perform).glassButton()
        }
        .padding(14)
        .liquidGlass(in: .rect(cornerRadius: 16))
    }
}
