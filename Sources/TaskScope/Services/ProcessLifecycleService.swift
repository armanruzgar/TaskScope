import Foundation

/// Every termination entry point is scoped to a preset so the implementation
/// can require the executable directory. There is deliberately no name-only
/// termination API: a name alone is never sufficient to signal a process.
protocol ProcessTerminating: Sendable {
    func settleAfterProcessChange() async
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool
}

protocol UserLaunchAgentControlling: Sendable {
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    /// Unloads the preset's user launch agents except any whose loaded pid is in
    /// `preservingPIDs` (used by Quit Helpers to keep an agent that runs the
    /// main process loaded).
    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult
}

protocol SystemLaunchDaemonControlling: Sendable {
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
}

protocol AppBundleLaunching: Sendable {
    func appBundleExists(at path: String) -> Bool
    func openAppBundle(at path: String) async -> AppBundleOpenResult
}

protocol ProcessLifecycleServicing:
    ProcessTerminating,
    UserLaunchAgentControlling,
    SystemLaunchDaemonControlling,
    AppBundleLaunching {
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult
}

extension ProcessLifecycleServicing {
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        .failed("Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
    }
}

enum AppBundleOpenResult: Equatable, Sendable {
    case opened
    case failed(String)
    var succeeded: Bool { if case .opened = self { return true }; return false }
}

struct SystemProcessLifecycleService: ProcessLifecycleServicing {
    /// True when `path` leads to an app bundle: after following links, a
    /// directory named `*.app` with `Contents/Info.plist`. `/usr/bin/open` would
    /// otherwise run a script, open a document or show a folder that a `*.app`
    /// link points at.
    static func isAppBundle(at path: String) -> Bool {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return false }
        defer { free(resolved) }
        let bundle = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var isDirectory: ObjCBool = false
        return bundle.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path)
    }

    let runtime: ProcessLifecycleRuntime
    private let disconnect: @Sendable () async -> GlobalProtectDisconnectResult

    /// The app's service: live launchd, signals, and the Accessibility disconnect.
    init() {
        runtime = .live
        disconnect = { await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded() }
    }

    /// An injected runtime never reaches the live Accessibility disconnect,
    /// which drives the real GlobalProtect app. Without an explicit
    /// `disconnect`, the GlobalProtect disconnect fails closed.
    init(
        runtime: ProcessLifecycleRuntime,
        disconnect: @escaping @Sendable () async -> GlobalProtectDisconnectResult = {
            .failed("Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
        }
    ) {
        self.runtime = runtime
        self.disconnect = disconnect
    }

    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        await disconnect()
    }

    func appBundleExists(at path: String) -> Bool {
        runtime.isAppBundle(path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange(runtime: runtime)
    }

    /// Both preset terminations escalate to SIGKILL only after the graceful
    /// window in `ProcessTerminationController` has elapsed with the identity
    /// still present; the confirmation dialog discloses that window.
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        return await ProcessLifecycleController.terminateProcess(
            named: preset.mainProcessName,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.mainExecutableDirectory,
            runtime: runtime
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.bundleContentsDirectory,
            runtime: runtime
        )
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: runtime)
    }

    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(
            for: preset,
            preservingPIDs: preservingPIDs,
            runtime: runtime
        )
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: runtime)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        await ProcessLifecycleController.disableUserLaunchAgents(for: preset, preservingVPNService: preservingVPNService, runtime: runtime)
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.enableUserLaunchAgents(for: preset, runtime: runtime)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset, runtime: runtime)
    }

    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: preset, allowAdministratorPrompt: allowAdministratorPrompt, runtime: runtime
        )
    }

    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.enableSystemLaunchDaemons(for: preset, runtime: runtime)
    }

    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(
            preset.mainProcessName,
            timeoutSeconds: timeoutSeconds,
            expectedExecutableDirectory: preset.mainExecutableDirectory,
            runtime: runtime
        )
    }

    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        // Checked again here: the link may have been re-pointed since Open
        // checked that the bundle exists.
        guard runtime.isAppBundle(path) else {
            return .failed("The app path no longer leads to an app bundle.")
        }
        return await ProcessLifecycleController.openAppBundle(at: path, runtime: runtime)
    }
}
