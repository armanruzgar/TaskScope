import Foundation
@testable import TaskScope

/// Stand-ins for the process-wide services views reach (L15-12). A view built
/// with these never submits to `AppCommandBus.shared`, never quits the test
/// process, never registers a global hotkey or reads the test runner's
/// preferences, and never touches UNUserNotificationCenter.
@MainActor
final class ViewTestDependencies {
    /// A bus of this test's own. A command the test does not expect stays
    /// queued here instead of reaching a handler another test installs.
    let commandBus = AppCommandBus()
    let hotkeyBackend = RecordingHotkeyBackend()
    let hotkey: HotkeyManager
    let notificationService: NotificationService
    /// How many times a view asked to quit.
    private(set) var quitRequests = 0
    /// What the bus received after `recordCommands()`.
    private(set) var receivedCommands: [TaskScopeCommand] = []

    init(notificationState: NotificationService.AuthorizationState = .unknown) {
        hotkey = .forTests(backend: hotkeyBackend)
        notificationService = .forTests(state: notificationState)
    }

    /// The quit action to give a view: it only counts.
    var quitAction: @MainActor () -> Void {
        { [weak self] in self?.quitRequests += 1 }
    }

    /// Installs a handler on this test's bus that records each command and
    /// reports it completed.
    func recordCommands() {
        commandBus.install { [weak self] command in
            self?.receivedCommands.append(command)
            return TaskScopeCommandResult(status: .completed, message: "recorded")
        }
    }
}

extension HotkeyManager {
    /// A manager on in-memory preferences whose backend registers nothing.
    @MainActor
    static func forTests(backend: RecordingHotkeyBackend = RecordingHotkeyBackend()) -> HotkeyManager {
        HotkeyManager(
            defaults: InMemoryUserDefaults(suiteName: "TaskScope.HotkeyManager.\(UUID().uuidString)")!,
            backend: backend
        )
    }
}

extension NotificationService {
    /// A service that never touches UNUserNotificationCenter and reports `state`.
    @MainActor
    static func forTests(state: AuthorizationState = .unknown) -> NotificationService {
        NotificationService(
            isAvailable: false,
            authorizationState: state,
            readAuthorization: { state },
            deliver: { _ in }
        )
    }
}
