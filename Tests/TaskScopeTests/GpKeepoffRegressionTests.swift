import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class GpKeepoffRegressionTests: XCTestCase {
    func testRecoveryCardDisablesEveryIntentWriterAndExplainsWhy() throws {
        let card = makeCard(enabled: false, recovery: {})
        // The saved intent is unreadable, so recovery shows Keep Off as unknown
        // and offers no switch to change it (audit A11-2).
        XCTAssertThrowsError(try card.inspect().find(ViewType.Toggle.self))
        XCTAssertNoThrow(try card.inspect().find(text: "Keep GlobalProtect Off: Unknown"))
        XCTAssertFalse(try makeCard(enabled: true).inspect().find(ViewType.Toggle.self).isDisabled())
        XCTAssertTrue(try card.inspect().find(button: "Quit All…").isDisabled())
        XCTAssertTrue(try card.inspect().find(button: "Apply Keep Off…").isDisabled())
        XCTAssertTrue(try card.inspect().find(button: "Stop Services Anyway…").isDisabled())
        XCTAssertFalse(try card.inspect().find(button: "Quit App…").isDisabled())
        XCTAssertFalse(try card.inspect().find(button: "Quit Helpers…").isDisabled())
        XCTAssertNoThrow(try card.inspect().find(text: "Settings are unreadable. Reset settings in Settings → General before changing Keep Off."))
    }

    func testRecoveryManagerRejectsQuitAllAndKeepOffBeforeDisconnectOrIntent() async {
        for quitAll in [true, false] {
            let lifecycle = KeepOffLifecycle()
            let manager = makeManager(lifecycle: lifecycle)
            manager.isKeepOffIntentWritableProvider = { false }
            var writes = 0
            manager.setPresetKeptOffHandler = { _, _ in writes += 1 }
            let result = quitAll ? await manager.quitAll(.globalProtect) : await manager.keepOff(.globalProtect)
            XCTAssertEqual(result.status, .rejected)
            XCTAssertTrue(result.message.contains("Reset settings"))
            XCTAssertEqual(writes, 0)
            let calls = await lifecycle.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testSettingsRecoveryIsRecheckedAfterDisconnect() async {
        let lifecycle = KeepOffLifecycle()
        let manager = makeManager(lifecycle: lifecycle)
        await lifecycle.setOnDisconnect { manager.isKeepOffIntentWritableProvider = { false } }
        var writes = 0
        manager.setPresetKeptOffHandler = { _, _ in writes += 1 }
        let result = await manager.quitAll(.globalProtect)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(writes, 0)
        let calls = await lifecycle.calls
        XCTAssertEqual(calls, ["disconnect"])
    }

    func testRecoveryManagerRejectsConfirmedServiceStop() async throws {
        let lifecycle = KeepOffLifecycle(disconnectResult: .failed("Disconnect failed"))
        let manager = makeManager(lifecycle: lifecycle)
        _ = await manager.keepOff(.globalProtect)
        let failure = try XCTUnwrap(manager.globalProtectDisconnectFailureID)
        manager.isKeepOffIntentWritableProvider = { false }
        var writes = 0
        manager.setPresetKeptOffHandler = { _, _ in writes += 1 }
        let result = await manager.stopGlobalProtectAfterFailedDisconnect(failureID: failure)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(writes, 0)
        let calls = await lifecycle.calls
        XCTAssertEqual(calls, ["disconnect"])
    }

    func testPresetRemovedDuringDisconnectRejectsBeforeIntentAndDisable() async {
        let lifecycle = KeepOffLifecycle()
        let manager = makeManager(lifecycle: lifecycle)
        var presets: [WatchedAppPreset] = [.globalProtect]
        manager.watchedAppsProvider = { presets }
        await lifecycle.setOnDisconnect {
            XCTAssertTrue(manager.isGlobalProtectKeepOffPending)
            XCTAssertNotNil(SettingsView.presetDeletionRefusal(
                for: .globalProtect, keepGlobalProtectOff: false,
                isGlobalProtectKeepOffPending: manager.isGlobalProtectKeepOffPending
            ))
            presets = []
        }
        var writes = 0
        manager.setPresetKeptOffHandler = { _, _ in writes += 1 }
        let result = await manager.quitAll(.globalProtect)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("removed"))
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(manager.isGlobalProtectKeepOffPending)
        let calls = await lifecycle.calls
        XCTAssertEqual(calls, ["disconnect"])
    }

    func testDeletedPresetRejectsConfirmedRecoveryAndStaleQuitAll() async throws {
        let lifecycle = KeepOffLifecycle(disconnectResult: .failed("Disconnect failed"))
        let manager = makeManager(lifecycle: lifecycle)
        _ = await manager.keepOff(.globalProtect)
        let failure = try XCTUnwrap(manager.globalProtectDisconnectFailureID)
        manager.watchedAppsProvider = { [] }
        var writes = 0
        manager.setPresetKeptOffHandler = { _, _ in writes += 1 }
        let recovered = await manager.stopGlobalProtectAfterFailedDisconnect(failureID: failure)
        XCTAssertEqual(recovered.status, .rejected)
        let stale = await manager.quitAll(.globalProtect)
        XCTAssertEqual(stale.status, .rejected)
        XCTAssertEqual(writes, 0)
        let calls = await lifecycle.calls
        XCTAssertEqual(calls, ["disconnect"])
    }

    func testPendingFlagCoversQueuedActionsUntilAllRequestsFinish() async {
        let pause = KeepOffPause()
        let lifecycle = KeepOffLifecycle()
        await lifecycle.setOnDisconnect { await pause.block() }
        let manager = makeManager(lifecycle: lifecycle)
        let first = Task { await manager.keepOff(.globalProtect) }
        await pause.waitForEntry()
        XCTAssertTrue(manager.isGlobalProtectKeepOffPending)
        let second = Task { await manager.quitAll(.globalProtect) }
        for _ in 0..<1000 {
            if manager.operationState == .queued { break }
            await Task.yield()
        }
        XCTAssertEqual(manager.operationState, .queued)
        XCTAssertTrue(manager.isGlobalProtectKeepOffPending)
        second.cancel()
        _ = await second.value
        XCTAssertTrue(manager.isGlobalProtectKeepOffPending, "The first request still owns the pending state")
        await pause.release()
        _ = await first.value
        XCTAssertFalse(manager.isGlobalProtectKeepOffPending)
    }

    func testKeepOffVerifiesCapturedPresetAfterStoreDefinitionChanges() async {
        for removed in [true, false] {
            let preset = WatchedAppPreset(displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
                                         protectedProcessNames: [], appPath: "/Applications/Example.app")
            let lifecycle = KeepOffLifecycle()
            let manager = makeManager(lifecycle: lifecycle, processes: [process(name: "Example", path: "/Applications/Example.app/Contents/MacOS/Example")])
            var presets = [preset]
            manager.watchedAppsProvider = { presets }
            await lifecycle.setOnDisable {
                if removed { presets = [] } else { presets[0].mainProcessName = "Renamed" }
            }
            let result = await manager.keepOff(preset)
            XCTAssertEqual(result.status, .failed, "The captured Example process still runs")
        }
    }

    func testPreservedPanGPSDoesNotTriggerOrRepeatBackgroundFailures() async {
        let lifecycle = KeepOffLifecycle(systemResult: LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "com.paloaltonetworks.gp.pangpsd", state: .failed, detail: "System state unknown")
        ]))
        let manager = makeManager(lifecycle: lifecycle, processes: [process()])
        manager.keptOffPresetsProvider = { [.globalProtect] }
        manager.isPresetKeptOffProvider = { _ in true }
        manager.setMessage("Previous action")
        for _ in 0..<3 { await manager.enforceKeptOffPresets() }
        XCTAssertEqual(manager.message, "Previous action")
        XCTAssertNil(manager.lifecycleReport)
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).isEmpty)
        var calls = await lifecycle.calls
        XCTAssertTrue(calls.isEmpty)
        await manager.enforceKeptOffPresets(force: true)
        let reportID = manager.lifecycleReport?.id
        let message = manager.message
        for _ in 0..<3 { await manager.enforceKeptOffPresets() }
        XCTAssertEqual(manager.lifecycleReport?.id, reportID)
        XCTAssertEqual(manager.message, message)
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count, 1)
        calls = await lifecycle.calls
        XCTAssertEqual(calls.filter { $0 == "disable:true" }.count, 1)
        XCTAssertFalse(calls.contains("system:true"))
        XCTAssertFalse(calls.contains("disconnect"))
    }

    func testBackgroundFinalVerdictAcceptsThePreservedSessionService() async {
        let manager = makeManager(lifecycle: KeepOffLifecycle(), processes: [process()])
        manager.isPresetKeptOffProvider = { _ in true }
        manager.globalProtectServiceObservationProvider = { .init(session: .running, system: .absent) }
        let result = await manager.keepOff(.globalProtect, recordIntent: false)
        XCTAssertEqual(result.status, .completed)
        XCTAssertTrue(result.message.contains("preserved"))
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).isEmpty)
    }

    func testUnchangedBackgroundFailureDoesNotReplaceMessageOrRepublishReport() async {
        let lifecycle = KeepOffLifecycle(systemResult: LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "com.paloaltonetworks.gp.pangpsd", state: .failed, detail: "Preserved system service")
        ]))
        let manager = makeManager(lifecycle: lifecycle, processes: [process(
            name: "GlobalProtect", path: GlobalProtectAccessibilityDisconnect.executable
        )])
        manager.keptOffPresetsProvider = { [.globalProtect] }
        manager.isPresetKeptOffProvider = { _ in true }
        await manager.enforceKeptOffPresets()
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count, 1)
        manager.dismissLifecycleReport()
        manager.setMessage("Another action's result")
        await manager.enforceKeptOffPresets()
        XCTAssertEqual(manager.message, "Another action's result")
        XCTAssertNil(manager.lifecycleReport)
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count, 1)
    }

    func testPreservedUserPanGPSHasServiceRunningBadge() throws {
        let snapshot = WatchedSnapshotBuilder(excludedPID: -1).snapshot(for: .globalProtect, in: [process()])
        let card = makeCard(snapshot: snapshot)
        XCTAssertNoThrow(try card.inspect().find(text: "Service running"))
        XCTAssertThrowsError(try card.inspect().find(text: "Enforcing"))
    }

    func testBackgroundSessionDaemonPreservationGivesActionableMessage() async {
        for unknown in [false, true] {
            let runtime = fakeRuntime(unknown: unknown)
            let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: false, runtime: runtime
            )
            XCTAssertFalse(result.succeeded)
            XCTAssertTrue(result.failureSummary?.contains("preserved") == true)
            XCTAssertFalse(result.failureSummary?.contains("Choose Apply Keep Off") == true)
            let explicit = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertEqual(result, explicit)
        }
    }

    func testOtherSessionPanGPSDoesNotCauseDisconnectOrAccessibilityRequest() async {
        for owner in [uid_t(0), getuid() + 1, getuid()] {
            var other = process()
            other.uid = owner
            let runtime = attributionRuntime(processes: [other])
            let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: .init(
                lifecycle: runtime,
                requestAccessibility: { XCTFail("Unattributed PanGPS must not request Accessibility"); return false },
                application: { XCTFail("Unattributed PanGPS must not open the vendor UI"); return nil },
                disconnect: { _, _ in XCTFail("Unattributed PanGPS must not disconnect"); return .disconnected }
            ))
            XCTAssertEqual(result, .disconnected)
        }
    }

    func testDisconnectRequiresJobPIDOwnerAndKernelProductPath() async {
        for service in [GlobalProtectCompatibilityReport.Service.pangps, .pangpsd] {
            for owner in [uid_t(0), getuid()] {
                for validPath in [true, false] {
                    var observed = process()
                    observed.uid = owner
                    let validOwner = service == .pangps || owner == 0
                    let runtime = attributionRuntime(processes: [observed], service: service,
                                                     kernelPath: validPath ? observed.executablePath : "/tmp/PanGPS")
                    let shouldDisconnect = validPath && validOwner
                    let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: .init(
                        lifecycle: runtime,
                        requestAccessibility: {
                            XCTAssertTrue(shouldDisconnect, "Unverified job must not request Accessibility")
                            return true
                        },
                        application: { (pid: 4343, launched: true) },
                        disconnect: { _, _ in .failed("Fake disconnect reached") }
                    ))
                    if shouldDisconnect {
                        XCTAssertEqual(result, .failed("Fake disconnect reached"))
                    } else {
                        guard case .failed(let detail) = result else { XCTFail("Unverified attribution must fail"); continue }
                        XCTAssertTrue(detail.contains("could not verify"))
                    }
                }
            }
        }
    }

    func testUnknownJobInspectionDoesNotClaimDisconnectedOrOpenUI() async {
        var runtime = attributionRuntime(processes: [])
        runtime.runCommand = { command, _ in
            ShellCommandResult(command: command, stdout: "", stderr: "Access denied", exitCode: 1)
        }
        let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: .init(
            lifecycle: runtime,
            requestAccessibility: { XCTFail("Unknown jobs must not request Accessibility"); return false },
            application: { XCTFail("Unknown jobs must not open the vendor UI"); return nil },
            disconnect: { _, _ in XCTFail("Unknown jobs must not disconnect"); return .disconnected }
        ))
        guard case .failed(let detail) = result else { return XCTFail("Unknown jobs must not establish disconnection") }
        XCTAssertTrue(detail.contains("could not verify"))
    }

    func testKeepOffVerdictIgnoresOtherSessionsPanGPSForExplicitAndStartupActions() async {
        for explicit in [true, false] {
            for owner in [uid_t(0), getuid(), getuid() + 1] {
                var other = process()
                other.uid = owner
                let lifecycle = KeepOffLifecycle()
                let manager = makeManager(lifecycle: lifecycle, processes: [other])
                manager.globalProtectServiceObservationProvider = { .init(session: .absent, system: .absent) }
                manager.isPresetKeptOffProvider = { _ in true }
                let result = await manager.keepOff(.globalProtect, recordIntent: explicit)
                XCTAssertEqual(result.status, .completed)
                XCTAssertFalse(result.message.contains("login-session VPN service was preserved"))
                XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).isEmpty)
                XCTAssertEqual(manager.snapshots.first?.hasAny, true, "Name-based display remains available")
            }
        }
    }

    func testAttributedSessionServiceRetryDoesNotPromiseAdministratorApproval() async {
        var service = process()
        service.uid = 0
        let lifecycle = KeepOffLifecycle()
        let manager = makeManager(lifecycle: lifecycle, processes: [service])
        manager.globalProtectServiceObservationProvider = { .init(session: .running, system: .absent) }
        let result = await manager.quitAll(.globalProtect)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("login-session"))
        XCTAssertFalse(result.message.contains("administrator"))
    }

    func testKeepOffCannotReportSuccessWithUnknownJobAttribution() async {
        let manager = makeManager(lifecycle: KeepOffLifecycle())
        manager.globalProtectServiceObservationProvider = { .init(session: .unknown, system: .absent) }
        let result = await manager.keepOff(.globalProtect)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("could not verify"))
    }

    private func attributionRuntime(processes: [AppProcess], service: GlobalProtectCompatibilityReport.Service? = nil,
                                    kernelPath: String? = nil) -> ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(userID: getuid(), fileExists: { _ in false }, launchAgentLabel: { _ in nil },
                                runCommand: { command, _ in
            // Fixed job output is simulated, including another session's absent local jobs.
            let inspected: GlobalProtectCompatibilityReport.Service = command.contains("system/") ? .pangpsd : .pangps
            if inspected == service {
                return ShellCommandResult(command: command, stdout: "job = {\n\tpid = 4242\n}", stderr: "", exitCode: 0)
            }
            return ShellCommandResult(command: command, stdout: "", stderr: "Could not find service \"\(inspected.label)\" in domain", exitCode: 113)
        }, loadProcessInventory: { .success(processes) }, executablePathForPID: {
            $0 == 4343 ? GlobalProtectAccessibilityDisconnect.executable : kernelPath
        }, sendSignal: { _, _ in XCTFail("No signal is permitted"); return false },
           isProcessAlive: { _ in false }, sleep: { _ in }, systemUptime: { 0 })
    }

    private func makeCard(snapshot: WatchedAppSnapshot = WatchedAppSnapshot(preset: .globalProtect, runningNames: []),
                          enabled: Bool = true, recovery: (() -> Void)? = nil) -> PresetCard {
        PresetCard(snapshot: snapshot, onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
                   isKeptOff: true, isKeepOffControlEnabled: enabled, onKeepOffChanged: { _ in },
                   onStopWithoutDisconnect: recovery)
    }

    private func makeManager(lifecycle: KeepOffLifecycle, processes: [AppProcess] = []) -> ProcessManager {
        let inventory = KeepOffInventory(processes: processes)
        let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory,
                                     processSignaler: KeepOffSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {})
        manager.enableNotifications = false
        manager.watchedAppsProvider = { [.globalProtect] }
        return manager
    }

    private func process(name: String = "PanGPS", path: String = "/Applications/GlobalProtect.app/Contents/Resources/PanGPS") -> AppProcess {
        AppProcess(pid: 4242, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: path,
                   executablePath: path, elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
                   netInKB: 0, netOutKB: 0, diskReadBytes: 0, diskWriteBytes: 0)
    }

    private func fakeRuntime(unknown: Bool) -> ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(userID: getuid(), fileExists: { _ in true }, launchAgentLabel: { _ in nil },
                                runCommand: { command, _ in
            // Command strings are interpreted only by this fake; no shell is run.
            if command == "/bin/launchctl print-disabled system" {
                return ShellCommandResult(command: command, stdout: "disabled services = {\n}", stderr: "", exitCode: 0)
            }
            if command.hasPrefix("/bin/launchctl print ") {
                return ShellCommandResult(command: command, stdout: unknown ? "" : "system/com.paloaltonetworks.gp.pangpsd = {\n state = running\n\tpid = 4242\n}",
                                          stderr: unknown ? "Access denied" : "", exitCode: unknown ? 1 : 0)
            }
            XCTFail("Unexpected fake command: \(command)")
            return ShellCommandResult(command: command, stdout: "", stderr: "Unexpected command", exitCode: 1)
        }, loadProcessInventory: { .success([]) }, executablePathForPID: { _ in nil }, sendSignal: { _, _ in
            XCTFail("No signal is permitted"); return false
        }, isProcessAlive: { _ in false }, sleep: { _ in }, systemUptime: { 0 })
    }
}

private struct KeepOffInventory: ProcessInventoryProviding {
    let processes: [AppProcess]
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> { .success(processes) }
}

private struct KeepOffSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { XCTFail("No direct signal is permitted"); return false }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private actor KeepOffLifecycle: ProcessLifecycleServicing {
    var calls: [String] = []
    let disconnectResult: GlobalProtectDisconnectResult
    let systemResult: LifecycleBatchResult
    var onDisconnect: (@MainActor @Sendable () async -> Void)?
    var onDisable: (@MainActor @Sendable () -> Void)?
    init(disconnectResult: GlobalProtectDisconnectResult = .disconnected, systemResult: LifecycleBatchResult = .notNeeded) {
        self.disconnectResult = disconnectResult
        self.systemResult = systemResult
    }
    func setOnDisconnect(_ action: @escaping @MainActor @Sendable () async -> Void) { onDisconnect = action }
    func setOnDisable(_ action: @escaping @MainActor @Sendable () -> Void) { onDisable = action }
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        calls.append("disconnect"); await onDisconnect?(); return disconnectResult
    }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        calls.append("disable:\(preservingVPNService)"); await onDisable?(); return .notNeeded
    }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        calls.append("system:\(allowAdministratorPrompt)"); return systemResult
    }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    nonisolated func appBundleExists(at path: String) -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { XCTFail("No launch is permitted"); return .failed("Fake launch failed.") }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}

private actor KeepOffPause {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
