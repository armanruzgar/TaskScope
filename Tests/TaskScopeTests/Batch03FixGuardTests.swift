import Darwin
import Foundation
import XCTest
@testable import TaskScope

// Each test pins one ProcessManager guard that removing would otherwise leave
// unnoticed. All fakes only record: no signal, launchctl, app launch or
// Accessibility.

private actor Batch03GuardInventory: ProcessInventoryProviding {
    private var result: Result<[AppProcess], ProcessInventoryError>
    private var blockFirst: Bool
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?

    init(_ result: Result<[AppProcess], ProcessInventoryError>, blockFirst: Bool = false) {
        self.result = result
        self.blockFirst = blockFirst
    }

    /// Deliberately ignores cancellation of the awaiting task: the read
    /// completes and succeeds, as a read can when cancellation lands after the
    /// reader's last cancellation check.
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if blockFirst {
            blockFirst = false
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { blocked = $0 }
        }
        return result
    }

    func set(_ result: Result<[AppProcess], ProcessInventoryError>) { self.result = result }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private final class Batch03GuardSignaler: ProcessSignaling {
    private(set) var delivered: [Int32] = []
    func send(_ signal: Int32, to pid: Int32) -> Bool { deliver(signal, to: pid) == .delivered }
    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        delivered.append(pid)   // recorded only; no kill(2)
        return .delivered
    }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private actor Batch03GuardLifecycle: ProcessLifecycleServicing {
    let systemResult: LifecycleBatchResult
    init(systemResult: LifecycleBatchResult = .notNeeded) { self.systemResult = systemResult }
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult { .disconnected }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { systemResult }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        .notNeeded
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    nonisolated func appBundleExists(at path: String) -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .failed("Not opened in tests.") }
}

@MainActor
final class Batch03GuardTests: XCTestCase {
    private let ownPID: Int32 = 999_002

    private func row(_ pid: Int32, start: String = "Sat Jul 26 11:20:17 2026",
                     path: String = "/Applications/Example.app/Contents/MacOS/Example") -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1, command: path,
                   executablePath: path, elapsedTime: "00:10", startTime: start,
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func manager(_ list: Batch03GuardInventory, verification: Batch03GuardInventory? = nil,
                         signaler: Batch03GuardSignaler = Batch03GuardSignaler(),
                         lifecycle: Batch03GuardLifecycle = Batch03GuardLifecycle()) -> ProcessManager {
        let manager = ProcessManager(processInventory: list, verificationInventory: verification ?? list,
                                     processSignaler: signaler, lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, currentPID: ownPID,
                                     pollingController: ProcessPollingController(sleep: { _ in false }))
        manager.enableNotifications = false
        manager.watchedAppsProvider = { [] }
        return manager
    }

    // Cancellation checks around the verification read and before kill(2).
    func testBatch03CancelledSingleStopDoesNotSignalWhenItsReadSucceeds() async {
        let target = row(4200)
        let verification = Batch03GuardInventory(.success([target]), blockFirst: true)
        let signaler = Batch03GuardSignaler()
        let manager = manager(Batch03GuardInventory(.success([target])), verification: verification, signaler: signaler)
        let stop = Task { await manager.terminate(target) }
        await verification.waitUntilEntered()
        stop.cancel()
        await verification.release()
        let result = await stop.value
        XCTAssertTrue(signaler.delivered.isEmpty, "A cancelled Stop must not signal")
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(manager.message, "Stop for Example was cancelled.")
    }

    func testCancelledBatchWithSuccessfulVerificationNeverSignals() async {
        let target = row(4200)
        let verification = Batch03GuardInventory(.success([target]), blockFirst: true)
        let signaler = Batch03GuardSignaler()
        let manager = manager(Batch03GuardInventory(.success([target])), verification: verification, signaler: signaler)
        manager.setMessage("existing status")
        let stop = Task { await manager.batchTerminate([target.identity]) }
        await verification.waitUntilEntered()
        stop.cancel()
        await verification.release()
        await stop.value
        XCTAssertTrue(signaler.delivered.isEmpty)
        XCTAssertNil(manager.batchActionReport)
        XCTAssertEqual(manager.message, "existing status")
    }

    // select(_:) keeps only identities in the current inventory.
    func testBatch03SelectDropsRowsWhoseIdentityIsNotInTheInventory() async {
        let live = row(4300)
        let manager = manager(Batch03GuardInventory(.success([live])))
        await manager.loadProcessList(showMessage: false)
        let recycled = row(4300, start: "Sat Jul 26 12:00:00 2026")
        let exited = row(4301)
        manager.select([recycled, exited])
        XCTAssertTrue(manager.selectedPids.isEmpty, "Stale or recycled rows must not be selected")
    }

    // toggleSelection(_:) and select(_:) never select TaskScope itself.
    func testBatch03ToggleSelectionRefusesTaskScopeItself() async {
        let own = row(ownPID, path: "/Applications/TaskScope.app/Contents/MacOS/TaskScope")
        let manager = manager(Batch03GuardInventory(.success([own, row(4400)])))
        await manager.loadProcessList(showMessage: false)
        manager.toggleSelection(ownPID)
        XCTAssertFalse(manager.selectedPids.contains(ownPID))
        manager.select([own])
        XCTAssertTrue(manager.selectedPids.isEmpty)
    }

    // A cancelled watched read publishes no failure.
    func testBatch03CancelledWatchedRefreshPublishesNoFailure() async {
        let manager = manager(Batch03GuardInventory(.failure(.cancelled)))
        manager.setMessage("existing status")
        let refreshed = await manager.refreshWatchedStatus()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(manager.message, "existing status")
    }

    // A cancelled list read publishes no failure.
    func testBatch03CancelledListLoadPublishesNoFailure() async {
        let manager = manager(Batch03GuardInventory(.failure(.cancelled)))
        manager.setMessage("existing status")
        let loaded = await manager.loadProcessList()
        XCTAssertFalse(loaded)
        XCTAssertEqual(manager.message, "existing status")
    }

    private func keepOffManager(_ inventory: Batch03GuardInventory) -> ProcessManager {
        let failed = LifecycleBatchResult(jobs: [
            LifecycleJobResult(label: "com.paloaltonetworks.gp.pangpsd", state: .failed, detail: "Same failure")
        ])
        let manager = manager(inventory, lifecycle: Batch03GuardLifecycle(systemResult: failed))
        manager.watchedAppsProvider = { [.globalProtect] }
        manager.keptOffPresetsProvider = { [.globalProtect] }
        manager.isPresetKeptOffProvider = { _ in true }
        return manager
    }

    private var ui: AppProcess { row(4343, path: GlobalProtectAccessibilityDisconnect.executable) }

    // The remembered background failure is forgotten once targets disappear.
    func testBatch03BackgroundFailureIsReportedAgainAfterTargetsDisappear() async {
        let inventory = Batch03GuardInventory(.success([ui]))
        let manager = keepOffManager(inventory)
        await manager.enforceKeptOffPresets()
        let first = manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count
        XCTAssertEqual(first, 1)
        await inventory.set(.success([]))
        await manager.enforceKeptOffPresets()   // targets gone
        manager.setMessage("other status")
        await inventory.set(.success([ui]))     // UI returns, same failure
        await manager.enforceKeptOffPresets()
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count, 2)
        XCTAssertNotEqual(manager.message, "other status")
    }

    // An explicit Keep Off forgets the remembered background failure.
    func testBatch03ExplicitKeepOffClearsRememberedBackgroundFailure() async {
        let inventory = Batch03GuardInventory(.success([ui]))
        let manager = keepOffManager(inventory)
        await manager.enforceKeptOffPresets()              // background failure remembered
        _ = await manager.keepOff(.globalProtect)          // explicit attempt
        let beforeTick = manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count
        manager.setMessage("other status")
        await manager.enforceKeptOffPresets()              // same background failure again
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).count, beforeTick + 1)
        XCTAssertNotEqual(manager.message, "other status")
    }
}
