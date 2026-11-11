import ApplicationServices
import XCTest
@testable import TaskScope

/// SystemActivityMonitorAccessibilityRuntime's restoration timer, with fake
/// worker closures and an injected sleep.
@MainActor
final class Batch09ActivityMonitorRestorationTests: XCTestCase {
    // A03-4 and A03-3: a restore is scheduled whenever state was prepared,
    // including after a selection, and then keeps what shows the selected row.
    func testRestorationIsScheduledForPreparedStateAndKeepsTheSelectedRowVisible() async {
        let recorder = Batch09RestorationRecorder()
        let restored = expectation(description: "restoration ran")
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, _, _, _ in
                var state = ActivityMonitorPreparedTableState(searchValue: "chrome")
                state.searchValueSet = "logd"
                state.searchWasChanged = true
                state.processScopeChanged = true
                state.processIDWasShown = true
                return .init(attempt: .selected, preparedState: state)
            },
            restoration: { recorder.record($0); restored.fulfill() }
        )
        let runtime = SystemActivityMonitorAccessibilityRuntime(worker: worker, restorationDelayNanoseconds: 1_000_000)

        let attempt = await runtime.selectProcessRow(applicationPID: 500, targetPID: 1, timeout: 5)

        XCTAssertEqual(attempt, .selected)
        await fulfillment(of: [restored], timeout: 2)
        let state = recorder.states.first
        XCTAssertEqual(recorder.states.count, 1)
        XCTAssertEqual(state?.keepsSelectionVisible, true)
        XCTAssertEqual(state?.searchWasChanged, false, "the search that shows the selected row is kept")
        XCTAssertEqual(state?.processScopeChanged, false, "the scope that shows the selected row is kept")
        XCTAssertEqual(state?.processIDWasShown, true, "the PID column is still hidden again")
    }

    func testNoRestorationIsScheduledWithoutPreparedState() async {
        let sleeps = Batch09SleepRecorder()
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, _, _, _ in .init(attempt: .selected, preparedState: nil) },
            restoration: { _ in XCTFail("nothing was changed, so nothing may be restored") }
        )
        let runtime = SystemActivityMonitorAccessibilityRuntime(
            worker: worker, sleep: { duration in _ = await sleeps.record(duration) }
        )

        _ = await runtime.selectProcessRow(applicationPID: 500, targetPID: 1, timeout: 5)
        for _ in 0..<20 { await Task.yield() }

        let count = await sleeps.count
        XCTAssertEqual(count, 0)
    }

    func testANewerAttemptCancelsTheEarlierRestorationTimer() async throws {
        let sleeps = Batch09SleepRecorder()
        let restored = expectation(description: "restoration ran")
        let recorder = Batch09RestorationRecorder()
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, pid, _, _ in
                var state = ActivityMonitorPreparedTableState(searchValue: "original")
                state.searchValueSet = "target \(pid)"
                state.searchWasChanged = true
                return .init(attempt: .notReady, preparedState: state)
            },
            restoration: { recorder.record($0); restored.fulfill() }
        )
        let runtime = SystemActivityMonitorAccessibilityRuntime(
            worker: worker,
            sleep: { _ in
                // The first timer waits for a long time; the second fires at once.
                if await sleeps.record(0) == 1 {
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        await sleeps.markCancelled()
                        throw error
                    }
                }
            }
        )

        _ = await runtime.selectProcessRow(applicationPID: 500, targetPID: 1, timeout: 5)
        try await waitUntil { await sleeps.count == 1 }
        _ = await runtime.selectProcessRow(applicationPID: 500, targetPID: 2, timeout: 5)

        await fulfillment(of: [restored], timeout: 2)
        try await waitUntil { await sleeps.cancelled }
        XCTAssertEqual(recorder.states.map(\.searchValueSet), ["target 2"])
    }

    func testQuitTimeRestoreCancelsTheTimerAndRestoresAtOnce() async throws {
        let sleeps = Batch09SleepRecorder()
        let recorder = Batch09RestorationRecorder()
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { _, _, _, _ in
                var state = ActivityMonitorPreparedTableState(searchValue: "original")
                state.searchValueSet = "target"
                state.searchWasChanged = true
                return .init(attempt: .notReady, preparedState: state)
            },
            restoration: { recorder.record($0) }
        )
        let runtime = SystemActivityMonitorAccessibilityRuntime(
            worker: worker,
            sleep: { _ in
                _ = await sleeps.record(0)
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    await sleeps.markCancelled()
                    throw error
                }
            }
        )

        _ = await runtime.selectProcessRow(applicationPID: 500, targetPID: 1, timeout: 5)
        try await waitUntil { await sleeps.count == 1 }
        runtime.restorePreparedState()

        XCTAssertEqual(recorder.states.count, 1, "the quit-time restore is synchronous")
        try await waitUntil { await sleeps.cancelled }
        runtime.restorePreparedState()
        XCTAssertEqual(recorder.states.count, 1, "restored state is not restored twice")
    }

    // A03-5: state captured from one Activity Monitor process is not handed
    // to another one, such as a relaunched instance.
    func testStateFromAQuitActivityMonitorIsNotCarriedIntoANewInstance() async {
        let seen = Batch09ExistingStateRecorder()
        let worker = ActivityMonitorAccessibilityWorker(
            selection: { applicationPID, _, _, existing in
                seen.record(applicationPID: applicationPID, hadState: existing != nil)
                var state = existing ?? ActivityMonitorPreparedTableState(searchValue: "original")
                state.searchValueSet = "target"
                state.searchWasChanged = true
                return .init(attempt: .notReady, preparedState: state)
            },
            restoration: { _ in }
        )

        _ = await worker.selectOrPrepare(applicationPID: 100, targetPID: 1, processName: nil)
        _ = await worker.selectOrPrepare(applicationPID: 100, targetPID: 1, processName: nil)
        _ = await worker.selectOrPrepare(applicationPID: 200, targetPID: 1, processName: nil)

        XCTAssertEqual(seen.calls.map(\.hadState), [false, true, false])
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met in time", file: file, line: line)
    }
}

private final class Batch09RestorationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ActivityMonitorPreparedTableState] = []
    var states: [ActivityMonitorPreparedTableState] { lock.withLock { recorded } }
    func record(_ state: ActivityMonitorPreparedTableState) { lock.withLock { recorded.append(state) } }
}

private final class Batch09ExistingStateRecorder: @unchecked Sendable {
    struct Call { let applicationPID: pid_t; let hadState: Bool }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func record(applicationPID: pid_t, hadState: Bool) {
        lock.withLock { recorded.append(.init(applicationPID: applicationPID, hadState: hadState)) }
    }
}

private actor Batch09SleepRecorder {
    private(set) var count = 0
    private(set) var cancelled = false
    @discardableResult
    func record(_ duration: UInt64) -> Int {
        count += 1
        return count
    }
    func markCancelled() { cancelled = true }
}
