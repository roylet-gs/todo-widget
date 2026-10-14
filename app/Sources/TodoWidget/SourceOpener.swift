import AppKit

/// Opens a task's source link in its desktop app when one is installed (Linear, Slack…), else on the web.
@MainActor
enum SourceOpener {
    enum Target: Equatable {
        case app(URL, URL)  // app bundle, URL to hand it
        case web(URL)
    }

    /// A web host and the desktop app that can show its links.
    private struct Rule {
        let hosts: [String]  // exact hosts, or ".example.com" for any subdomain
        let bundleId: String
        /// Rewrites https://host/path to scheme://path (or scheme://host/path with `keepHost`).
        /// nil hands the app the https URL, which it resolves itself.
        var scheme: String?
        var keepHost = false

        func matches(_ host: String) -> Bool {
            hosts.contains { $0.hasPrefix(".") ? host.hasSuffix($0) || host == $0.dropFirst() : host == $0 }
        }
    }

    private static let rules = [
        Rule(hosts: ["linear.app"], bundleId: "com.linear", scheme: "linear"),
        Rule(hosts: [".slack.com"], bundleId: "com.tinyspeck.slackmacgap"),
        Rule(hosts: [".notion.so", ".notion.site"], bundleId: "notion.id", scheme: "notion", keepHost: true),
        Rule(hosts: [".figma.com"], bundleId: "com.figma.Desktop"),
    ]

    /// What the last `open` resolved to, e.g. "app:com.linear linear://acme/issue/X-1" (shown in e2e state).
    private(set) static var lastOpened: String?

    static func target(for url: URL, appURL: (String) -> URL?, handles: (URL) -> Bool) -> Target {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(),
              let rule = rules.first(where: { $0.matches(host) }),
              let app = appURL(rule.bundleId) else { return .web(url) }
        guard let scheme = rule.scheme else { return .app(app, url) }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = scheme
        if !rule.keepHost, let path = c?.path.split(separator: "/") {
            c?.host = path.first.map(String.init)
            c?.path = "/" + path.dropFirst().joined(separator: "/")
        }
        guard let rewritten = c?.url, handles(rewritten) else { return .app(app, url) }
        return .app(app, rewritten)
    }

    static func open(_ url: URL) {
        let ws = NSWorkspace.shared
        let t = target(for: url, appURL: { ws.urlForApplication(withBundleIdentifier: $0) },
                       handles: { ws.urlForApplication(toOpen: $0) != nil })
        switch t {
        case let .app(app, link):
            lastOpened = "app:\(Bundle(url: app)?.bundleIdentifier ?? app.lastPathComponent) \(link.absoluteString)"
            guard !E2E.enabled else { return }
            ws.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) } }
            }
        case let .web(link):
            lastOpened = "web:\(link.absoluteString)"
            guard !E2E.enabled else { return }
            ws.open(link)
        }
    }
}
