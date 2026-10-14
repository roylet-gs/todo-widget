import Foundation

struct RunLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var startedAt: Date
    var duration: TimeInterval
    var ok: Bool
    var message: String
}

/// Built-in scheduler: runs `claude -p` with the rendered prompt and the local `todo mcp` server.
@MainActor
@Observable
final class Runner {
    private let prefs: Preferences
    private let store: TodoStore
    private(set) var isRunning = false
    private(set) var log: [RunLogEntry] = []
    private var timer: Timer?
    static let agentName = "Claude Code"

    var lastRun: Date? {
        get { UserDefaults.standard.object(forKey: "runnerLastRun") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "runnerLastRun") }
    }

    init(prefs: Preferences, store: TodoStore) {
        self.prefs = prefs
        self.store = store
        if let data = UserDefaults.standard.data(forKey: "runnerLog"), let l = try? JSONDecoder().decode([RunLogEntry].self, from: data) {
            log = l
        }
        // Checking once a minute also catches up after sleep: the first tick after wake runs if due.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var nextRun: Date? {
        guard prefs.runnerEnabled else { return nil }
        let cal = Calendar.current
        var candidate = (lastRun ?? .distantPast).addingTimeInterval(TimeInterval(prefs.runnerIntervalMinutes * 60))
        if candidate < Date() { candidate = Date() }
        for _ in 0..<(8 * 24 * 4) {
            if inWindow(candidate) { return candidate }
            candidate = cal.date(byAdding: .minute, value: 15, to: candidate) ?? candidate
            if let start = cal.date(bySettingHour: prefs.runnerStartHour, minute: 0, second: 0, of: candidate), candidate < start, inWindow(start) {
                return start
            }
        }
        return nil
    }

    private func inWindow(_ d: Date) -> Bool {
        let cal = Calendar.current
        if prefs.runnerWeekdaysOnly && cal.isDateInWeekend(d) { return false }
        let h = cal.component(.hour, from: d)
        return h >= prefs.runnerStartHour && h < prefs.runnerEndHour
    }

    private func tick() {
        guard prefs.runnerEnabled, !isRunning, inWindow(Date()) else { return }
        let due = (lastRun ?? .distantPast).addingTimeInterval(TimeInterval(prefs.runnerIntervalMinutes * 60))
        if Date() >= due { runNow() }
    }

    var commandPreview: String {
        let args = arguments(prompt: "$(todo prompt --render --agent 'Claude Code')")
        return (["claude"] + args.map { $0.contains(" ") || $0.contains("{") ? "'\($0)'" : $0 }).joined(separator: " ")
    }

    private func arguments(prompt: String) -> [String] {
        let mcp = Integrations.mcpSnippet(agent: Self.agentName).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "  ", with: "")
        var args = ["-p", prompt, "--model", prefs.runnerModel, "--mcp-config", mcp]
        let tools = prefs.runnerAllowedTools.split(whereSeparator: \.isWhitespace).map(String.init)
        if !tools.isEmpty { args += ["--allowedTools"] + tools }
        args += ["--permission-prompts", "none", "--output-format", "json"]
        return args
    }

    func runNow() {
        guard !isRunning else { return }
        guard let claude = Integrations.claudePath else {
            append(RunLogEntry(startedAt: Date(), duration: 0, ok: false, message: "claude CLI not found"))
            return
        }
        let prompt: String
        do { prompt = try store.renderPrompt(agent: Self.agentName) } catch {
            append(RunLogEntry(startedAt: Date(), duration: 0, ok: false, message: "\(error)"))
            return
        }
        isRunning = true
        let start = Date()
        lastRun = start
        let args = arguments(prompt: prompt)
        DispatchQueue.global(qos: .utility).async {
            let r = Integrations.shell(claude, args)
            var message = r.err.isEmpty ? r.out : r.err
            if let data = r.out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = obj["result"] as? String {
                message = result
            }
            let entry = RunLogEntry(startedAt: start, duration: Date().timeIntervalSince(start), ok: r.code == 0,
                                    message: String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRunning = false
                    self.append(entry)
                }
            }
        }
    }

    private func append(_ e: RunLogEntry) {
        log.insert(e, at: 0)
        log = Array(log.prefix(20))
        if let data = try? JSONEncoder().encode(log) { UserDefaults.standard.set(data, forKey: "runnerLog") }
    }
}
