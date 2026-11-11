import Darwin
import Foundation
import XCTest
import ViewInspector
@testable import TaskScope

@MainActor
final class Batch03FixTests: XCTestCase {
    private func row(_ pid: Int32 = 42, name: String = "Example", uid: uid_t = getuid()) -> AppProcess {
        AppProcess.fixture(pid: pid, parentPID: 1, uid: uid, cpu: 1, memoryMB: 1,
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
                         signaler: any ProcessSignaling = FakeSignaler(),
                         lifecycle: FakeLifecycle = FakeLifecycle.allSucceeding(),
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
            let signaler = FakeSignaler(alive: [target.pid])
            let manager = manager(ScriptedInventory([.success([target])], repeatsLast: true), signaler: signaler)
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
        let signaler = FakeSignaler()
        let verification = ScriptedInventory([.failure(.commandFailed("ps failed"))], repeatsLast: true)
        let manager = manager(ScriptedInventory([.success([target])], repeatsLast: true), verification: verification, signaler: signaler)
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
        let manager = manager(ScriptedInventory([.success([first, later])], repeatsLast: true),
                              signaler: FakeSignaler(alive: [first.pid]),
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
        let lifecycle = FakeLifecycle.allSucceeding()
        lifecycle.onBootstrapAgents = { await hold.wait() }
        let inventory = ScriptedInventory([.success([first, later])], repeatsLast: true)
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
            let signaler = FakeSignaler(alive: [b.pid])
            let manager = manager(ScriptedInventory([.success([a, b])], repeatsLast: true), signaler: signaler)
            await manager.batchTerminate([a.identity, b.identity, c.identity], forceKill: force)
            XCTAssertEqual(manager.message, "\(force ? "Force stopped" : "Stopped") 1 of 3 selected; 1 still running, 1 no longer matched.")
            XCTAssertEqual(manager.batchActionReport?.targets.map(\.state), [.stopped, .requestedStillRunning, .stale])
        }
    }

    func testSingleAndBatchPIDGuardsAndSelfSelection() async {
        let invalid = [Int32(-1), 0, 1].map { row($0) }
        let own = row(999_999), valid = row()
        let signaler = FakeSignaler()
        let manager = manager(ScriptedInventory([.success(invalid + [own, valid])], repeatsLast: true), signaler: signaler)
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
        let rejected = manager(ScriptedInventory([.success([target])], repeatsLast: true),
                               signaler: FakeSignaler(rejected: [target.pid]))
        let result = await rejected.terminate(target)
        XCTAssertEqual(result, .refused)
        XCTAssertEqual(rejected.message, "Could not send stop to Example. The process is not owned by the current user.")
        await rejected.batchTerminate([target.identity])
        XCTAssertEqual(rejected.batchActionReport?.targets.map(\.state), [.signalRejected])
        XCTAssertEqual(rejected.batchActionReport?.targets.first?.detail, "The process is not owned by the current user.")

        let own = row()
        let refusedOwn = manager(ScriptedInventory([.success([own])], repeatsLast: true),
                                 signaler: FakeSignaler(rejected: [own.pid]))
        _ = await refusedOwn.terminate(own, forceKill: true)
        XCTAssertEqual(refusedOwn.message, "Could not send force stop to Example. The system refused the stop request.")

        let survivor = manager(ScriptedInventory([.success([target])], repeatsLast: true),
                               signaler: FakeSignaler(alive: [target.pid]))
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
            let signaler = FakeSignaler(alive: [target.pid])
            var polls = 0
            let manager = manager(ScriptedInventory([.success([target])], repeatsLast: true), signaler: signaler, settle: {
                polls += 1
                if polls == 3 { signaler.setAlive(target.pid, false) }
            })
            if batch {
                await manager.batchTerminate([target.identity])
                XCTAssertEqual(manager.batchActionReport?.targets.first?.state, .stopped)
            } else {
                let result = await manager.terminate(target)
                XCTAssertEqual(result, .stopped)
            }
            XCTAssertEqual(polls, 3)
            XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM])
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
        let inventory = ScriptedInventory([.success([target, bystander])], repeatsLast: true)
        let verification = ScriptedInventory([.success([basicBystander])], repeatsLast: true)
        let manager = manager(inventory, verification: verification)
        await manager.beginExtendedMetrics()
        await manager.loadProcessList()
        let result = await manager.terminate(target)
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(verification.extendedStatsRequests, [false])
        XCTAssertEqual(manager.inventorySnapshot.first, bystander)
        manager.endExtendedMetrics()
    }

    func testOpenStopsAtFailedReenablesAndPreservesIntent() async {
        for system in [false, true] {
            let lifecycle = FakeLifecycle.allSucceeding()
            let failed = LifecycleBatchResult(jobs: [.init(label: "job", state: .failed, detail: "Cancelled.")])
            if system { lifecycle.enableDaemonsResult = failed } else { lifecycle.enableAgentsResult = failed }
            let manager = manager(ScriptedInventory([.success([])], repeatsLast: true), lifecycle: lifecycle)
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
            let lifecycle = FakeLifecycle.allSucceeding()
            lifecycle.bootstrapAgentsResult = changed
            lifecycle.openResult = .failed("Fake launch failed.")
            let inventory = ScriptedInventory([
                .success([]), failedRead ? .failure(.commandFailed("ps failed")) : .success([])
            ], repeatsLast: true)
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
            let lifecycle = FakeLifecycle.allSucceeding()
            let manager = manager(
                ScriptedInventory([.success([row()]), .success([row()]), final], repeatsLast: true),
                lifecycle: lifecycle
            )

            let result = await manager.openApp(preset)

            XCTAssertEqual(result, expected)
            XCTAssertEqual(lifecycle.calls, ["exists", "daemon", "agents.load", "open"])
        }

        let lifecycle = FakeLifecycle.allSucceeding()
        lifecycle.openResult = .failed("Fake launch failed.")
        let manager = manager(ScriptedInventory([.success([row()])], repeatsLast: true), lifecycle: lifecycle)
        let result = await manager.openApp(preset)
        XCTAssertEqual(result, TaskScopeCommandResult(status: .failed, message: "Could not open Example: Fake launch failed."))
    }

    func testKeepOffTerminationFailuresTakePrecedenceOverFinalInventory() async {
        for outcome in [ProcessTerminationOutcome.signalRejected, .inventoryUnavailable] {
            for final in [[AppProcess](), [row()]] {
                let lifecycle = FakeLifecycle.allSucceeding()
                lifecycle.terminationOutcome = outcome
                let manager = manager(ScriptedInventory([.success([row()]), .success(final)], repeatsLast: true), lifecycle: lifecycle)
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
        let lifecycle = FakeLifecycle.allSucceeding()
        lifecycle.disconnectResult = .failed("Complete the request in GlobalProtect.")
        var time = Date(timeIntervalSince1970: 1_000)
        let manager = manager(ScriptedInventory([.success([])], repeatsLast: true), lifecycle: lifecycle, now: { time })
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
        let inventory = ScriptedInventory([.success([]), .failure(.commandFailed("watched failed"))], repeatsLast: true)
        let verification = ScriptedInventory([.success([])], repeatsLast: true)
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

        let healthy = self.manager(ScriptedInventory([.success([])], repeatsLast: true),
                              verification: ScriptedInventory([.failure(.commandFailed("verify failed"))], repeatsLast: true))
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
