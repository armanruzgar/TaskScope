/// The three explicit stop commands share execution order and failure priority,
/// while retaining their own targets and user-facing results.
enum PresetStopScope {
    case app, helpers, all

    var diagnosticAction: LifecycleDiagnosticFailure.Action {
        switch self {
        case .app: .quitApp
        case .helpers: .quitHelpers
        case .all: .close
        }
    }

    var incompleteMessage: String {
        switch self {
        case .app: "Quit did not complete."
        case .helpers: "Helper stop did not complete."
        case .all: "Quit App and Helpers did not complete."
        }
    }

    /// Shown while the stop runs, so the footer's spinner is not next to an
    /// earlier, unrelated result.
    func progressMessage(for preset: WatchedAppPreset) -> String {
        switch self {
        case .app: "Quitting \(preset.displayName)…"
        case .helpers: "Quitting the helpers of \(preset.displayName)…"
        case .all: "Quitting \(preset.displayName) and its helpers…"
        }
    }

    func inventoryFailure(for preset: WatchedAppPreset) -> PresetStopResult {
        .failed(
            self == .helpers
                ? "Could not read the process list; user helpers were not stopped."
                : "Could not read the process list; \(preset.displayName) was not stopped.",
            reason: .inventoryUnavailable
        )
    }

    func result(
        before: WatchedAppSnapshot,
        after: WatchedAppSnapshot,
        terminations: [ProcessTerminationOutcome],
        agents: LifecycleBatchResult,
        refreshed: Bool
    ) -> PresetStopResult {
        let name = before.preset.displayName
        // Signal/identity failures take precedence over job and final-read
        // failures, even if a later observation happens to show no targets.
        if terminations.contains(.inventoryUnavailable) {
            return .failed(
                "Could not read the process list for every stop target; the stop may be incomplete.",
                reason: .inventoryUnavailable
            )
        }
        if terminations.contains(.signalRejected) {
            return .failed(
                self == .helpers
                    ? "A stop signal was rejected; user helpers were not fully stopped."
                    : "A stop signal was rejected; \(name) was not fully stopped.",
                reason: .signalRejected
            )
        }
        if terminations.contains(.escalationUnavailable) {
            return .failed(
                self == .helpers
                    ? "Could not verify user helpers before Force Stop; they may still run."
                    : "Could not verify \(name) before Force Stop; it may still run.",
                reason: .verificationUnavailable
            )
        }
        if !agents.succeeded {
            let message: String
            switch self {
            case .app:
                let appState: String
                if !refreshed || after.isMainRunning {
                    appState = "\(name) may still run;"
                } else if before.isMainRunning {
                    appState = "\(name) quit, but"
                } else {
                    appState = "No \(name) app found, but"
                }
                message = "\(appState) relaunch jobs failed: \(agents.failureSummary ?? "unknown failure")."
            case .helpers:
                message = "Helper stop was incomplete: \(agents.failureSummary ?? "relaunch job failure")."
            case .all:
                message = "Quit App and Helpers was incomplete: \(agents.failureSummary ?? "relaunch job failure")."
            }
            return .failed(message, reason: .userLaunchAgentFailed)
        }
        if !refreshed {
            let message: String
            switch self {
            case .app:
                message = "Stop was requested, but TaskScope could not verify the final \(name) state."
            case .helpers:
                message = "Helper stop was requested, but TaskScope could not verify the final state."
            case .all:
                message = "Quit App and Helpers was requested, but TaskScope could not verify the final \(name) state."
            }
            return .failed(message, reason: .verificationUnavailable)
        }

        func completed(_ message: String) -> PresetStopResult {
            let vpnRemains = before.preset.hasSupportedGlobalProtectIdentity
                && (!after.protectedRunning.isEmpty || !after.unprivilegedProtectedRunning.isEmpty)
            return .completed(message + (vpnRemains
                ? " Its VPN service (PanGPS) is still running and the VPN was not disconnected; use Quit All in TaskScope to disconnect and stop it."
                : ""))
        }

        switch self {
        case .app:
            if !before.isMainRunning && !after.isMainRunning {
                return completed(agents.didChangeState ? "No \(name) app was running; launch agents unloaded." : "No \(name) app found.")
            }
            if after.isMainRunning {
                return .failed("\(name) may still run.", reason: .stillRunning)
            }
            return completed(agents.didChangeState
                ? "\(name) quit and launch agents unloaded."
                : "\(name) quit.")
        case .helpers:
            if before.helpersRunning.isEmpty && after.helpersRunning.isEmpty {
                return completed(agents.didChangeState ? "No user helpers were running; launch agents unloaded." : "No user helpers found.")
            }
            if !after.helpersRunning.isEmpty {
                return .failed("User helpers may still run.", reason: .stillRunning)
            }
            return completed(agents.didChangeState
                ? "User helpers quit and launch agents unloaded."
                : "User helpers quit.")
        case .all:
            if !before.isMainRunning && before.helpersRunning.isEmpty,
               !after.isMainRunning && after.helpersRunning.isEmpty {
                return completed(agents.didChangeState ? "No watched app or user helpers were running; launch agents unloaded." : "No watched app or user helpers found.")
            }
            if after.isMainRunning {
                return .failed("\(name) may still run.", reason: .stillRunning)
            }
            if !after.helpersRunning.isEmpty {
                return .failed("User helpers may still run.", reason: .stillRunning)
            }
            return completed(agents.didChangeState
                ? "\(name) and helpers quit and launch agents unloaded."
                : "\(name) and helpers quit.")
        }
    }
}

struct PresetStopResult {
    let message: String
    let failureReason: LifecycleDiagnosticFailure.Reason?

    var commandResult: TaskScopeCommandResult {
        TaskScopeCommandResult(status: failureReason == nil ? .completed : .failed, message: message)
    }

    static func completed(_ message: String) -> Self {
        Self(message: message, failureReason: nil)
    }

    static func failed(_ message: String, reason: LifecycleDiagnosticFailure.Reason) -> Self {
        Self(message: message, failureReason: reason)
    }
}

extension PresetStopScope {
    /// Every confirmation of a preset stop discloses what the stop request is
    /// and its escalation to SIGKILL.
    static var forceStopDisclosure: String {
        let window = Int(ProcessTerminationController.gracefulExitWindowSeconds)
        return "Sends SIGTERM. Apps may close without asking to save changes. "
            + "A process still running \(window) seconds after the stop request is force stopped."
    }

    /// The launch agents a Close (`.all`) of `preset` unloads before stopping its
    /// processes. For GlobalProtect that is only the interface agent: these stops
    /// never disconnect the VPN.
    static func closeAgentLabels(for preset: WatchedAppPreset) -> [String] {
        let agentPreset = preset.hasSupportedGlobalProtectIdentity ? preset.globalProtectInterfaceOnly : preset
        return agentPreset.lifecycleUserLaunchAgentJobs.map(\.label)
    }
}
