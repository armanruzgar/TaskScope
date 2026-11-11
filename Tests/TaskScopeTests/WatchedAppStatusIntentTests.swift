import Darwin
import XCTest
@testable import TaskScope

/// L11-20: Get Watched App Status is a read-only action that returns the
/// verified status of one watched app; Open and Stop return the same value.
@MainActor
final class WatchedAppStatusIntentTests: XCTestCase {
    private let preset = WatchedAppPreset(
        displayName: "Example",
        mainProcessName: "Example",
        helperProcessNames: ["Example Helper", "Example Agent"],
        protectedProcessNames: [],
        appPath: "/Applications/Example.app"
    )

    // MARK: Summary

    func testSummaryReportsTheVerifiedSnapshotAndNothingWhileUnknown() {
        let running = WatchedAppSnapshot(preset: preset, runningNames: ["Example", "Example Helper"])
        let current = WatchedAppStatusSummary(
            preset: preset, snapshots: [running], availability: .current, isKeptOff: false
        )
        XCTAssertEqual(current, WatchedAppStatusSummary(
            presetName: "Example", availability: .current, isMainAppRunning: true,
            runningHelperCount: 1, isKeptOff: false
        ))
        XCTAssertEqual(current.sentence, "Example: main app running, 1 helper running.")

        let quiet = WatchedAppSnapshot(preset: preset, runningNames: [])
        let stale = WatchedAppStatusSummary(preset: preset, snapshots: [quiet], availability: .stale, isKeptOff: true)
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertEqual(stale.isMainAppRunning, false)
        XCTAssertEqual(stale.runningHelperCount, 0)
        XCTAssertEqual(
            stale.sentence,
            "Example, as last observed before a failed refresh: main app not running, no helpers running. Keep Off is on."
        )

        // A preset no read has covered is unknown, whatever the global state says.
        for availability in [WatchedStatusAvailability.current, .stale, .unknown] {
            let unknown = WatchedAppStatusSummary(
                preset: preset, snapshots: [], availability: availability, isKeptOff: false
            )
            XCTAssertEqual(unknown.availability, .unknown)
            XCTAssertNil(unknown.isMainAppRunning)
            XCTAssertNil(unknown.runningHelperCount)
            XCTAssertEqual(unknown.sentence, "TaskScope could not verify the status of Example.")
        }
        let twoHelpers = WatchedAppSnapshot(preset: preset, runningNames: ["Example Helper", "Example Agent"])
        XCTAssertEqual(
            WatchedAppStatusSummary(preset: preset, snapshots: [twoHelpers], availability: .current, isKeptOff: false)
                .sentence,
            "Example: main app not running, 2 helpers running."
        )
    }

    // MARK: Get Watched App Status command

    func testStatusRefreshesAndReportsTheVerifiedSnapshotWithoutChangingTheStatusLine() async throws {
        let inventory = StatusScriptedInventory([.success([main, helper])])
        let (manager, coordinator) = makeCoordinator(inventory: inventory)

        let result = await coordinator.perform(.statusPresetEntity(target))

        XCTAssertEqual(result.status, .completed, result.message)
        let status = try XCTUnwrap(result.watchedStatus)
        XCTAssertEqual(status, WatchedAppStatusSummary(
            presetName: "Example", availability: .current, isMainAppRunning: true,
            runningHelperCount: 1, isKeptOff: false
        ))
        XCTAssertEqual(result.message, status.sentence)
        XCTAssertEqual(inventory.loads, 1, "one fresh read")
        XCTAssertEqual(manager.message, "Idle.", "a status check leaves the status line alone")
        XCTAssertEqual(manager.snapshots.first?.isMainRunning, true, "the read updates the shown status too")
        XCTAssertNil(manager.lifecycleReport)
    }

    func testStatusReportsThePresetsKeepOffIntent() async throws {
        let (manager, coordinator) = makeCoordinator(inventory: StatusScriptedInventory([.success([])]))
        manager.dependencies.isPresetKeptOff = { [id = preset.id] in $0.id == id }

        let result = await coordinator.perform(.statusPresetEntity(target))
        let status = try XCTUnwrap(result.watchedStatus)

        XCTAssertTrue(status.isKeptOff)
        XCTAssertEqual(status.isMainAppRunning, false)
        XCTAssertEqual(status.sentence, "Example: main app not running, no helpers running. Keep Off is on.")
    }

    func testStatusAfterAFailedReadIsStaleThenUnknownWithoutAnEarlierRead() async throws {
        let inventory = StatusScriptedInventory([.success([main]), .failure(.commandFailed("ps timed out"))])
        let (_, coordinator) = makeCoordinator(inventory: inventory)

        let first = await coordinator.perform(.statusPresetEntity(target))
        XCTAssertEqual(first.watchedStatus?.availability, .current)
        let second = await coordinator.perform(.statusPresetEntity(target))
        XCTAssertEqual(second.status, .completed, "the value itself says the status is stale")
        XCTAssertEqual(second.watchedStatus, WatchedAppStatusSummary(
            presetName: "Example", availability: .stale, isMainAppRunning: true,
            runningHelperCount: 0, isKeptOff: false
        ))

        let (_, cold) = makeCoordinator(inventory: StatusScriptedInventory([.failure(.commandFailed("ps timed out"))]))
        let unknown = await cold.perform(.statusPresetEntity(target))
        XCTAssertEqual(unknown.status, .completed)
        XCTAssertEqual(unknown.watchedStatus?.availability, .unknown)
        XCTAssertNil(unknown.watchedStatus?.isMainAppRunning)
        XCTAssertEqual(unknown.message, "TaskScope could not verify the status of Example.")
    }

    func testStatusRejectsAMissingPresetAndStartupVerification() async {
        let inventory = StatusScriptedInventory([.success([main])])
        let manager = makeManager(inventory: inventory)
        let missing = await AppCommandCoordinator(processManager: manager, presets: { [] })
            .perform(.statusPresetEntity(target))
        XCTAssertEqual(missing.status, .rejected)
        XCTAssertNil(missing.watchedStatus)

        let verifying = await AppCommandCoordinator(
            processManager: manager, presets: { [self.preset] }, allowsCommands: { false }
        ).perform(.statusPresetEntity(target))
        XCTAssertEqual(verifying, AppCommandCoordinator.startupVerificationRejection)
        XCTAssertEqual(inventory.loads, 0, "a rejected status check reads nothing")
    }

    // MARK: Open and Stop values

    func testOpenAndStopReturnTheStatusTheirFinalReadVerified() async throws {
        // Open: not running before, not started by its agents, running after.
        let opening = StatusScriptedInventory([.success([]), .success([]), .success([main, helper])])
        let (_, openCoordinator) = makeCoordinator(inventory: opening)
        let opened = await openCoordinator.perform(.openPresetEntity(target))
        XCTAssertEqual(opened.status, .completed, opened.message)
        XCTAssertEqual(opened.watchedStatus?.isMainAppRunning, true)
        XCTAssertEqual(opened.watchedStatus?.runningHelperCount, 1)
        XCTAssertEqual(opened.watchedStatus?.availability, .current)

        // Stop: running before, gone after.
        let stopping = StatusScriptedInventory([.success([main, helper]), .success([])])
        let (_, stopCoordinator) = makeCoordinator(inventory: stopping)
        let stopped = await stopCoordinator.perform(.stopPresetEntity(target))
        XCTAssertEqual(stopped.status, .completed, stopped.message)
        XCTAssertEqual(stopped.watchedStatus?.isMainAppRunning, false)
        XCTAssertEqual(stopped.watchedStatus?.runningHelperCount, 0)

        // A failed Open carries no status: Shortcuts reports the failure instead.
        let (_, failing) = makeCoordinator(inventory: StatusScriptedInventory([.success([])]), bundleExists: false)
        let failed = await failing.perform(.openPresetEntity(target))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertNil(failed.watchedStatus)
    }

    // MARK: Intents

    @available(macOS 13.0, *)
    func testStatusIntentSubmitsTheReadOnlyCommandAndReturnsItsValue() async throws {
        let bus = AppCommandBus()
        var events: [String] = []
        var commands: [TaskScopeCommand] = []
        bus.onIntentExecution = { events.append("intent") }
        let summary = WatchedAppStatusSummary(
            presetName: "Example", availability: .current, isMainAppRunning: true,
            runningHelperCount: 2, isKeptOff: true
        )
        bus.install { command in
            commands.append(command)
            events.append("status")
            return TaskScopeCommandResult(status: .completed, message: summary.sentence, watchedStatus: summary)
        }
        let intent = GetWatchedAppStatusIntent()
        intent.app = WatchedPresetEntity(id: preset.id, displayName: "Example")

        let result = try await intent.executeStatus(bus: bus)
        let status = try TaskScopeIntentDialog.statusResult(
            for: result, action: "get the status of Example", presetName: "Example"
        )

        XCTAssertEqual(events, ["intent", "status"])
        XCTAssertEqual(commands, [.statusPresetEntity(intent.app.commandTarget)])
        XCTAssertEqual(status.message, summary.sentence)
        XCTAssertEqual(status.value.watchedApp, "Example")
        XCTAssertEqual(status.value.availability, .current)
        XCTAssertEqual(status.value.isMainAppRunning, true)
        XCTAssertEqual(status.value.runningHelperCount, 2)
        XCTAssertTrue(status.value.isKeptOff)
        XCTAssertFalse(GetWatchedAppStatusIntent.openAppWhenRun)
    }

    @available(macOS 13.0, *)
    func testStatusValuesMapEveryAvailabilityAndFailuresStillThrow() throws {
        XCTAssertEqual(WatchedStatusAvailabilityAppEnum(.current), .current)
        XCTAssertEqual(WatchedStatusAvailabilityAppEnum(.stale), .stale)
        XCTAssertEqual(WatchedStatusAvailabilityAppEnum(.unknown), .unknown)
        XCTAssertEqual(Set(WatchedStatusAvailabilityAppEnum.caseDisplayRepresentations.keys), [.current, .stale, .unknown])

        let unknown = WatchedAppStatusEntity(WatchedAppStatusSummary(
            presetName: "Example", availability: .unknown, isMainAppRunning: nil,
            runningHelperCount: nil, isKeptOff: false
        ))
        XCTAssertNil(unknown.isMainAppRunning)
        XCTAssertNil(unknown.runningHelperCount)
        XCTAssertEqual(unknown.availability, .unknown)

        for result in [
            TaskScopeCommandResult(status: .rejected, message: "No watched-app preset matches “Example”."),
            TaskScopeCommandResult(status: .failed, message: "ps timed out")
        ] {
            XCTAssertThrowsError(
                try TaskScopeIntentDialog.statusResult(for: result, action: "open Example", presetName: "Example")
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("open Example"), error.localizedDescription)
            }
        }
        // A completed action without a status value still completed; its value
        // claims nothing about the processes.
        let bare = try TaskScopeIntentDialog.statusResult(
            for: TaskScopeCommandResult(status: .completed, message: "Opened Example."),
            action: "open Example", presetName: "Example"
        )
        XCTAssertEqual(bare.message, "Opened Example.")
        XCTAssertEqual(bare.value.watchedApp, "Example")
        XCTAssertEqual(bare.value.availability, .unknown)
        XCTAssertNil(bare.value.isMainAppRunning)
        XCTAssertNil(bare.value.runningHelperCount)
    }

    // MARK: Fixtures

    private var target: WatchedPresetCommandTarget {
        WatchedPresetCommandTarget(id: preset.id, displayName: preset.displayName)
    }

    private var main: AppProcess {
        process(pid: 501, path: "/Applications/Example.app/Contents/MacOS/Example")
    }

    private var helper: AppProcess {
        process(pid: 502, path: "/Applications/Example.app/Contents/Helpers/Example Helper")
    }

    private func process(pid: Int32, path: String) -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: path,
            executablePath: path, elapsedTime: "00:01", netInKB: nil, netOutKB: nil,
            diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    private func makeManager(inventory: StatusScriptedInventory, bundleExists: Bool = true) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: StatusNoopSignaler(),
            lifecycle: StatusNoopLifecycle(bundleExists: bundleExists),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [preset] in [preset] }
        return manager
    }

    private func makeCoordinator(
        inventory: StatusScriptedInventory, bundleExists: Bool = true
    ) -> (ProcessManager, AppCommandCoordinator) {
        let manager = makeManager(inventory: inventory, bundleExists: bundleExists)
        return (manager, AppCommandCoordinator(processManager: manager, presets: { [preset] in [preset] }))
    }
}

/// Returns its results in order and then repeats the last one.
private final class StatusScriptedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private var loadCount = 0

    init(_ results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    var loads: Int { lock.withLock { loadCount } }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            loadCount += 1
            return results.count == 1 ? results[0] : results.removeFirst()
        }
    }
}

private struct StatusNoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}

/// Lifecycle steps that need nothing and change nothing: no signal, launchd
/// or open call leaves the test.
private struct StatusNoopLifecycle: ProcessLifecycleServicing {
    var bundleExists = true
    func appBundleExists(at path: String) -> Bool { bundleExists }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .opened }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { .notNeeded }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { true }
}
