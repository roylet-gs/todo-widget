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
}
