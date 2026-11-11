import Darwin
import Foundation
import XCTest
import ViewInspector
@testable import TaskScope

@MainActor
final class Batch03FixTests: XCTestCase {
    private func row(_ pid: Int32 = 42, name: String = "Example", uid: uid_t = getuid()) -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: uid, cpu: 1, memoryMB: 1,
                   command: "/Applications/\(name).app/Contents/MacOS/\(name)",
                   executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
                   elapsedTime: "00:10", startTime: "start-\(pid)",
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private var preset: WatchedAppPreset {
        WatchedAppPreset(id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!, displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
                         protectedProcessNames: [], appPath: "/Applications/Example.app")
    }

    private func manager(_ inventory: any ProcessInventoryProviding,
                         verification: (any ProcessInventoryProviding)? = nil,
                         signaler: any ProcessSignaling = ManagerTestSignaler(),
                         lifecycle: ManagerTestLifecycle = ManagerTestLifecycle(),
                         settle: @escaping () async -> Void = {},
                         now: @escaping () -> Date = Date.init) -> ProcessManager {
        let manager = ProcessManager(processInventory: inventory, verificationInventory: verification,
                                     processSignaler: signaler, lifecycle: lifecycle,
                                     settleAfterProcessChange: settle, currentPID: 999_999, now: now, dependencies: .inert)
        manager.enableNotifications = false
        return manager
    }

    func testBatchSurvivorsRemainReportedAndRequestedSelectionIsCleared() async {
        for force in [false, true] {
            let target = row()
            let signaler = ManagerTestSignaler(alivePids: [target.pid])
            let manager = manager(ManagerTestInventory(results: [.success([target])]), signaler: signaler)
            await manager.loadProcessList()
            manager.select([target])
            await manager.batchTerminate(manager.selectionSnapshot(), forceKill: force)
            XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.requestedStillRunning])
            XCTAssertEqual(manager.message, "\(force ? "Force stopped" : "Stopped") 0 of 1 selected; 1 still running.")
            XCTAssertTrue(manager.selectedPids.isEmpty)
            XCTAssertEqual(signaler.sent.map(\.signal), [force ? SIGKILL : SIGTERM])
        }
    }

    func testUnverifiedBatchPreservesSelectionAndSendsNothing() async {
        let target = row()
        let signaler = ManagerTestSignaler()
        let verification = ManagerTestInventory(results: [.failure(.commandFailed("ps failed"))])
        let manager = manager(ManagerTestInventory(results: [.success([target])]), verification: verification, signaler: signaler)
        await manager.loadProcessList()
        manager.select([target])
        await manager.batchTerminate(manager.selectionSnapshot())
        XCTAssertEqual(manager.selectedPids, [target.pid])
        XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.unverified])
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    func testBatchOnlyDeselectsCapturedIdentitiesWhileSettling() async {
        let first = row(), later = row(43)
        let hold = Batch03Hold()
        let manager = manager(ManagerTestInventory(results: [.success([first, later])]),
                              signaler: ManagerTestSignaler(alivePids: [first.pid]),
                              settle: { await hold.wait() })
        await manager.loadProcessList()
        manager.select([first])
        let batch = Task { await manager.batchTerminate([first.identity]) }
        await hold.waitUntilEntered()
        manager.toggleSelection(later.pid)
        await hold.open()
        await batch.value
        XCTAssertEqual(manager.selectedPids, [later.pid])
    }

    func testBatchPreservesSelectionsMadeWhileWaitingForAdmission() async {
        let first = row(), later = row(43)
        let hold = Batch03Hold()
        let lifecycle = ManagerTestLifecycle()
        lifecycle.agentLoadAction = { await hold.wait() }
        let inventory = ManagerTestInventory(results: [.success([first, later])])
        let manager = manager(inventory, lifecycle: lifecycle)
        await manager.loadProcessList()
        manager.select([first])
        let owner = Task { await manager.openApp(self.preset) }
        await hold.waitUntilEntered()
        let batch = Task { await manager.batchTerminate([first.identity]) }
        for _ in 0..<500 where manager.operationState != .queued { await Task.yield() }
        XCTAssertEqual(manager.operationState, .queued)
        manager.toggleSelection(later.pid)
        await hold.open()
        _ = await owner.value
        await batch.value
        XCTAssertEqual(manager.selectedPids, [later.pid])
    }

    func testLifecycleSummaryDoesNotDuplicateFinalPunctuation() {
        let result = LifecycleBatchResult(jobs: [
            .init(label: "one", state: .failed, detail: "Keep Off is incomplete."),
            .init(label: "two", state: .failed, detail: "Missing job")
        ])
        XCTAssertEqual(result.failureSummary, "one: Keep Off is incomplete; two: Missing job")
    }

    func testBatchSummaryIncludesStoppedAndOnlyNonzeroRemainders() async {
        let a = row(), b = row(43), c = row(44)
        for force in [false, true] {
            let signaler = ManagerTestSignaler(alivePids: [b.pid])
            let manager = manager(ManagerTestInventory(results: [.success([a, b])]), signaler: signaler)
            await manager.batchTerminate([a.identity, b.identity, c.identity], forceKill: force)
            XCTAssertEqual(manager.message, "\(force ? "Force stopped" : "Stopped") 1 of 3 selected; 1 still running, 1 no longer matched.")
            XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.stopped, .requestedStillRunning, .stale])
        }
    }

    func testSingleAndBatchPIDGuardsAndSelfSelection() async {
        let invalid = [Int32(-1), 0, 1].map { row($0) }
        let own = row(999_999), valid = row()
        let signaler = ManagerTestSignaler()
        let manager = manager(ManagerTestInventory(results: [.success(invalid + [own, valid])]), signaler: signaler)
        await manager.loadProcessList()
        manager.toggleSelection(own.pid)
        XCTAssertTrue(manager.selectedPids.isEmpty)
        manager.select([own, valid])
        XCTAssertEqual(manager.selectedPids, [valid.pid])
        for process in invalid {
            let result = await manager.terminate(process)
            XCTAssertEqual(result, .refused)
        }
        await manager.batchTerminate((invalid + [valid]).map(\.identity))
        XCTAssertEqual(signaler.sent.map(\.pid), [valid.pid])
        XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.signalRejected, .signalRejected, .signalRejected, .stopped])
    }

    func testRefusedSignalsExplainOwnershipAndForceSurvivorsRemainRunning() async {
        let target = row(uid: getuid() + 1)
        let rejected = manager(ManagerTestInventory(results: [.success([target])]),
                               signaler: ManagerTestSignaler(rejectedPids: [target.pid]))
        let result = await rejected.terminate(target)
        XCTAssertEqual(result, .refused)
        XCTAssertEqual(rejected.message, "Could not send stop to Example. The process is not owned by the current user.")
        await rejected.batchTerminate([target.identity])
        XCTAssertEqual(rejected.batchActionReport?.targets.map(\.state), [.signalRejected])
        XCTAssertEqual(rejected.batchActionReport?.targets.first?.detail, "The process is not owned by the current user.")

        let own = row()
        let refusedOwn = manager(ManagerTestInventory(results: [.success([own])]),
                                 signaler: ManagerTestSignaler(rejectedPids: [own.pid]))
        _ = await refusedOwn.terminate(own, forceKill: true)
        XCTAssertEqual(refusedOwn.message, "Could not send force stop to Example. The system refused the stop request.")

        let survivor = manager(ManagerTestInventory(results: [.success([target])]),
                               signaler: ManagerTestSignaler(alivePids: [target.pid]))
        let forceResult = await survivor.terminate(target, forceKill: true)
        XCTAssertEqual(forceResult, .requestedStillRunning)
        XCTAssertEqual(survivor.message, "Example is still running after Force Stop.")
    }

    /// Manual and automatic stops explain a refusal with the same words.
    func testRefusalDetailIsSharedAndUsesTheKernelAnswer() {
        let ownPID: Int32 = 999_999
        let process = row()
        XCTAssertEqual(
            ProcessSignalGuard.refusalDetail(for: row(ownPID), currentPID: ownPID, currentUID: getuid()),
            "TaskScope cannot stop itself; use Quit to close TaskScope."
        )
        XCTAssertEqual(
            ProcessSignalGuard.refusalDetail(for: row(1), currentPID: ownPID, currentUID: getuid()),
            "This PID cannot be signalled."
        )
        XCTAssertEqual(
            ProcessSignalGuard.refusalDetail(for: process, currentPID: ownPID, currentUID: getuid() + 1, errno: EPERM),
            "The process is not owned by the current user."
        )
        XCTAssertEqual(
            ProcessSignalGuard.refusalDetail(for: process, currentPID: ownPID, currentUID: getuid(), errno: EPERM),
            "The system refused the stop request."
        )
        XCTAssertEqual(
            ProcessSignalGuard.refusalDetail(for: process, currentPID: ownPID, currentUID: getuid(), errno: EINVAL),
            "The system refused the stop request (Invalid argument)."
        )
    }

    func testDelayedGracefulExitIsObservedForSingleAndBatchWithoutEscalation() async {
        for batch in [false, true] {
            let target = row()
            let signaler = Batch03DelayedSignaler()
            var polls = 0
            let manager = manager(ManagerTestInventory(results: [.success([target])]), signaler: signaler, settle: {
                polls += 1
                if polls == 3 { signaler.alive = false }
            })
            if batch {
                await manager.batchTerminate([target.identity])
                XCTAssertEqual(manager.batchActionReport?.targets.first?.state, .stopped)
            } else {
                let result = await manager.terminate(target)
                XCTAssertEqual(result, .stopped)
            }
            XCTAssertEqual(polls, 3)
            XCTAssertEqual(signaler.signals, [SIGTERM])
        }
    }

    func testSingleStopVerifiesWithoutExtendedStatsAndPreservesOldMetricsForUnchangedRows() async {
        let target = row()
        var bystander = row(43)
        bystander.netInKB = 12
        bystander.netOutKB = 13
        bystander.diskReadBytes = 14
        bystander.diskWriteBytes = 15
        var basicBystander = bystander
        basicBystander.netInKB = nil
        basicBystander.netOutKB = nil
        basicBystander.diskReadBytes = nil
        basicBystander.diskWriteBytes = nil
        let inventory = ManagerTestInventory(results: [.success([target, bystander])])
        let verification = ManagerTestInventory(results: [.success([basicBystander])])
        let manager = manager(inventory, verification: verification)
        await manager.beginExtendedMetrics()
        await manager.loadProcessList()
        let result = await manager.terminate(target)
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(verification.fetchExtendedRequests, [false])
        XCTAssertEqual(manager.inventorySnapshot.first, bystander)
        manager.endExtendedMetrics()
    }

    func testOpenStopsAtFailedReenablesAndPreservesIntent() async {
        for system in [false, true] {
            let lifecycle = ManagerTestLifecycle()
            let failed = LifecycleBatchResult(jobs: [.init(label: "job", state: .failed, detail: "Cancelled.")])
            if system { lifecycle.systemEnableResult = failed } else { lifecycle.agentEnableResult = failed }
            let manager = manager(ManagerTestInventory(results: [.success([])]), lifecycle: lifecycle)
            var keptOff = true
            manager.dependencies.isPresetKeptOff = { _ in keptOff }
            manager.dependencies.setPresetKeptOff = { _, value in keptOff = value }
            let result = await manager.openApp(system ? .globalProtect : preset)
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(keptOff)
            XCTAssertEqual(lifecycle.calls, system ? ["exists", "daemon", "daemon.enable"] : ["exists", "daemon", "agents.enable"])
            XCTAssertFalse(result.message.contains(".."))
        }
    }

    /// Open's late failures happen after Keep Off was cleared and the services
    /// were restored; their messages must say so instead of "nothing was opened".
    func testOpenLateFailuresSayKeepOffWasClearedAndServicesWereRestored() async {
        let changed = LifecycleBatchResult(jobs: [.init(label: "job", state: .changed, detail: "Restored.")])
        for failedRead in [false, true] {
            let lifecycle = ManagerTestLifecycle()
            lifecycle.agentLoadResult = changed
            lifecycle.openResult = false
            let inventory = ManagerTestInventory(results: [
                .success([]), failedRead ? .failure(.commandFailed("ps failed")) : .success([])
            ])
            let manager = manager(inventory, lifecycle: lifecycle)
            var keptOff = true
            manager.dependencies.isPresetKeptOff = { _ in keptOff }
            manager.dependencies.setPresetKeptOff = { _, value in keptOff = value }

            let result = await manager.openApp(preset)

            XCTAssertEqual(result.status, .failed)
            XCTAssertFalse(keptOff)
            XCTAssertEqual(result.message, failedRead
                ? "Keep Off was turned off and required services were restored. Could not verify whether Example started with its services; no app launch was requested."
                : "Keep Off was turned off and required services were restored. Could not open Example: Fake launch failed.")
            XCTAssertEqual(lifecycle.calls.contains("open"), !failedRead)
        }
    }

    /// An app that was already running before Open is brought forward with a
    /// plain `open` (which reuses the running instance) rather than reported as
    /// opened while nothing happened; its late failures never claim a launch.
    func testOpenBringsAnAlreadyRunningAppForwardAndNeverClaimsALaunch() async {
        let finals: [(Result<[AppProcess], ProcessInventoryError>, TaskScopeCommandResult)] = [
            (.success([row()]), TaskScopeCommandResult(status: .completed, message: "Opened Example.")),
            (.failure(.commandFailed("ps failed")), TaskScopeCommandResult(
                status: .failed, message: "Example was running, but TaskScope could not verify its final state."
            )),
            (.success([]), TaskScopeCommandResult(
                status: .failed, message: "Example was running, but its main process could not be verified."
            ))
        ]
        for (final, expected) in finals {
            let lifecycle = ManagerTestLifecycle()
            let manager = manager(
                ManagerTestInventory(results: [.success([row()]), .success([row()]), final]),
                lifecycle: lifecycle
            )

            let result = await manager.openApp(preset)

            XCTAssertEqual(result, expected)
            XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load", "open"])
        }

        let lifecycle = ManagerTestLifecycle()
        lifecycle.openResult = false
        let manager = manager(ManagerTestInventory(results: [.success([row()])]), lifecycle: lifecycle)
        let result = await manager.openApp(preset)
        XCTAssertEqual(result, TaskScopeCommandResult(status: .failed, message: "Could not open Example: Fake launch failed."))
    }

    func testKeepOffTerminationFailuresTakePrecedenceOverFinalInventory() async {
        for outcome in [ProcessTerminationOutcome.signalRejected, .inventoryUnavailable] {
            for final in [[AppProcess](), [row()]] {
                let lifecycle = ManagerTestLifecycle()
                lifecycle.terminationOutcome = outcome
                let manager = manager(ManagerTestInventory(results: [.success([row()]), .success(final)]), lifecycle: lifecycle)
                let watched = preset
                manager.dependencies.watchedPresets = { [watched] }
                let result = await manager.keepOff(preset)
                XCTAssertEqual(result.status, .failed)
                let expected: LifecycleDiagnosticFailure.Reason = outcome == .signalRejected ? .signalRejected : .inventoryUnavailable
                XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: preset.id).first?.reason, expected)
                XCTAssertEqual(result.message, outcome == .signalRejected
                               ? "Keep Off disabled relaunch jobs, but a running process rejected the stop signal."
                               : "Keep Off disabled relaunch jobs, but the process list became unavailable before app processes could be stopped.")
            }
        }
    }

    func testFailedExplicitDisconnectLeavesVendorUIAvailableDuringEnforcement() async {
        let lifecycle = ManagerTestLifecycle()
        lifecycle.disconnectResult = .failed("Complete the request in GlobalProtect.")
        var time = Date(timeIntervalSince1970: 1_000)
        let manager = manager(ManagerTestInventory(results: [.success([])]), lifecycle: lifecycle, now: { time })
        manager.dependencies.watchedPresets = { [.globalProtect] }
        manager.dependencies.keptOffPresets = { [.globalProtect] }
        manager.dependencies.isPresetKeptOff = { _ in true }
        let result = await manager.keepOff(.globalProtect)
        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(manager.globalProtectDisconnectFailureID)
        let calls = lifecycle.calls
        await manager.enforceKeptOffPresets(force: true)
        XCTAssertEqual(lifecycle.calls, calls)
        XCTAssertEqual(manager.message, result.message)
        time = time.addingTimeInterval(ProcessManager.disconnectFailureGraceSeconds + 1)
        await manager.enforceKeptOffPresets(force: true)
        XCTAssertTrue(lifecycle.calls.contains("agents.disable"), "enforcement must resume after the grace period")
    }

    func testWatchedErrorSurvivesSuccessfulVerificationAndVerificationFailuresDoNotMarkWatchedStale() async {
        let inventory = ManagerTestInventory(results: [.success([]), .failure(.commandFailed("watched failed"))])
        let verification = ManagerTestInventory(results: [.success([])])
        let manager = manager(inventory, verification: verification)
        await manager.refreshWatchedStatus()
        await manager.refreshWatchedStatus()
        let lastRead = manager.lastSuccessfulWatchedReadAt
        manager.dependencies.keptOffPresets = { [self.preset] }
        await manager.enforceKeptOffPresets()
        XCTAssertNil(manager.processLoadError)
        XCTAssertEqual(manager.watchedStatusLoadError, "watched failed")
        XCTAssertEqual(manager.watchedStatusAvailability, .stale)
        XCTAssertEqual(manager.lastSuccessfulWatchedReadAt, lastRead)

        let healthy = self.manager(ManagerTestInventory(results: [.success([])]),
                              verification: ManagerTestInventory(results: [.failure(.commandFailed("verify failed"))]))
        await healthy.refreshWatchedStatus()
        _ = await healthy.terminate(row())
        XCTAssertEqual(healthy.watchedStatusAvailability, .current)
        XCTAssertNil(healthy.watchedStatusLoadError)
        await healthy.batchTerminate([row().identity])
        XCTAssertEqual(healthy.watchedStatusAvailability, .current)
        XCTAssertNil(healthy.watchedStatusLoadError)
        XCTAssertEqual(healthy.processLoadError, "verify failed")
    }

    func testSilentReadsKeepFooterResultWhileExplicitReadReportsProgress() async throws {
        for list in [false, true] {
            for explicit in [false, true] {
                let hold = Batch03Hold()
                let inventory = Batch03HeldInventory(hold: hold)
                let manager = manager(inventory)
                manager.setMessage("Last result")
                let read = Task {
                    if list { return await manager.loadProcessList(showMessage: explicit) }
                    return await manager.refreshWatchedStatus(showMessage: explicit)
                }
                await hold.waitUntilEntered()
                XCTAssertEqual(manager.isWorking, explicit)
                let footer = TaskScopeFooterView(isWorking: manager.isWorking, message: manager.message, summary: nil, quitAction: {})
                if !explicit { XCTAssertNoThrow(try footer.inspect().find(text: "Last result")) }
                await hold.open()
                _ = await read.value
                XCTAssertFalse(manager.isWorking)
            }
        }
    }
}

/// DarwinProcessSignaler's reading of `kill(2)` through an injected call. The
/// injected call only records, and every case uses the null signal, so nothing
/// is ever sent; the controlled-child tests in ProcessSignalIntegrationTests
/// cover the real system call.
final class Batch03DarwinSignalerTests: XCTestCase {
    private final class KillLog: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [Int32] = []
        var calls: [Int32] { lock.withLock { pids } }
        func record(_ pid: Int32) { lock.withLock { pids.append(pid) } }
    }

    func testDeliveryMapsTheKernelAnswer() {
        let answers: [(answer: (Int32, Int32), delivery: ProcessSignalDelivery)] = [
            ((0, 0), .delivered),
            ((-1, ESRCH), .noSuchProcess),
            ((-1, EPERM), .rejected(errno: EPERM)),
            ((-1, EINVAL), .rejected(errno: EINVAL))
        ]
        for (answer, delivery) in answers {
            let signaler = DarwinProcessSignaler(kill: { _, _ in answer })
            XCTAssertEqual(signaler.deliver(0, to: 4242), delivery)
            XCTAssertEqual(signaler.send(0, to: 4242), delivery == .delivered)
        }
    }

    /// `kill(pid, 0)` failing with EPERM means the process exists but belongs
    /// to someone else, so it is alive. The test's own pid is used because the
    /// zombie check reads that pid's real kernel state; it is never signalled.
    func testLivenessTreatsPermissionDeniedAsAlive() {
        let pid = getpid()
        XCTAssertTrue(DarwinProcessSignaler(kill: { _, _ in (0, 0) }).isAlive(pid))
        XCTAssertTrue(DarwinProcessSignaler(kill: { _, _ in (-1, EPERM) }).isAlive(pid))
        XCTAssertFalse(DarwinProcessSignaler(kill: { _, _ in (-1, ESRCH) }).isAlive(pid))
    }

    func testPIDGuardRunsBeforeTheKernelCall() {
        let log = KillLog()
        let signaler = DarwinProcessSignaler(kill: { pid, _ in
            log.record(pid)
            return (0, 0)
        })
        for pid: Int32 in [1, 0, -1] {
            XCTAssertEqual(signaler.deliver(0, to: pid), .rejected(errno: EINVAL))
            XCTAssertFalse(signaler.isAlive(pid))
        }
        XCTAssertTrue(log.calls.isEmpty)
    }
}

private final class Batch03DelayedSignaler: ProcessSignaling {
    var alive = true
    var signals: [Int32] = []
    func send(_ signal: Int32, to pid: Int32) -> Bool { signals.append(signal); return true }
    func isAlive(_ pid: Int32) -> Bool { alive }
}

actor Batch03Hold {
    private var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entries: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        entries.forEach { $0.resume() }; entries.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entries.append($0) } }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}

private struct Batch03HeldInventory: ProcessInventoryProviding {
    let hold: Batch03Hold
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        await hold.wait()
        return .success([])
    }
}
