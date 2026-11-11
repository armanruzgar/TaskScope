import Darwin
import XCTest
@testable import TaskScope

/// Pins the two ProcessOperationGate cancellation paths. All collaborators are
/// fakes; nothing is signalled and no launchctl runs.
@MainActor
final class Batch03GateCancellationTests: XCTestCase {
    /// The re-check after admission. The queued mutation is cancelled in the
    /// owner's last synchronous step, so release() promotes it before the
    /// cancellation handler's main-actor task can dequeue it.
    func testWaiterCancelledAsItIsPromotedDoesNotRunAndHandsTheGateOn() async {
        let gate = ProcessOperationGate()
        let latch = Batch03Latch()
        let box = Batch03GateBox()
        let owner = Task {
            await gate.run(kind: .mutation) {
                await latch.wait()
                box.queued?.cancel()
            }
        }
        for _ in 0..<500 where !gate.isMutationActive { await Task.yield() }
        box.queued = Task { await gate.run(kind: .mutation) { box.log.append("cancelled mutation ran") } }
        for _ in 0..<500 where gate.state != .queued { await Task.yield() }
        XCTAssertEqual(gate.state, .queued)
        let next = Task { await gate.run(kind: .read(.processList)) { box.log.append("next read ran") } }
        for _ in 0..<50 { await Task.yield() }

        await latch.open()
        let ownerRan = await owner.value
        let queuedRan = await box.queued!.value
        let nextRan = await next.value
        XCTAssertTrue(ownerRan)
        XCTAssertFalse(queuedRan, "a waiter cancelled at promotion reported that it ran")
        XCTAssertEqual(box.log, ["next read ran"], "a waiter cancelled at promotion executed its operation")
        XCTAssertTrue(nextRan)
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.isWorking)
    }

    /// The same window seen through ProcessManager: a preset Stop (the Shortcuts
    /// "Stop Watched App" path) that is cancelled as it is admitted must not
    /// unload agents or signal. Commands cancelled while queued or waiting for
    /// admission are rejected.
    func testPresetStopCancelledAsItIsAdmittedNeverUnloadsOrSignals() async {
        let target = batch03Process(pid: 4242, name: "Target")
        let world = Batch03World([target])
        let verification = Batch03BlockingInventory(world: world)
        let lifecycle = Batch03Lifecycle()
        let manager = ProcessManager(
            processInventory: world,
            verificationInventory: verification,
            processSignaler: Batch03Signaler(world: world),
            lifecycle: lifecycle,
            settleAfterProcessChange: {},
            currentPID: 999_999,
            dependencies: .inert
        )
        let box = Batch03StopBox()
        manager.enableNotifications = true
        // apply() is the owner's last synchronous step before the gate releases.
        manager.notifyTransitions = { _ in box.cancelPendingStop() }
        manager.primeNotificationBaseline = { _ in box.cancelPendingStop() }
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example",
            helperProcessNames: [], protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )

        let owner = Task { await manager.terminate(target) }
        await verification.waitUntilBlocked()
        box.stop = Task { await manager.quitAllKillable(preset) }
        for _ in 0..<500 where manager.operationState != .queued { await Task.yield() }
        XCTAssertEqual(manager.operationState, .queued)

        await verification.open()
        let ownerResult = await owner.value
        let stopResult = await box.stop!.value
        let calls = await lifecycle.calls
        XCTAssertEqual(ownerResult, .stopped)
        XCTAssertTrue(box.cancelIssued)
        XCTAssertEqual(stopResult.status, .rejected)
        XCTAssertFalse(calls.contains("agents.unload"), "cancelled Stop unloaded launch agents")
        XCTAssertFalse(calls.contains("terminate.main"), "cancelled Stop signalled the app")
    }

    /// A read that joined a queued read must be released when that queued read
    /// is cancelled, and then run its own work.
    func testJoinerOfCancelledQueuedReadRunsItsOwnWorkInsteadOfHanging() async {
        let gate = ProcessOperationGate()
        let latch = Batch03Latch()
        let box = Batch03GateBox()
        let owner = Task { await gate.run(kind: .mutation) { await latch.wait() } }
        for _ in 0..<500 where !gate.isMutationActive { await Task.yield() }
        let queuedRead = Task { await gate.run(kind: .read(.watchedStatus)) { box.log.append("queued read ran") } }
        for _ in 0..<500 where gate.state != .queued { await Task.yield() }
        XCTAssertEqual(gate.state, .queued)
        let joiner = Task { await gate.run(kind: .read(.watchedStatus)) { box.log.append("joiner ran") } }
        for _ in 0..<500 where gate.state != .coalesced { await Task.yield() }
        XCTAssertEqual(gate.state, .coalesced)

        queuedRead.cancel()
        let queuedRan = await queuedRead.value
        await latch.open()
        _ = await owner.value

        let timedOut = Batch03GateBox()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            timedOut.didTimeOut = true
            joiner.cancel()
        }
        let joinerRan = await joiner.value
        watchdog.cancel()
        XCTAssertFalse(queuedRan)
        XCTAssertFalse(timedOut.didTimeOut, "the joiner of a cancelled queued read never returned")
        XCTAssertTrue(joinerRan)
        XCTAssertEqual(box.log, ["joiner ran"])
        XCTAssertEqual(gate.state, .idle)
    }
}

@MainActor
final class Batch03GateBox {
    var queued: Task<Bool, Never>?
    var log: [String] = []
    var didTimeOut = false
}

@MainActor
final class Batch03StopBox {
    var stop: Task<TaskScopeCommandResult, Never>?
    var cancelIssued = false

    func cancelPendingStop() {
        guard !cancelIssued, let stop else { return }
        cancelIssued = true
        stop.cancel()
    }
}

actor Batch03Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// First load blocks until `open()`; later loads return the world at once.
actor Batch03BlockingInventory: ProcessInventoryProviding {
    private let world: Batch03World
    private var blockedOnce = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(world: Batch03World) { self.world = world }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if !blockedOnce {
            blockedOnce = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }
        return await world.load(fetchExtendedStats: fetchExtendedStats)
    }

    func waitUntilBlocked() async {
        if blockedOnce { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
