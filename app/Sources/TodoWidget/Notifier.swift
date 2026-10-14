import Foundation
import UserNotifications

/// One notification per finished agent run, with Open and Undo actions.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = AppDefaults
    private var notified: Set<String>
    private let enabled: Bool
    var onOpen: (() -> Void)?
    var onUndo: ((String) -> Void)?

    override init() {
        notified = Set(defaults.stringArray(forKey: "notifiedRuns") ?? [])
        // UNUserNotificationCenter requires a bundled app (not `swift run`).
        enabled = Bundle.main.bundleIdentifier != nil && !E2E.enabled
        super.init()
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let undo = UNNotificationAction(identifier: "undo", title: "Undo run", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "run", actions: [open, undo], intentIdentifiers: [])])
        if defaults.object(forKey: "notifiedBaseline") == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: "notifiedBaseline")
        }
    }

    /// Asked during setup rather than at launch.
    static func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, !E2E.enabled else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }

    static func permissionGranted(_ done: @escaping @MainActor (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, !E2E.enabled else { done(false); return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    func check(_ runs: [ChangeGroup]) {
        let baseline = Int64((defaults.double(forKey: "notifiedBaseline")) * 1000)
        for run in runs where run.kind == "run" && run.finishedAt != nil && !notified.contains(run.id) {
            notified.insert(run.id)
            guard run.createdAt >= baseline, !run.events.isEmpty, !run.undone else { continue }
            post(run)
        }
        defaults.set(Array(notified.suffix(300)), forKey: "notifiedRuns")
    }

    private func post(_ run: ChangeGroup) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(run.actor) updated your list"
        var body = run.statsText
        if let s = run.summary, !s.isEmpty { body = "\(s) (\(run.statsText))" }
        content.body = body
        content.categoryIdentifier = "run"
        content.userInfo = ["run": run.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let run = response.notification.request.content.userInfo["run"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if action == "undo", let run { onUndo?(run) } else { onOpen?() }
        }
    }
}
