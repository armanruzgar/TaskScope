import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

// MARK: - Guards without other coverage (T04-12)

final class Batch07GuardTests: XCTestCase {
    private let cancelled = GlobalProtectDisconnectResult.failed("GlobalProtect shutdown was cancelled before its services were stopped.")

    // T04-12 (2): a cancelled disconnect neither reads nor presses.
    func testAPreCancelledDisconnectNeitherReadsNorPresses() async {
        let runtime = Batch07DisconnectRuntime(firstState: .connected, suspendsFirstRead: false)
        let task = Task { () -> GlobalProtectDisconnectResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await GlobalProtectDisconnectController.disconnect(using: runtime)
        }
        let result = await task.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(runtime.counts.reads, 0)
        XCTAssertEqual(runtime.counts.presses, 0)
    }

    // T04-12 (2): cancelled while waiting for an observation, it stops at the
    // next check instead of reporting a disconnect.
    func testCancellingDuringAnObservationStopsBeforeReportingDisconnected() async {
        let runtime = Batch07DisconnectRuntime(firstState: .disconnected, suspendsFirstRead: true)
        let task = Task { await GlobalProtectDisconnectController.disconnect(using: runtime) }
        await runtime.waitForFirstRead()
        task.cancel()
        runtime.resumeFirstRead()
        let result = await task.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(runtime.counts.reads, 1)
        XCTAssertEqual(runtime.counts.presses, 0)
    }

    // T04-12 (3): launchd's own PID is never taken for a job's PID.
    func testLaunchdPIDOneIsNeverAJobPID() {
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID("system/com.paloaltonetworks.gp.pangpsd = {\n\tpid = 1\n}"))
        XCTAssertEqual(GlobalProtectCompatibilityChecker.topLevelPID("system/com.paloaltonetworks.gp.pangpsd = {\n\tpid = 2\n}"), 2)
        XCTAssertNil(ProcessLifecycleController.launchJobPID(from: ShellCommandResult(
            command: "fixture", stdout: "gui/501/com.example.agent = {\n\tpid = 1\n}", stderr: "", exitCode: 0
        )))
    }
}

// MARK: - Fakes

/// Never touches the vendor interface. The first read can be held open so a
/// test can cancel the disconnect while it waits for an observation.
private final class Batch07DisconnectRuntime: GlobalProtectDisconnectRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let firstState: GlobalProtectConnectionState
    private let suspendsFirstRead: Bool
    private var reads = 0
    private var presses = 0
    private var firstReadStarted = false
    private var pendingRead: CheckedContinuation<GlobalProtectConnectionState, Never>?
    private var firstReadWaiter: CheckedContinuation<Void, Never>?

    init(firstState: GlobalProtectConnectionState, suspendsFirstRead: Bool) {
        self.firstState = firstState
        self.suspendsFirstRead = suspendsFirstRead
    }

    var counts: (reads: Int, presses: Int) { lock.withLock { (reads, presses) } }

    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState {
        let isFirst: Bool = lock.withLock {
            reads += 1
            return reads == 1
        }
        guard isFirst, suspendsFirstRead else { return isFirst ? firstState : .disconnected }
        return await withCheckedContinuation { continuation in
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                pendingRead = continuation
                firstReadStarted = true
                defer { firstReadWaiter = nil }
                return firstReadWaiter
            }
            waiter?.resume()
        }
    }

    func waitForFirstRead() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let started: Bool = lock.withLock {
                if firstReadStarted { return true }
                firstReadWaiter = continuation
                return false
            }
            if started { continuation.resume() }
        }
    }

    func resumeFirstRead() {
        let continuation: CheckedContinuation<GlobalProtectConnectionState, Never>? = lock.withLock {
            defer { pendingRead = nil }
            return pendingRead
        }
        continuation?.resume(returning: firstState)
    }

    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectDisconnectPressResult {
        lock.withLock { presses += 1 }
        return .pressed
    }

    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async {}
}
