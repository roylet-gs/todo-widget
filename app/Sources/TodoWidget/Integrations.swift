import AppKit
import Foundation

/// Finding executables and registering the `todo mcp` command with agent tools.
enum Integrations {
    /// The bundled `todo` binary, or one on PATH during development.
    static var todoPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/todo").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("todo").path
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return which("todo") ?? bundled
    }

    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return which("claude")
    }

    static func which(_ name: String) -> String? {
        let r = shell("/bin/zsh", ["-lc", "command -v \(name)"])
        let p = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !p.isEmpty ? p : nil
    }

    static func mcpEntry(agent: String) -> [String: Any] {
        ["command": todoPath, "args": ["mcp", "--agent", agent]]
    }

    static func mcpSnippet(agent: String) -> String {
        let obj: [String: Any] = ["mcpServers": ["todo": mcpEntry(agent: agent)]]
        let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Claude Code

    static func claudeCodeInstalled() -> Bool {
        guard let claude = claudePath else { return false }
        return shell(claude, ["mcp", "get", "todo"]).code == 0
    }

    @discardableResult
    static func installClaudeCode() -> (ok: Bool, message: String) {
        guard let claude = claudePath else { return (false, "The claude CLI was not found. Install Claude Code, or run:\n\(claudeCodeCommand)") }
        _ = shell(claude, ["mcp", "remove", "todo", "--scope", "user"])
        let r = shell(claude, ["mcp", "add", "--scope", "user", "todo", "--", todoPath, "mcp", "--agent", "Claude Code"])
        return (r.code == 0, r.code == 0 ? "Added to Claude Code (user scope)." : r.err + r.out)
    }

    static var claudeCodeCommand: String {
        "claude mcp add --scope user todo -- \"\(todoPath)\" mcp --agent \"Claude Code\""
    }

    // MARK: Claude Desktop

    static var claudeDesktopConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static func claudeDesktopInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeDesktopConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return false }
        return servers["todo"] != nil
    }

    /// Merge our entry into claude_desktop_config.json, keeping a timestamped backup.
    @discardableResult
    static func installClaudeDesktop() -> (ok: Bool, message: String) {
        let url = claudeDesktopConfig
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var obj: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return (false, "claude_desktop_config.json is not a JSON object; not changed.")
                }
                obj = parsed
                let stamp = Int(Date().timeIntervalSince1970)
                try data.write(to: url.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json.bak-\(stamp)"))
            }
            var servers = obj["mcpServers"] as? [String: Any] ?? [:]
            servers["todo"] = mcpEntry(agent: "Claude Desktop")
            obj["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: url, options: .atomic)
            return (true, "Added to Claude Desktop. Restart Claude Desktop to load it.")
        } catch {
            return (false, "Could not update Claude Desktop config: \(error.localizedDescription)")
        }
    }

    static func openClaudeDesktop() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    // MARK: CLI on PATH

    static var cliLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/todo")
    }

    @discardableResult
    static func installCLI() -> (ok: Bool, message: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: cliLink)
            try fm.createSymbolicLink(atPath: cliLink.path, withDestinationPath: todoPath)
            return (true, "Linked \(cliLink.path)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: process helper

    struct Output { var code: Int32; var out: String; var err: String }

    static func shell(_ path: String, _ args: [String], input: String? = nil) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Output(code: -1, out: "", err: error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(code: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
    }
}
