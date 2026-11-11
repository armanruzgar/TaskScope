import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the composition root and runtime
// (TaskScopeRuntime), the command coordinator's Open and Stop routing, and the
// Stop Watched App intent. Lifecycle, inventory and signaler are fakes: nothing
// is signalled and no launchctl, Accessibility or notification call is made.

// MARK: - Coordinator routing (T05-2, T05-1)

@MainActor
final class Batch02CoordinatorTests: XCTestCase {
    private func examplePreset() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
    }

    private func exampleRow(pid: Int32) -> AppProcess {
        AppProcess.fixture(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: 0, netOutKB: 0, diskReadBytes: 0, diskWriteBytes: 0
        )
    }

    private func manager(
        inventory: any ProcessInventoryProviding, lifecycle: FakeLifecycle
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory, processSignaler: FakeSignaler(),
            lifecycle: lifecycle, settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    /// T05-2: Open opens the app and never takes a stop path.
    func testOpenEntityCommandOpensTheAppAndNeverStopsIt() async {
        let lifecycle = FakeLifecycle.allSucceeding()
        let inventory = ScriptedInventory([.success([]), .success([]), .success([exampleRow(pid: 42)])], repeatsLast: true)
        let preset = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: inventory, lifecycle: lifecycle), presets: { [preset] }
        )

        let result = await coordinator.perform(.openPresetEntity(
            WatchedPresetCommandTarget(id: preset.id, displayName: preset.displayName)
        ))

        XCTAssertEqual(result.status, .completed, result.message)
        XCTAssertEqual(result.message, "Opened Example.")
        XCTAssertTrue(lifecycle.calls.contains("open"), "\(lifecycle.calls)")
        XCTAssertFalse(lifecycle.calls.contains { $0.hasPrefix("terminate") || $0 == "agents.unload" },
                       "Open must never stop anything: \(lifecycle.calls)")
    }

    /// T05-2: Open resolves the preset by its stable identifier only; a preset
    /// that merely has the same display name is not opened.
    func testOpenEntityCommandRejectsAReplacementPresetWithTheSameDisplayName() async {
        let lifecycle = FakeLifecycle.allSucceeding()
        let replacement = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: ScriptedInventory(processes: []), lifecycle: lifecycle),
            presets: { [replacement] }
        )

        let result = await coordinator.perform(.openPresetEntity(
            WatchedPresetCommandTarget(id: UUID(), displayName: "Example")
        ))

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("Example"), result.message)
        XCTAssertEqual(lifecycle.calls, [], "No lifecycle work for an unknown preset")
    }

    /// T05-2 control: Stop stops and never opens.
    func testStopEntityCommandStopsTheAppAndNeverOpensIt() async {
        let lifecycle = FakeLifecycle.allSucceeding()
        let inventory = ScriptedInventory([.success([exampleRow(pid: 42)]), .success([])], repeatsLast: true)
        let preset = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: inventory, lifecycle: lifecycle), presets: { [preset] }
        )

        _ = await coordinator.perform(.stopPresetEntity(
            WatchedPresetCommandTarget(id: preset.id, displayName: preset.displayName)
        ))

        XCTAssertTrue(lifecycle.calls.contains("terminate:Example"), "\(lifecycle.calls)")
        XCTAssertFalse(lifecycle.calls.contains("open"), "\(lifecycle.calls)")
    }

    /// T05-1: Shortcuts Stop of the built-in GlobalProtect preset, through the
    /// app's own wiring, stays in user-process scope: no VPN disconnect, no Keep
    /// Off intent, no persistent agent disable, no system daemon, and only the
    /// interface agent is unloaded.
    func testShortcutsStopOfGlobalProtectStaysInUserProcessScope() async throws {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)

        _ = try await intent.executeStop(
            bus: rig.bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { _ in }

        XCTAssertFalse(rig.lifecycle.calls.contains("vpn.disconnect"), "\(rig.lifecycle.calls)")
        XCTAssertFalse(rig.lifecycle.calls.contains("agents.disable"))
        XCTAssertFalse(rig.lifecycle.calls.contains { $0.hasPrefix("daemon.disable") })
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff, "Shortcuts Stop must not record Keep Off")
        let unloaded = rig.lifecycle.presetsByCall["agents.unload"]?.first
        XCTAssertEqual(unloaded?.lifecycleUserLaunchAgentJobs.map(\.label), ["com.paloaltonetworks.gp.pangpa"])
        XCTAssertEqual(unloaded?.lifecycleSystemLaunchDaemonJobs.count, 0)
    }

    /// T05-1: a failed Shortcuts Stop is recorded as Close in diagnostics.
    func testShortcutsStopFailureIsRecordedAsClose() async throws {
        let rig = Batch02RuntimeRig(
            inventory: ScriptedInventory(failing: .commandFailed("ps unavailable"))
        )
        defer { rig.tearDown() }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)

        let result = try await intent.executeStop(
            bus: rig.bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { _ in }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(rig.manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).map(\.action),
                       [.close])
        XCTAssertEqual(rig.lifecycle.calls, [])
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff)
    }
}
