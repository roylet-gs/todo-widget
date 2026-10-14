import Foundation

/// Listens for the cross-process "db changed" Darwin notification posted by todo-core
/// (from the CLI/MCP process or this app) and calls back on the main actor.
@MainActor
final class DarwinObserver {
    static let name = "com.todowidget.db.changed"
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { me.fire() } }
            },
            Self.name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private var pending = false

    /// Coalesce bursts (an agent run writes many events) into one refresh.
    private func fire() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.onChange()
            }
        }
    }
}
