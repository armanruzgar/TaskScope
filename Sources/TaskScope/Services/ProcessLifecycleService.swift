import Foundation

/// Every termination entry point is scoped to a preset so the implementation
/// can require the executable directory. There is deliberately no name-only
/// termination API: a name alone is never sufficient to signal a process.
protocol ProcessTerminating: Sendable {
    func settleAfterProcessChange() async
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome
    func isProcessNamedRunning(_ name: String) async -> Bool
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool
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

extension UserLaunchAgentControlling {
    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        await unloadUserLaunchAgents(for: preset)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        .notNeeded
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        .notNeeded
    }
}

protocol SystemLaunchDaemonControlling: Sendable {
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult
}

extension SystemLaunchDaemonControlling {
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        .notNeeded
    }

    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        .notNeeded
    }
}

protocol AppBundleLaunching: Sendable {
    func appBundleExists(at path: String) -> Bool
    func openAppBundle(at path: String) async -> Bool
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

extension ProcessTerminating {
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds)
    }
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

    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded()
    }

    func appBundleExists(at path: String) -> Bool {
        Self.isAppBundle(at: path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange()
    }

    /// Both preset terminations escalate to SIGKILL only after the graceful
    /// window in `ProcessTerminationController` has elapsed with the identity
    /// still present; the confirmation dialog discloses that window.
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        return await ProcessLifecycleController.terminateProcess(
            named: preset.mainProcessName,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.mainExecutableDirectory
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            policy: .gracefulThenForce,
            expectedExecutableDirectory: preset.bundleContentsDirectory
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset)
    }

    func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32>
    ) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(
            for: preset,
            preservingPIDs: preservingPIDs
        )
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        await ProcessLifecycleController.disableUserLaunchAgents(for: preset, preservingVPNService: preservingVPNService)
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.enableUserLaunchAgents(for: preset)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset)
    }

    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: preset, allowAdministratorPrompt: allowAdministratorPrompt
        )
    }

    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.enableSystemLaunchDaemons(for: preset)
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(name, timeoutSeconds: timeoutSeconds)
    }

    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(
            preset.mainProcessName,
            timeoutSeconds: timeoutSeconds,
            expectedExecutableDirectory: preset.mainExecutableDirectory
        )
    }

    func openAppBundle(at path: String) async -> Bool {
        // Checked again here: the link may have been re-pointed since Open
        // checked that the bundle exists.
        guard Self.isAppBundle(at: path) else { return false }
        return await ProcessLifecycleController.openAppBundle(at: path)
    }
}
