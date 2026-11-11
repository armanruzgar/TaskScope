import XCTest
@testable import TaskScope

/// Adding a watched preset for an app that is *already* running must not announce it
/// as having just started.
///
/// The re-baseline used to be computed from `processManager.snapshots` before the
/// refresh, i.e. from snapshots that predated the new preset list and therefore had
/// no entry for it. The next refresh then diffed the new preset's already-running
/// names against a baseline that never contained them.
@MainActor
final class WatchedPresetNotificationBaselineTests: XCTestCase {
    private let presetID = UUID()
    func testAddingAPresetForAnAlreadyRunningAppDoesNotAnnounceAStart() async {
        let running = [appProcess(pid: 41, name: "Slack")]
        let manager = makeManager(inventory: StubInventory(processes: running))

        var started: [Set<String>] = []
        var primed: [Set<String>] = []
        manager.notifyTransitions = { started.append(Set($0.flatMap(\.runningNames))) }
        manager.primeNotificationBaseline = { primed.append(Set($0.flatMap(\.runningNames))) }

        // The preset list changes to include an app that is already running, and the
        // manager has no snapshot for it yet.
        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }
        XCTAssertTrue(manager.snapshots.isEmpty, "precondition: no snapshot for the new preset")

        // Note: an ordinary refresh, with no flag. The decision is made inside
        // `apply`, so no caller can get it wrong and no ordering can defeat it.
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertTrue(started.isEmpty, "a changed watched-name set must not be diffed")
        XCTAssertEqual(
            primed,
            [["Slack"]],
            "the baseline must come from the refreshed snapshots, which include the running app"
        )

        // A subsequent refresh with the same watched names must diff normally.
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertEqual(started, [["Slack"]], "one diff, against a baseline that already had Slack")
    }

    /// The ordinary path must still report a genuine start.
    func testAGenuineStartIsStillReported() async {
        let inventory = StubInventory(processes: [])
        let manager = makeManager(inventory: inventory)
        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }

        var started: [Set<String>] = []
        manager.notifyTransitions = { started.append(Set($0.flatMap(\.runningNames))) }

        await manager.refreshWatchedStatus(showMessage: false)
        inventory.processes = [appProcess(pid: 41, name: "Slack")]
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertEqual(started, [["Slack"]], "a real start must still reach the notifier")
    }

    /// Turning a preset's notification switch on changes which names the baseline
    /// covers, so that refresh must re-baseline rather than diff — otherwise the
    /// already-running app is announced as newly started.
    func testEnablingNotificationsForARunningPresetDoesNotAnnounceAStart() async {
        let manager = makeManager(
            inventory: StubInventory(processes: [appProcess(pid: 41, name: "Slack")])
        )
        var silent = preset(named: "Slack")
        silent.notificationsEnabled = false
        manager.watchedAppsProvider = { [silent] }
        await manager.refreshWatchedStatus(showMessage: false)

        var started: [Set<String>] = []
        var primed: [Set<String>] = []
        manager.notifyTransitions = { started.append(Set($0.flatMap(\.runningNames))) }
        manager.primeNotificationBaseline = { primed.append(Set($0.flatMap(\.runningNames))) }

        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(primed, [["Slack"]])
    }

    /// The quick "watch this process" action used to fire its own refresh with no
    /// re-baseline, racing the app's preset-change handler. Whichever won, the
    /// result was wrong. `apply` now decides for itself, so even a bare extra
    /// refresh arriving first cannot produce a false start.
    func testAnExtraUnflaggedRefreshCannotProduceAFalseStart() async {
        let manager = makeManager(
            inventory: StubInventory(processes: [appProcess(pid: 41, name: "Slack")])
        )
        var calls: [String] = []
        manager.notifyTransitions = { _ in calls.append("diff") }
        manager.primeNotificationBaseline = { _ in calls.append("prime") }

        manager.watchedAppsProvider = { [self.preset(named: "Slack")] }
        // Two bare refreshes, as the quick-watch action and the preset-change
        // handler used to produce between them.
        await manager.refreshWatchedStatus(showMessage: false)
        await manager.refreshWatchedStatus(showMessage: false)

        XCTAssertEqual(
            calls.first,
            "prime",
            "the first refresh after the watched-name set changed must re-baseline, never diff"
        )
        XCTAssertEqual(calls, ["prime", "diff"])
    }

    // MARK: - Helpers

    private func makeManager(inventory: any ProcessInventoryProviding) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: InertSignaler(),
            lifecycle: InertLifecycle(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = true
        return manager
    }

    private func preset(named name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            id: presetID,
            displayName: name,
            mainProcessName: name,
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app"
        )
    }

    private func appProcess(pid: Int32, name: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: getuid(),
            cpu: 1,
            memoryMB: 1,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "01:00",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

private final class StubInventory: ProcessInventoryProviding, @unchecked Sendable {
    var processes: [AppProcess]

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private struct InertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct InertLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { false }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .failed("Fake launch failed.") }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}
