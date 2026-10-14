import ServiceManagement

/// Start-at-login via SMAppService (the app registers itself; shows in System Settings › Login Items).
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    /// Returns an error message, or nil on success.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on && needsApproval { return "Approve Todo Widget in System Settings › General › Login Items." }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Open at login is on by default: register once, on the first launch of an installed copy.
    /// Done only once so that turning it off in Settings sticks. Dev builds and e2e runs are skipped.
    static func enableByDefaultOnce() {
        let key = "loginItemDefaulted"
        guard !E2E.enabled, !AppDefaults.bool(forKey: key),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        AppDefaults.set(true, forKey: key)
        if !isEnabled { set(true) }
    }
}
