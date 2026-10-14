import AppKit
import Foundation
import UserNotifications

/// "Is there a newer Todo Widget?": compares this build's version with the latest GitHub
/// Release of `repo` (tags are `vX.Y.Z`). The answer is cached for `interval`, and being
/// offline is normal, so failures are silent.
@MainActor
@Observable
final class Updater {
    nonisolated static let repo = "roylet-gs/todo-widget"
    nonisolated static let caskName = "todo-widget"
    private static let interval: TimeInterval = 6 * 60 * 60
    nonisolated static let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("todowidget-update.log").path

    enum InstallMethod {
        case homebrew, manual, dev

        /// Detected from where the app and Homebrew's Caskroom are.
        static var current: InstallMethod {
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            if path.contains("/.build/") || path.contains("/build/TodoWidget.app") { return .dev }
            let caskrooms = ["/opt/homebrew/Caskroom/\(caskName)", "/usr/local/Caskroom/\(caskName)"]
            if caskrooms.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return .homebrew }
            return .manual
        }

        var hint: String {
            switch self {
            case .homebrew: "brew update && brew upgrade --cask \(Updater.caskName)"
            case .dev: "git pull, then ./scripts/bundle-app.sh"
            case .manual: "Download the latest release from github.com/\(Updater.repo)/releases/latest"
            }
        }
    }

    let current: String
    private(set) var method = InstallMethod.current
    private(set) var latest: String?
    private(set) var lastChecked: Date?
    private(set) var checking = false
    private(set) var updating = false
    private(set) var updateError: String?
    private var timer: Timer?
    private var brewPath: String?
    private let d = AppDefaults

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest, than: current)
    }

    init() {
        current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        latest = d.string(forKey: "update.latest")
        lastChecked = d.object(forKey: "update.checkedAt") as? Date
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// Fetch the latest release unless the cached answer is still fresh (or `force`).
    func check(force: Bool = false) {
        if E2E.enabled { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        guard !checking else { return }
        checking = true
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let tag = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["tag_name"] as? String }
                .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(tag) }
            }
        }.resume()
    }

    private func finish(_ tag: String?) {
        checking = false
        guard let tag else { return }
        latest = tag
        lastChecked = Date()
        d.set(tag, forKey: "update.latest")
        d.set(lastChecked, forKey: "update.checkedAt")
        if updateAvailable && d.string(forKey: "update.notified") != tag {
            d.set(tag, forKey: "update.notified")
            notify(tag)
        }
    }

    private func notify(_ version: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = "Todo Widget \(version) is available"
        c.body = method == .homebrew ? "Open Settings to update, or run: \(method.hint)" : method.hint
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(version)", content: c, trigger: nil))
    }

    /// Homebrew installs: run the upgrade detached, then quit this app and reopen the new one.
    /// `brew upgrade` replaces the bundle on disk but leaves the running app alone, so the
    /// script does the restart itself. If the upgrade fails the app stays up and says so.
    func updateNow() {
        guard method == .homebrew, !updating else { return }
        let brew = brewPath ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "brew"
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundleURL.path
        let script = """
            \(brew) update && \(brew) upgrade --cask \(Self.caskName) || exit 1
            kill \(pid) 2>/dev/null
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            open '\(app)' || open -a TodoWidget
            """
        let log = Self.logPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/zsh", "-lc", "{\n\(script)\n} > '\(log)' 2>&1"]
        p.terminationHandler = { proc in
            let failed = proc.terminationStatus != 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.updateFinished(failed: failed) }
            }
        }
        do {
            try p.run()
            updating = true
            updateError = nil
        } catch {
            openReleasePage()
        }
    }

    private func updateFinished(failed: Bool) {
        updating = false
        if failed { updateError = "Update failed" }
    }

    /// e2e: pretend `version` is out and Homebrew lives at `brew`, so the update flow runs
    /// without the network or a real upgrade.
    func simulate(latest version: String, brew: String) {
        latest = version
        method = .homebrew
        brewPath = brew
    }

    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
    }

    /// Numeric x.y.z comparison; non-numeric parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
