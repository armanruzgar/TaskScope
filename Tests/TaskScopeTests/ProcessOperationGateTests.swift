import XCTest
@testable import TaskScope

@MainActor
final class ProcessOperationGateTests: XCTestCase {
    func testEquivalentReadJoinsMatchingReadUntilItCompletes() async {
        let blocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let active = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await blocker.block()
            }
        }
        await blocker.waitUntilBlocked()

        let duplicate = Task {
            let ran = await gate.run(kind: .read(.watchedStatus)) {
                await recorder.record("duplicate operation")
            }
            await recorder.record("duplicate returned")
            return ran
        }
        for _ in 0..<100 where gate.state != .coalesced {
            await Task.yield()
        }

        XCTAssertEqual(gate.state, .coalesced)
        let valuesWhileBlocked = await recorder.values()
        XCTAssertEqual(valuesWhileBlocked, [])
        await blocker.release()
        let activeRan = await active.value
        let duplicateRan = await duplicate.value
        let finalValues = await recorder.values()
        XCTAssertTrue(activeRan)
        XCTAssertFalse(duplicateRan)
        XCTAssertEqual(finalValues, ["duplicate returned"])
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.isWorking)
    }

    /// `state` shows the latest queue activity, so a read queued behind a
    /// running mutation replaces `.runningMutation`. Logic that must not queue
    /// behind a user mutation relies on `isMutationActive` instead.
    func testMutationStaysActiveWhileAReadQueuesBehindIt() async {
        let blocker = OperationGateBlocker()
        let gate = ProcessOperationGate()

        let mutation = Task {
            await gate.run(kind: .mutation) {
                await blocker.block()
            }
        }
        await blocker.waitUntilBlocked()
        let read = Task {
            await gate.run(kind: .read(.processList)) {}
        }
        for _ in 0..<100 where gate.state != .queued {
            await Task.yield()
        }

        XCTAssertEqual(gate.state, .queued)
        XCTAssertTrue(gate.isMutationActive)
        await blocker.release()
        _ = await mutation.value
        _ = await read.value
        XCTAssertFalse(gate.isMutationActive)
    }

    func testEquivalentReadJoinsMatchingQueuedRead() async {
        let activeBlocker = OperationGateBlocker()
        let queuedBlocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let active = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await activeBlocker.block()
            }
        }
        await activeBlocker.waitUntilBlocked()

        let queued = Task {
            await gate.run(kind: .read(.processList)) {
                await recorder.record("queued operation")
                await queuedBlocker.block()
            }
        }
        for _ in 0..<100 where gate.state != .queued {
            await Task.yield()
        }

        let duplicate = Task {
            let ran = await gate.run(kind: .read(.processList)) {
                await recorder.record("duplicate operation")
            }
            await recorder.record("duplicate returned")
            return ran
        }
        for _ in 0..<100 where gate.state != .coalesced {
            await Task.yield()
        }

        await activeBlocker.release()
        await queuedBlocker.waitUntilBlocked()
        let valuesWhileQueuedReadRuns = await recorder.values()
        XCTAssertEqual(valuesWhileQueuedReadRuns, ["queued operation"])

        await queuedBlocker.release()
        let activeRan = await active.value
        let queuedRan = await queued.value
        let duplicateRan = await duplicate.value
        let finalValues = await recorder.values()
        XCTAssertTrue(activeRan)
        XCTAssertTrue(queuedRan)
        XCTAssertFalse(duplicateRan)
        XCTAssertEqual(finalValues, ["queued operation", "duplicate returned"])
        XCTAssertEqual(gate.state, .idle)
    }

    func testCancellingJoinedReadDoesNotCancelActiveRead() async {
        let blocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let active = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await blocker.block()
                await recorder.record("active completed")
            }
        }
        await blocker.waitUntilBlocked()

        let duplicate = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await recorder.record("duplicate operation")
            }
        }
        for _ in 0..<100 where gate.state != .coalesced {
            await Task.yield()
        }

        duplicate.cancel()
        let duplicateRan = await duplicate.value
        XCTAssertFalse(duplicateRan)
        XCTAssertTrue(gate.isWorking)
        await blocker.release()

        let activeRan = await active.value
        let values = await recorder.values()
        XCTAssertTrue(activeRan)
        XCTAssertEqual(values, ["active completed"])
        XCTAssertEqual(gate.state, .idle)
    }

    func testMutationRunsBeforeQueuedRead() async {
        let blocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let active = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await blocker.block()
            }
        }
        await blocker.waitUntilBlocked()

        let queuedRead = Task {
            await gate.run(kind: .read(.processList)) {
                await recorder.record("read")
            }
        }
        let queuedMutation = Task {
            await gate.run(kind: .mutation) {
                await recorder.record("mutation")
            }
        }
        await Task.yield()

        await blocker.release()
        let activeRan = await active.value
        let mutationRan = await queuedMutation.value
        let readRan = await queuedRead.value
        let values = await recorder.values()
        XCTAssertTrue(activeRan)
        XCTAssertTrue(mutationRan)
        XCTAssertTrue(readRan)
        XCTAssertEqual(values, ["mutation", "read"])
        XCTAssertEqual(gate.state, .idle)
    }

    /// A joiner must not be told the read completed when its owner was
    /// cancelled mid-run; it runs its own work instead.
    func testJoinerOfOwnerCancelledMidRunRunsItsOwnWork() async {
        let blocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let owner = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await blocker.block()
                await recorder.record("owner finished")
            }
        }
        await blocker.waitUntilBlocked()

        let joiner = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await recorder.record("joiner operation")
            }
        }
        for _ in 0..<100 where gate.state != .coalesced {
            await Task.yield()
        }
        XCTAssertEqual(gate.state, .coalesced)

        owner.cancel()
        await blocker.release()

        let ownerRan = await owner.value
        let joinerRan = await joiner.value
        let values = await recorder.values()
        XCTAssertTrue(ownerRan)
        XCTAssertTrue(joinerRan)
        XCTAssertEqual(values, ["owner finished", "joiner operation"])
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.isWorking)
    }

    func testCancelledWaiterNeverRunsAndGateReturnsToIdle() async {
        let blocker = OperationGateBlocker()
        let recorder = OperationGateRecorder()
        let gate = ProcessOperationGate()

        let active = Task {
            await gate.run(kind: .read(.watchedStatus)) {
                await blocker.block()
            }
        }
        await blocker.waitUntilBlocked()

        let queued = Task {
            await gate.run(kind: .read(.processList)) {
                await recorder.record("cancelled read")
            }
        }
        await Task.yield()
        queued.cancel()
        await blocker.release()

        let activeRan = await active.value
        let queuedRan = await queued.value
        let values = await recorder.values()
        XCTAssertTrue(activeRan)
        XCTAssertFalse(queuedRan)
        XCTAssertEqual(values, [])
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.isWorking)
    }
}

private actor OperationGateBlocker {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func block() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor OperationGateRecorder {
    private var recordedValues: [String] = []

    func record(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}
