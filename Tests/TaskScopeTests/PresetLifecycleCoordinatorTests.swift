import XCTest
@testable import TaskScope

/// ProcessManager's dependencies and the preset lifecycle coordinator: the
/// app wiring, the explicit inert value, and each action's single outcome.
@MainActor
final class PresetLifecycleCoordinatorTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults(suiteName: "TaskScope.PresetLifecycleCoordinatorTests.\(UUID().uuidString)")!
    }

    private func example() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
    }

    // MARK: - Dependencies

    /// T02-6: the app's wiring reads and writes the stores it was given.
    func testAppDependenciesFollowTheStores() async {
        let defaults = makeDefaults()
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let watchedApps = WatchedAppsStore(userDefaults: defaults, key: "presets")
        let custom = example()
        XCTAssertTrue(watchedApps.add(custom))
        let observation = GlobalProtectServiceObservation(session: .absent, system: .running)
        let dependencies = ProcessManager.Dependencies.app(
            settings: settings, watchedApps: watchedApps, globalProtectServiceObservation: { observation }
        )

        XCTAssertEqual(dependencies.watchedPresets().map(\.id), [WatchedAppPreset.globalProtectID, custom.id])
        XCTAssertEqual(dependencies.processListLimit(), SettingsStore.defaultProcessListLimit)
        settings.processListLimit = 120
        XCTAssertEqual(dependencies.processListLimit(), 120)

        XCTAssertTrue(dependencies.keptOffPresets().isEmpty)
        dependencies.setPresetKeptOff(.globalProtect, true)
        XCTAssertTrue(settings.keepGlobalProtectOff)
        XCTAssertEqual(dependencies.keptOffPresets().map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertTrue(dependencies.isPresetKeptOff(.globalProtect))
        XCTAssertFalse(dependencies.isPresetKeptOff(custom))
        dependencies.setPresetKeptOff(custom, false)
        XCTAssertTrue(settings.keepGlobalProtectOff, "A custom preset never writes the built-in preset's intent")
        dependencies.setPresetKeptOff(.globalProtect, false)
        XCTAssertFalse(settings.keepGlobalProtectOff)

        XCTAssertTrue(dependencies.isKeepOffIntentWritable())
        let observed = await dependencies.globalProtectServiceObservation()
        XCTAssertEqual(observed, observation)
    }

    func testAppDependenciesRefuseKeepOffIntentWhileSettingsAreUnreadable() {
        let defaults = makeDefaults()
        defaults.set(Data([0xFF, 0x04]), forKey: "settings")
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let dependencies = ProcessManager.Dependencies.app(
            settings: settings, watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            globalProtectServiceObservation: { nil }
        )
        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        XCTAssertFalse(dependencies.isKeepOffIntentWritable())
    }

    func testInertDependenciesAreExplicitAndNeutral() async {
        let inert = ProcessManager.Dependencies.inert
        XCTAssertTrue(inert.watchedPresets().isEmpty)
        XCTAssertEqual(inert.processListLimit(), SettingsStore.defaultProcessListLimit)
        XCTAssertTrue(inert.keptOffPresets().isEmpty)
        XCTAssertFalse(inert.isPresetKeptOff(.globalProtect))
        XCTAssertTrue(inert.isKeepOffIntentWritable())
        let observed = await inert.globalProtectServiceObservation()
        XCTAssertNil(observed)
    }

    /// The old optional preset list skipped this check when nobody had wired
    /// it. Now the list is always there: a built-in Keep Off whose preset is
    /// not in it is refused before anything is disconnected or recorded.
    func testBuiltInKeepOffIsRefusedWhenThePresetListLacksIt() async {
        let lifecycle = coordinatorLifecycle()
        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler.forbidding("No signal may be sent"),
            lifecycle: lifecycle,
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        var writes = 0
        manager.dependencies.setPresetKeptOff = { _, _ in writes += 1 }

        let result = await manager.keepOff(.globalProtect)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.message, "The built-in GlobalProtect preset was removed. Keep Off was not recorded and no services were disabled.")
        XCTAssertEqual(manager.message, result.message)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(lifecycle.calls.isEmpty, "\(lifecycle.calls)")
    }

    // MARK: - Outcomes

    func testStopOutcomeCarriesStatusMessageReportAndDiagnosticFromOneExit() async {
        let host = CoordinatorTestHost(snapshot: .failure(.commandFailed("ps failed")))
        let lifecycle = coordinatorLifecycle()
        let coordinator = PresetLifecycleCoordinator(lifecycle: lifecycle, now: Date.init)
        let preset = example()

        let outcome = await coordinator.stop(preset, scope: .all, host: host)

        XCTAssertEqual(host.progress, ["Quitting Example and its helpers…"])
        XCTAssertEqual(outcome.result, TaskScopeCommandResult(status: .failed, message: "Could not read the process list; Example was not stopped."))
        XCTAssertEqual(outcome.message, outcome.result.message)
        XCTAssertEqual(outcome.report, .unchanged)
        XCTAssertEqual(outcome.diagnostic?.reason, .inventoryUnavailable)
        XCTAssertEqual(outcome.diagnostic?.action, .close)
        XCTAssertEqual(outcome.diagnostic?.presetID, preset.id)
        XCTAssertTrue(lifecycle.calls.isEmpty)
    }

    func testCancelledStopPutsTheEarlierStatusLineBack() async {
        let host = CoordinatorTestHost(snapshot: .failure(.cancelled))
        host.message = "Earlier status"
        let coordinator = PresetLifecycleCoordinator(lifecycle: coordinatorLifecycle(), now: Date.init)

        let outcome = await coordinator.stop(example(), scope: .app, host: host)

        XCTAssertEqual(outcome.result, TaskScopeCommandResult(status: .rejected, message: "Stop for Example was cancelled."))
        XCTAssertEqual(outcome.message, "Earlier status")
        XCTAssertNil(outcome.diagnostic)
    }

    func testCompletedStopReportsItsRelaunchJobs() async {
        let preset = example()
        let host = CoordinatorTestHost(snapshot: .success(WatchedAppSnapshot(preset: preset, runningNames: [])))
        let lifecycle = coordinatorLifecycle()
        let job = LifecycleJobResult(label: "com.example.agent", state: .changed, detail: "Unloaded and verified.")
        lifecycle.unloadAgentsResult = LifecycleBatchResult(jobs: [job])
        let coordinator = PresetLifecycleCoordinator(lifecycle: lifecycle, now: Date.init)

        let outcome = await coordinator.stop(preset, scope: .all, host: host)

        XCTAssertEqual(outcome.result.status, .completed)
        XCTAssertEqual(outcome.result.message, "No watched app or user helpers were running; launch agents unloaded.")
        XCTAssertEqual(outcome.message, outcome.result.message)
        guard case .replace(let report) = outcome.report else { return XCTFail("Expected a report") }
        XCTAssertEqual(report?.title, "Example Relaunch Jobs")
        XCTAssertEqual(report?.jobs, [job])
        XCTAssertNil(outcome.diagnostic)
        XCTAssertEqual(lifecycle.calls, ["agents.unload", "terminate.scope:all", "settle"])
        XCTAssertEqual(lifecycle.preservedPIDs, [], "A full stop preserves no agent processes")
    }

    /// Background enforcement runs on every poll; the same failure is shown
    /// once until enforcement next succeeds.
    func testBackgroundKeepOffShowsAnIdenticalFailureOnce() async {
        let preset = example()
        let host = CoordinatorTestHost(snapshot: .failure(.commandFailed("ps failed")))
        host.dependencies.isPresetKeptOff = { _ in true }
        let coordinator = PresetLifecycleCoordinator(lifecycle: coordinatorLifecycle(), now: Date.init)

        let first = await coordinator.keepOff(preset, recordIntent: false, confirmedFailureID: nil, host: host)
        XCTAssertEqual(first.result.status, .failed)
        XCTAssertEqual(first.message, first.result.message)
        XCTAssertEqual(first.diagnostic?.backgroundEnforcement, true)
        XCTAssertEqual(first.diagnostic?.reason, .inventoryUnavailable)

        let second = await coordinator.keepOff(preset, recordIntent: false, confirmedFailureID: nil, host: host)
        XCTAssertEqual(second.result, first.result)
        XCTAssertNil(second.message)
        XCTAssertNil(second.diagnostic)
        XCTAssertEqual(second.report, .unchanged)
    }

    func testKeepOffRefusedBeforeItStartsChangesNothing() async {
        let host = CoordinatorTestHost(snapshot: .failure(.commandFailed("unused")))
        host.dependencies.isKeepOffIntentWritable = { false }
        var writes = 0
        host.dependencies.setPresetKeptOff = { _, _ in writes += 1 }
        let lifecycle = coordinatorLifecycle()
        let coordinator = PresetLifecycleCoordinator(lifecycle: lifecycle, now: Date.init)

        let outcome = await coordinator.keepOff(example(), recordIntent: true, confirmedFailureID: nil, host: host)

        XCTAssertEqual(outcome.result.status, .rejected)
        XCTAssertEqual(outcome.message, "Settings are unreadable. Reset settings in Settings → General before changing Keep Off.")
        XCTAssertNil(outcome.diagnostic)
        XCTAssertEqual(outcome.report, .unchanged)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(lifecycle.calls.isEmpty)
        XCTAssertTrue(host.progress.isEmpty)
    }

    func testOpenWithAMissingBundleFailsWithItsReason() async {
        let lifecycle = coordinatorLifecycle()
        lifecycle.appExists = false
        let host = CoordinatorTestHost(snapshot: .failure(.commandFailed("unused")))
        let coordinator = PresetLifecycleCoordinator(lifecycle: lifecycle, now: Date.init)

        let outcome = await coordinator.open(example(), host: host)

        XCTAssertEqual(outcome.result, TaskScopeCommandResult(status: .failed, message: "Could not open Example: app bundle is missing at /Applications/Example.app."))
        XCTAssertEqual(outcome.message, outcome.result.message)
        XCTAssertEqual(outcome.diagnostic?.reason, .appBundleMissing)
        XCTAssertEqual(outcome.diagnostic?.action, .open)
        XCTAssertEqual(lifecycle.calls, ["exists"], "Only the bundle check ran")
    }
}

// MARK: - Fakes

@MainActor
private final class CoordinatorTestHost: PresetLifecycleHost {
    var dependencies = ProcessManager.Dependencies.inert
    var message = "Idle."
    var snapshots: [WatchedAppSnapshot] = []
    var lastInventoryReadWasCancelled = false
    var isMutationActive = false
    private(set) var progress: [String] = []
    private let snapshotResult: Result<WatchedAppSnapshot, ProcessInventoryError>

    init(snapshot: Result<WatchedAppSnapshot, ProcessInventoryError>) {
        snapshotResult = snapshot
    }

    func showProgress(_ message: String) {
        progress.append(message)
        self.message = message
    }

    func currentSnapshot(for preset: WatchedAppPreset) async -> Result<WatchedAppSnapshot, ProcessInventoryError> {
        snapshotResult
    }

    func refreshInventoryAfterMutation() async -> [AppProcess]? { [] }

    func snapshot(for preset: WatchedAppPreset, inventory: [AppProcess]) -> WatchedAppSnapshot {
        WatchedAppSnapshot(preset: preset, runningNames: [])
    }

    func enforceKeepOff(_ preset: WatchedAppPreset) async {
        XCTFail("No enforcement was expected")
    }
}

/// launchd changes are not needed, a preset stop answers in one
/// `terminate.scope` call with no outcomes, the app exists and opens, waits for
/// it succeed, and the VPN disconnects.
private func coordinatorLifecycle() -> FakeLifecycle {
    let lifecycle = FakeLifecycle.allSucceeding()
    lifecycle.terminationOutcome = .noMatchingProcesses
    lifecycle.terminateScope = { _, _ in [] }
    return lifecycle
}
