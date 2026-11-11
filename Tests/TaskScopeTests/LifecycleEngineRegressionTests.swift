import XCTest
@testable import TaskScope

@MainActor
final class LifecycleEngineRegressionTests: XCTestCase {
    func testStopVerifiesCapturedPresetAfterDeletionForEveryScope() async {
        for scope in [PresetStopScope.app, .helpers, .all] {
            let preset = examplePreset
            let store = PresetList([preset])
            var lifecycle = FakeLifecycle()
            lifecycle.onUnload = { await store.replace(with: []) }
            let inventory = Inventory([.success(exampleProcesses)])
            let manager = manager(inventory: inventory, lifecycle: lifecycle)
            manager.dependencies.watchedPresets = { store.presets }

            let result = await stop(manager, preset: preset, scope: scope)

            XCTAssertEqual(result.status, .failed, "A deleted preset must not hide surviving targets")
            XCTAssertEqual(result.message, scope == .helpers ? "User helpers may still run." : "Example may still run.")
            XCTAssertTrue(manager.snapshots.isEmpty, "UI still follows the current store")
        }
    }

    func testStopVerifiesCapturedPresetAfterEditingExecutablePath() async {
        for scope in [PresetStopScope.app, .helpers, .all] {
            let preset = examplePreset
            var edited = preset
            edited.appPath = "/Applications/Replacement.app"
            let store = PresetList([preset])
            let replacement = edited
            var lifecycle = FakeLifecycle()
            lifecycle.onUnload = { await store.replace(with: [replacement]) }
            let manager = manager(inventory: Inventory([.success(exampleProcesses)]), lifecycle: lifecycle)
            manager.dependencies.watchedPresets = { store.presets }

            let result = await stop(manager, preset: preset, scope: scope)

            XCTAssertEqual(result.status, .failed, "An edited preset must not hide surviving targets")
            XCTAssertEqual(manager.snapshots.first?.preset.appPath, edited.appPath)
            XCTAssertFalse(manager.snapshots.first?.hasAny ?? true)
        }
    }

    func testMissingGlobalProtectBundleClearsOverridesWithoutSavedIntent() async {
        let calls = Calls()
        var lifecycle = FakeLifecycle(calls: calls)
        lifecycle.bundleExists = false
        let manager = manager(inventory: Inventory([.success([])]), lifecycle: lifecycle)
        manager.dependencies.isPresetKeptOff = { _ in false }

        let result = await manager.openApp(.globalProtect)

        let recorded = await calls.values
        XCTAssertEqual(recorded, ["enableSystem", "enableUser"])
        XCTAssertEqual(result.status, .failed, "Missing bundle still prevents Open")
        XCTAssertEqual(result.message, "GlobalProtect is allowed to run, but its app bundle is missing at /Applications/GlobalProtect.app; nothing was opened.")
        XCTAssertNil(manager.lifecycleReport, "No changes or failures need a service report")
    }

    func testMissingBundleReportsOverrideFailureWithoutClaimingKeepOffIntent() async {
        var lifecycle = FakeLifecycle()
        lifecycle.bundleExists = false
        lifecycle.systemEnableResult = batch(.failed, detail: "Approval cancelled")
        let manager = manager(inventory: Inventory([.success([])]), lifecycle: lifecycle)
        manager.dependencies.isPresetKeptOff = { _ in false }

        let result = await manager.openApp(.globalProtect)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("Could not allow GlobalProtect to run"))
        XCTAssertTrue(result.message.contains("Approval cancelled"))
        XCTAssertTrue(result.message.contains("app bundle is missing"))
        XCTAssertFalse(result.message.contains("remains requested"))
        XCTAssertNotNil(manager.lifecycleReport)
    }

    func testHealthyGlobalProtectOpenDoesNotClaimRestorationOrShowReport() async {
        let runtime = CommandRuntime(disabledTable: "disabled services = {\n}")
        var lifecycle = FakeLifecycle()
        lifecycle.enableRuntime = runtime.runtime
        lifecycle.ensureResult = batch(.verified)
        lifecycle.systemEnableResult = batch(.verified)
        lifecycle.bootstrapResult = batch(.alreadyLoaded)
        let manager = manager(inventory: Inventory([.success(globalProtectProcesses)]), lifecycle: lifecycle)
        manager.dependencies.isPresetKeptOff = { _ in false }

        let result = await manager.openApp(.globalProtect)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.message, "GlobalProtect is already running.")
        XCTAssertNil(manager.lifecycleReport)
        let calls = await lifecycle.calls.values
        XCTAssertFalse(calls.contains("open"), "GlobalProtect's UI must never be opened over a running one")
    }

    func testOpenReportsActualOverrideRestoration() async {
        let label = WatchedAppPreset.globalProtectInterfaceAgent.label
        let runtime = CommandRuntime(disabledTable: "disabled services = {\n\"\(label)\" => true\n}")
        var lifecycle = FakeLifecycle()
        lifecycle.enableRuntime = runtime.runtime
        let manager = manager(inventory: Inventory([.success(globalProtectProcesses)]), lifecycle: lifecycle)
        manager.dependencies.isPresetKeptOff = { _ in false }

        let result = await manager.openApp(.globalProtect)

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.message, "Required services were restored. GlobalProtect is already running.")
        XCTAssertEqual(manager.lifecycleReport?.jobs.filter { $0.state == .changed }.map(\.label), [label])
    }

    func testEnableUserAgentsDistinguishesDisabledEnabledAndAbsentOverrides() async {
        for (value, state) in [("true", LifecycleJobState.changed), ("false", .verified), ("absent", .verified)] {
            let entry = value == "absent" ? "" : "\"example.agent\" => \(value)\n"
            let harness = CommandRuntime(disabledTable: "disabled services = {\n\(entry)}")
            let result = await ProcessLifecycleController.enableUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
            XCTAssertEqual(result.jobs.first?.state, state)
            XCTAssertEqual(result.didChangeState, value == "true")
            XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("enable") })
            XCTAssertFalse(harness.commands.contains { $0.isLaunchctl("bootstrap", "kickstart") })
        }
    }

    func testUnknownPriorOverrideDoesNotClaimAChange() async {
        let harness = CommandRuntime(disabledTable: "unrecognized output")
        let result = await ProcessLifecycleController.enableUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
        XCTAssertTrue(result.succeeded, "Explicit enable can recover even when the prior state is unreadable")
        XCTAssertFalse(result.didChangeState, "An unreadable prior state cannot prove a change")
        XCTAssertTrue(result.jobs.first?.detail.contains("previous disable state could not be read") == true)
    }

    func testNonzeroBootoutSucceedsOnceFinalInspectionConfirmsAbsence() async {
        for keepOff in [false, true] {
            for delayedReads in [0, 2] {
                let harness = CommandRuntime(bootoutFailure: true, delayedReads: delayedReads)
                let result = keepOff
                    ? await ProcessLifecycleController.disableUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
                    : await ProcessLifecycleController.unloadUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
                XCTAssertTrue(result.succeeded, result.failureSummary ?? "")
                XCTAssertEqual(result.jobs.first?.state, .changed)
                XCTAssertEqual(harness.commands.filter { $0.isLaunchctl("bootout") }.count, 1)
                XCTAssertEqual(harness.sleepDurations.filter { $0 == 500_000_000 }.count, delayedReads)
            }
        }
    }

    func testNonzeroBootoutWaitIsBoundedAndPreservesFailureWhenStillLoaded() async {
        for keepOff in [false, true] {
            let harness = CommandRuntime(bootoutFailure: true, delayedReads: 1000)
            let result = keepOff
                ? await ProcessLifecycleController.disableUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
                : await ProcessLifecycleController.unloadUserLaunchAgents(for: examplePreset, runtime: harness.runtime)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(harness.sleepDurations.filter { $0 == 500_000_000 }.count, 60)
            XCTAssertTrue(result.failureSummary?.contains("Operation now in progress") == true)
        }
    }

    func testQuitAppJobFailureDoesNotClaimAnUnobservedQuit() async {
        for finalRead: Result<[AppProcess], ProcessInventoryError> in [
            .success(exampleProcesses), .failure(.commandFailed("ps unavailable")), .success([])
        ] {
            var lifecycle = FakeLifecycle()
            lifecycle.unloadResult = batch(.failed, detail: "bootout denied")
            let manager = manager(inventory: Inventory([.success(exampleProcesses), finalRead]), lifecycle: lifecycle)
            manager.dependencies.watchedPresets = { [self.examplePreset] }
            let result = await manager.quitMainApp(examplePreset)
            XCTAssertEqual(result.status, .failed)
            let prefix: String
            switch finalRead {
            case .success(let rows) where rows.isEmpty: prefix = "Example quit, but relaunch jobs failed:"
            default: prefix = "Example may still run; relaunch jobs failed:"
            }
            XCTAssertTrue(result.message.hasPrefix(prefix), result.message)
        }
    }

    func testQuitAppJobFailureWithNoRunningAppDoesNotClaimItQuit() async {
        var lifecycle = FakeLifecycle()
        lifecycle.unloadResult = batch(.failed, detail: "bootout denied")
        let manager = manager(inventory: Inventory([.success([])]), lifecycle: lifecycle)
        let result = await manager.quitMainApp(examplePreset)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.hasPrefix("No Example app found, but relaunch jobs failed:"), result.message)
    }

    func testPartialStopInventoryFailureDoesNotClaimNothingStopped() async {
        for scope in [PresetStopScope.helpers, .all] {
            var lifecycle = FakeLifecycle()
            lifecycle.helperOutcome = .inventoryUnavailable
            let manager = manager(inventory: Inventory([.success(exampleProcesses), .success([])]), lifecycle: lifecycle)
            let result = await stop(manager, preset: examplePreset, scope: scope)
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.message, "Could not read the process list for every stop target; the stop may be incomplete.")
            let calls = await lifecycle.calls.values
            XCTAssertTrue(calls.contains("terminateHelper"))
            if scope == .all { XCTAssertTrue(calls.contains("terminateMain")) }
        }
    }

    private var examplePreset: WatchedAppPreset {
        WatchedAppPreset(displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Helper"],
                         protectedProcessNames: [], appPath: "/Applications/Example.app",
                         userLaunchAgentJobs: [UserLaunchAgentJob(label: "example.agent", plistPath: "/agents/example.plist")])
    }

    private var exampleProcesses: [AppProcess] {
        [process(701, path: "/Applications/Example.app/Contents/MacOS/Example"),
         process(702, path: "/Applications/Example.app/Contents/MacOS/Helper")]
    }

    private var globalProtectProcesses: [AppProcess] {
        [process(703, path: "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"),
         process(704, path: "/Applications/GlobalProtect.app/Contents/MacOS/PanGPS")]
    }

    private func process(_ pid: Int32, path: String) -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: path,
                   executablePath: path, elapsedTime: "00:01", startTime: "fixture-start",
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func batch(_ state: LifecycleJobState, detail: String = "fixture") -> LifecycleBatchResult {
        LifecycleBatchResult(jobs: [LifecycleJobResult(label: "example.job", state: state, detail: detail)])
    }

    private func manager(inventory: Inventory, lifecycle: FakeLifecycle) -> ProcessManager {
        let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory,
                                     processSignaler: NoopSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, dependencies: .inert)
        manager.enableNotifications = false
        return manager
    }

    private func stop(_ manager: ProcessManager, preset: WatchedAppPreset, scope: PresetStopScope) async -> TaskScopeCommandResult {
        switch scope {
        case .app: await manager.quitMainApp(preset)
        case .helpers: await manager.quitHelpers(preset)
        case .all: await manager.quitAllKillable(preset)
        }
    }
}

@MainActor
private final class PresetList {
    var presets: [WatchedAppPreset]
    init(_ presets: [WatchedAppPreset]) { self.presets = presets }
    func replace(with presets: [WatchedAppPreset]) { self.presets = presets }
}

private actor Calls {
    var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private struct FakeLifecycle: ProcessLifecycleServicing {
    var calls = Calls()
    var bundleExists = true
    var onUnload: @Sendable () async -> Void = {}
    var unloadResult = LifecycleBatchResult.notNeeded
    var ensureResult = LifecycleBatchResult.notNeeded
    var bootstrapResult = LifecycleBatchResult.notNeeded
    var systemEnableResult = LifecycleBatchResult.notNeeded
    var enableRuntime: ProcessLifecycleRuntime?
    var helperOutcome = ProcessTerminationOutcome.signalled

    func appBundleExists(at path: String) -> Bool { bundleExists }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await calls.record("terminateMain")
        return .signalled
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await calls.record("terminateHelper")
        return helperOutcome
    }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        await calls.record("open")
        return .opened
    }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await onUnload()
        return unloadResult
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { bootstrapResult }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { ensureResult }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await calls.record("enableSystem")
        return systemEnableResult
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await calls.record("enableUser")
        guard let enableRuntime else { return .notNeeded }
        return await ProcessLifecycleController.enableUserLaunchAgents(for: preset, runtime: enableRuntime)
    }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}

private actor Inventory: ProcessInventoryProviding {
    var results: [Result<[AppProcess], ProcessInventoryError>]
    init(_ results: [Result<[AppProcess], ProcessInventoryError>]) { self.results = results }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if results.count > 1 { return results.removeFirst() }
        return results[0]
    }
}

private final class NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private final class CommandRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let disabledTable: String
    private let bootoutFailure: Bool
    private var delayedReads: Int
    private var bootoutRequested = false
    private var recordedCommands: [ExternalCommand] = []
    private var recordedSleeps: [UInt64] = []

    init(disabledTable: String = "disabled services = {\n}", bootoutFailure: Bool = false, delayedReads: Int = 0) {
        self.disabledTable = disabledTable
        self.bootoutFailure = bootoutFailure
        self.delayedReads = delayedReads
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: getuid(), fileExists: { _ in true }, launchAgentLabel: { _ in "example.agent" },
            runCommand: { [self] command, _ in run(command) }, loadProcessInventory: { .success([]) },
            executablePathForPID: { _ in nil }, sendSignal: { _, _ in false }, isProcessAlive: { _ in false },
            sleep: { [self] duration in lock.withLock { recordedSleeps.append(duration) } }, systemUptime: { 0 },
            isAppBundle: { _ in false }
        )
    }

    var commands: [ExternalCommand] { lock.withLock { recordedCommands } }
    var sleepDurations: [UInt64] { lock.withLock { recordedSleeps } }

    private func run(_ command: ExternalCommand) -> ShellCommandResult {
        lock.withLock {
            recordedCommands.append(command)
            var output = ""
            var error = ""
            var code: Int32 = 0
            if command.isLaunchctl("print-disabled") {
                output = disabledTable
            } else if command.isLaunchctl("bootout") {
                bootoutRequested = true
                if bootoutFailure { error = "Operation now in progress"; code = 36 }
            } else if command.isLaunchctl("print") {
                if bootoutRequested && delayedReads == 0 {
                    error = launchctlNotFoundMessage(command: command); code = 113
                } else {
                    output = launchctlPrintOutput(pid: 42)
                    if bootoutRequested { delayedReads -= 1 }
                }
            } else if !command.isLaunchctl("enable", "disable") {
                error = "Unexpected fake command"; code = 1
            }
            return ShellCommandResult(command: command, stdout: output, stderr: error, exitCode: code)
        }
    }
}
