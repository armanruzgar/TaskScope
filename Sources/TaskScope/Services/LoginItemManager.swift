import Foundation
import ServiceManagement

enum LoginItemState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var label: String {
        switch self {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Requires Approval"
        case .notFound: "Unavailable"
        }
    }
}

protocol LoginItemServicing {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLoginItemService: LoginItemServicing {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var state: LoginItemState = .notRegistered
    @Published private(set) var message: String?

    var isEnabled: Bool {
        state == .enabled
    }

    private let service: any LoginItemServicing
    /// How long to wait before re-reading the state after a change, so a
    /// state macOS settles shortly after the call (such as Requires Approval)
    /// reaches the UI. Injectable for tests.
    private let verificationDelay: @Sendable () async throws -> Void
    private var delayedRefreshTask: Task<Void, Never>?

    init(
        service: any LoginItemServicing = SystemLoginItemService(),
        verificationDelay: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 750_000_000)
        }
    ) {
        self.service = service
        self.verificationDelay = verificationDelay
        refresh()
    }

    deinit {
        delayedRefreshTask?.cancel()
    }

    func refresh() {
        state = service.state
        message = message(for: state)
    }

    func setEnabled(_ enabled: Bool) {
        delayedRefreshTask?.cancel()
        do {
            if enabled {
                switch service.state {
                case .notRegistered, .notFound:
                    // `.notFound` is also reported for a stale registration of a
                    // moved or replaced bundle; registering this bundle repairs it.
                    try service.register()
                case .requiresApproval:
                    // Already registered; only the user can approve it, so take
                    // them to the setting instead of silently doing nothing.
                    service.openSystemSettings()
                case .enabled:
                    break
                }
            } else if service.state != .notRegistered {
                // `.notFound` still gets an unregister attempt: a stale
                // registration for a moved or replaced bundle can only be
                // cleared this way, and the thrown error is surfaced.
                try service.unregister()
            }
            refresh()
            scheduleVerification()
        } catch {
            refresh()
            message = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func scheduleVerification() {
        let verificationDelay = verificationDelay
        delayedRefreshTask = Task { [weak self] in
            do {
                try await verificationDelay()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func message(for state: LoginItemState) -> String {
        switch state {
        case .notRegistered:
            "Launch at Login is off."
        case .enabled:
            "Launch at Login is on."
        case .requiresApproval:
            "Launch at Login requires approval in System Settings."
        case .notFound:
            "macOS has no login item for this copy of TaskScope. Turn the switch on to register it."
        }
    }
}
