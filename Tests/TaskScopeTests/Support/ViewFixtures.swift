import Foundation
@testable import TaskScope

// The fixtures view tests build their popovers and Settings from: a manager on
// shared fakes, in-memory stores, and doubles for the services views reach.

@MainActor
final class UIMenuBarConfirmation: MenuBarConfirming {
    var answer: Bool
    private(set) var requests: [MenuBarConfirmationRequest] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool {
        requests.append(request)
        return answer
    }
}

struct UILoginItemService: LoginItemServicing {
    var state: LoginItemState = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
struct UIActivityMonitor: ActivityMonitorCoordinating {
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        .missingProcess
    }
}

@MainActor
struct UIFixture {
    var manager: ProcessManager
    var signaler: FakeSignaler
    var stores: UIStores
    var lifecycle: FakeLifecycle
}

@MainActor
struct UIStores {
    var suiteName: String
    var defaults: UserDefaults
    var settings: SettingsStore
    var watchedApps: WatchedAppsStore
    var savedSelections: SavedSelectionsStore
    var autoStopRules: AutoStopRulesStore
    var history: ProcessHistory

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
