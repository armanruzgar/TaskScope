import XCTest
@testable import TaskScope

/// Covers the rule-lifecycle invariants around the auto-stop engine: an action must
/// fire only while its rule is still active, a retired rule must take its prompts
/// with it, and a stop that was never actually attempted must not be treated as
/// permanently handled.
@MainActor
final class AutoStopRuleLifecycleTests: XCTestCase {
    private var monotonicInstant = ContinuousClock.now
    private let examplePath = "/Applications/Example.app/Contents/MacOS/Example"
    private let suiteName = "TaskScope.AutoStopRuleLifecycleTests.\(UUID().uuidString)"
    private let key = "auto-stop-rules-lifecycle-tests"
    private let eventsKey = "auto-stop-events-lifecycle-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Disabling a rule while its prompt is on screen must retire that prompt.
    /// `update(_:)` cleared `handledOccurrences` but left `pendingPrompts`, so the
    /// alert for a switched-off rule stayed live and "Stop Now" still killed under it.
    func testDisablingARuleRetiresItsPendingPrompt() async {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
        store.add(rule)
        let stored = store.rules[0]

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1, "precondition: a prompt is queued")

        store.setEnabled(false, for: stored)

        XCTAssertTrue(store.pendingPrompts.isEmpty, "a disabled rule must not keep a live prompt")
        XCTAssertNil(store.currentPrompt)
    }

    /// Re-enabling must not resurrect an occurrence the user already disposed of by
    /// disabling the rule: the prompt is gone, so nothing should be actionable until
    /// the threshold is crossed again by a genuinely new evaluation.
    func testTogglingARuleOffAndOnDoesNotLeaveAStalePrompt() async {
        let store = makeStore()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        let stored = store.rules[0]

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1, "precondition: a prompt is queued")
        store.dismissCurrentPrompt()
        store.setEnabled(false, for: stored)
        store.setEnabled(true, for: store.rules[0])

        XCTAssertTrue(
            store.pendingPrompts.isEmpty,
            "toggling must not leave a duplicate of the prompt it already retired"
        )

        // A dismissed occurrence stays dismissed across the toggle: the process
        // is still over its threshold, but the user already answered for it.
        await store.evaluateNow()
        XCTAssertTrue(
            store.pendingPrompts.isEmpty,
            "a dismissed occurrence must not prompt again after the rule is toggled off and on"
        )
        XCTAssertEqual(store.events.map(\.outcome), [.dismissed])
    }

    func testDismissedPromptStillActsAfterChangingToAutoStopOrLogOnly() async {
        for action in [AutoStopRule.Action.kill, .silent] {
            defaults.removePersistentDomain(forName: suiteName)
            let store = makeStore()
            var rule = AutoStopRule(processName: "Example", executablePath: examplePath, runtimeMinutes: 1, action: .prompt)
            XCTAssertTrue(store.add(rule))
            var attempts = 0
            store.start { _, _ in
                attempts += 1
                return .stopped
            }
            store.stop()
            await store.evaluateNow()
            XCTAssertNotNil(store.currentPrompt)
            store.dismissCurrentPrompt()

            rule.action = action
            XCTAssertTrue(store.update(rule))
            await store.evaluateNow()
            await store.evaluateNow()

            XCTAssertEqual(attempts, action == .kill ? 1 : 0)
            XCTAssertEqual(store.events.map(\.outcome), [action == .kill ? .stopped : .logged, .dismissed])
            XCTAssertTrue(store.pendingPrompts.isEmpty)

            // Saving resets a Log Only rule's occurrences (it logs again), while
            // an unchanged Auto Stop rule retains its handled occurrence.
            XCTAssertTrue(store.update(rule))
            await store.evaluateNow()
            XCTAssertEqual(attempts, action == .kill ? 1 : 0, "An unchanged Auto Stop rule retains its handled occurrence")
            XCTAssertEqual(store.events.filter { $0.outcome == .logged }.count, action == .silent ? 2 : 0)
        }
    }

    /// A process that takes longer than the settle delay to exit used to be
    /// re-SIGTERMed on every tick and logged as "did not complete" each time.
    /// An accepted stop is now tracked until the identity disappears.
    func testAcceptedStopWhoseTargetHasNotExitedYetIsRecordedStoppedOnceItExits() async {
        let inventory = MutableStubInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .requestedStillRunning
        }
        await waitUntil { attempts == 1 && !store.events.isEmpty }
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])

        inventory.processes = []
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 1, "an accepted stop must not be re-signalled on the next tick")
        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested])
    }

    func testStillRunningTargetIsReSignalledOnceThenMarkedFailedWithoutFurtherRetries() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .requestedStillRunning
        }
        await waitUntil { attempts == 1 && !store.events.isEmpty }
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])

        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_600))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2, "one re-signal is allowed")
        XCTAssertEqual(store.events.map(\.outcome), [.failed, .stopRequested])

        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 2, "after the retry cap the process is not signalled again")
        XCTAssertEqual(store.events.count, 2, "the failure is recorded exactly once")
    }

    func testConfirmedPromptWhoseTargetHasNotExitedYetIsRecordedStoppedOnceItExits() async throws {
        let inventory = MutableStubInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .requestedStillRunning
        }
        store.stop()
        await store.evaluateNow()
        let prompt = try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt)))
        await store.finishStop(prompt)
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])

        await store.evaluateNow()
        XCTAssertEqual(attempts, 1, "a confirmed prompt is never re-signalled automatically")

        inventory.processes = []
        await store.evaluateNow()

        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested])
        XCTAssertTrue(store.pendingPrompts.isEmpty)
    }

    /// A rule edit restarts polling with an immediate tick while the previous
    /// evaluation may still be awaiting its inventory. Evaluations must not
    /// overlap, and the refused request must run once the pass finishes.
    func testConcurrentEvaluationsDoNotOverlapAndTheQueuedRequestRunsAfterwards() async {
        let inventory = BlockingLifecycleInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))

        let first = Task { await store.evaluateNow() }
        await inventory.waitForFirstLoad()
        await store.evaluateNow()
        let countWhileBlocked = await inventory.loadCount()
        XCTAssertEqual(countWhileBlocked, 1, "a second evaluation must not start while one is in flight")

        await inventory.releaseFirstLoad()
        await first.value

        let finalCount = await inventory.loadCount()
        XCTAssertEqual(finalCount, 2, "the refused evaluation must run after the first pass")
        XCTAssertEqual(store.pendingPrompts.count, 1, "the occurrence is prompted exactly once")
    }

    /// A `.kill` rule deleted while its handler is in flight must not go on acting.
    /// `evaluate` snapshots the active rules once and then awaits per process, so
    /// the rule has to be re-checked after the suspension.
    func testRuleDeletedWhileTheStopIsInFlightRecordsTheDeliveredStop() async {
        let store = makeStore(processes: [
            appProcess(pid: 41, elapsed: "10:00"),
            appProcess(pid: 42, elapsed: "10:00")
        ])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))
        let stored = store.rules[0]

        var handled: [Int32] = []
        store.start(cadence: 3_600) { _, process in
            handled.append(process.pid)
            // Delete the rule from inside the first in-flight action, exactly as a
            // Settings tap landing during the suspension would.
            store.remove(stored)
            return .stopped
        }

        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(handled, [41], "the second process must not be signalled under a deleted rule")
        XCTAssertEqual(store.events.map(\.outcome), [.stopped])
        XCTAssertEqual(store.events.first?.ruleID, stored.id)
        XCTAssertEqual(store.events.first?.processName, "Example")
        XCTAssertEqual(store.events.first?.pid, 41)
    }

    func testRetiredRuleRecordsDeliveredSignalsWithoutKeepingExitTracking() async {
        for retirement in ["edit", "disable", "delete"] {
            for result in [ProcessActionResult.stopped, .requestedStillRunning] {
                defaults.removePersistentDomain(forName: suiteName)
                let inventory = MutableStubInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
                let store = makeStore(inventory: inventory)
                store.add(AutoStopRule(processName: "Example", executablePath: examplePath, runtimeMinutes: 1, action: .kill))
                let stored = store.rules[0]
                var attempts = 0
                store.start(cadence: 3_600) { _, _ in
                    attempts += 1
                    switch retirement {
                    case "edit":
                        var edited = stored
                        edited.runtimeMinutes = 60
                        XCTAssertTrue(store.update(edited))
                    case "disable": XCTAssertTrue(store.setEnabled(false, for: stored))
                    default: store.remove(stored)
                    }
                    return result
                }

                await store.evaluateNow()
                await store.evaluateNow()
                inventory.processes = []
                await store.evaluateNow()
                store.stop()

                XCTAssertEqual(attempts, 1, retirement)
                XCTAssertEqual(store.events.map(\.outcome), [result == .stopped ? .stopped : .stopRequested], retirement)
                XCTAssertEqual(store.events.first?.ruleID, stored.id)
            }
        }
    }

    func testRetiredRuleDropsOutcomesWhenNothingWasSignalled() async {
        for result in [ProcessActionResult.rejected, .refused, .stale] {
            defaults.removePersistentDomain(forName: suiteName)
            let store = makeStore()
            store.add(AutoStopRule(processName: "Example", executablePath: examplePath, runtimeMinutes: 1, action: .kill))
            let stored = store.rules[0]
            var attempts = 0
            store.start(cadence: 3_600) { _, _ in
                attempts += 1
                store.remove(stored)
                return result
            }

            await store.evaluateNow()
            store.stop()

            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(store.events.isEmpty)
        }
    }

    func testRuleRetiredDuringRetryRecordsAStopRequestWithoutTrackingExit() async {
        let inventory = MutableStubInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", executablePath: examplePath, runtimeMinutes: 1, action: .kill))
        let stored = store.rules[0]
        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            if attempts == 2 { store.remove(stored) }
            return .requestedStillRunning
        }
        await waitUntil { attempts == 1 && !store.events.isEmpty }

        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_600))
        await store.evaluateNow()
        inventory.processes = []
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested, .stopRequested])
    }

    /// A stop that never happened (nothing was signalled) must stay retryable, and
    /// must not flood the log with one failure per tick while it keeps failing.
    func testUnattemptedStopIsRetriedButLoggedOnlyOnce() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .rejected
        }

        // `start` intentionally evaluates once before sleeping. Synchronize with that
        // real engine tick so the three explicit evaluations below cannot race it.
        for _ in 0..<100 where attempts == 0 || store.events.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(attempts, 1, "precondition: the engine performs its initial evaluation")
        XCTAssertEqual(store.events.count, 1, "precondition: the first failure is recorded")
        attempts = 0

        await store.evaluateNow()
        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 3, "a stop that was never attempted must be retried on later ticks")
        XCTAssertEqual(
            store.events.count,
            1,
            "a persistent failure must be logged once, not once per tick"
        )
        XCTAssertEqual(store.events.first?.outcome, .failed)
    }

    /// The counterpart: once the stop succeeds, the occurrence is done.
    func testSuccessfulStopIsRecordedAndNotRetried() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .stopped
        }

        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.events.map(\.outcome), [.stopped])
    }

    /// A signal the kernel refuses (EPERM on another user's process) can never
    /// succeed. It must be logged once and not retried on every tick.
    func testRefusedStopIsLoggedOnceAndNotRetried() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .refused
        }
        for _ in 0..<100 where attempts == 0 || store.events.isEmpty {
            await Task.yield()
        }

        await store.evaluateNow()
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 1, "a refused signal must not be re-attempted every tick")
        XCTAssertEqual(store.events.map(\.outcome), [.failed])
    }

    /// A process that exits between the engine's observation and the stop's
    /// identity check ended on its own; it is not a failed stop.
    func testStaleTargetIsRecordedAsEndedNotFailed() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .stale
        }
        for _ in 0..<100 where attempts == 0 || store.events.isEmpty {
            await Task.yield()
        }
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.events.map(\.outcome), [.processEnded])
    }

    /// After the single re-signal leaves the process running, a later exit is
    /// still recorded instead of being forgotten.
    func testExitAfterTheFailedRetryIsStillRecorded() async {
        let inventory = MutableAutoStopInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        ))

        var attempts = 0
        store.start(cadence: 3_600) { _, _ in
            attempts += 1
            return .requestedStillRunning
        }
        for _ in 0..<100 where attempts == 0 || store.events.isEmpty {
            await Task.yield()
        }
        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_600))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2, "precondition: one automatic re-signal")
        await inventory.set([])
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .failed, .stopRequested])
        XCTAssertEqual(store.events.first?.detail, "Exited after the stop request.")
    }

    /// A confirmed prompt whose stop never ran (unreadable process list) must
    /// prompt again rather than silently abandon a still-running process.
    func testConfirmedPromptThatCouldNotRunPromptsAgain() async {
        let store = makeStore(processes: [appProcess(pid: 41, elapsed: "10:00")])
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .prompt
        ))
        store.start(cadence: 3_600) { _, _ in .rejected }
        for _ in 0..<100 where store.currentPrompt == nil {
            await Task.yield()
        }
        guard let prompt = store.currentPrompt, let claimed = store.claimPrompt(prompt) else {
            return XCTFail("precondition: a prompt is queued")
        }

        await store.finishStop(claimed)
        await store.evaluateNow()
        store.stop()

        XCTAssertEqual(store.pendingPrompts.map(\.id), [prompt.id])
    }

    // MARK: - Helpers

    private func makeStore(
        processes: [AppProcess] = [appProcess(pid: 41, elapsed: "10:00")]
    ) -> AutoStopRulesStore {
        makeStore(inventory: StubInventory(processes: processes))
    }

    private func makeStore(inventory: any ProcessInventoryProviding) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: key,
            eventsKey: eventsKey,
            inventory: inventory,
            now: { Date(timeIntervalSince1970: 1_000) },
            monotonicNow: { self.monotonicInstant }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "condition was not met within \(timeout)s")
    }

}

private func appProcess(pid: Int32, elapsed: String) -> AppProcess {
    AppProcess(
        pid: pid,
        parentPID: 1,
        uid: getuid(),
        cpu: 1,
        memoryMB: 1,
        command: "Example",
        executablePath: "/Applications/Example.app/Contents/MacOS/Example",
        elapsedTime: elapsed,
        startTime: "start-\(pid)",
        netInKB: nil,
        netOutKB: nil,
        diskReadBytes: nil,
        diskWriteBytes: nil
    )
}

private struct StubInventory: ProcessInventoryProviding {
    let processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class MutableStubInventory: ProcessInventoryProviding, @unchecked Sendable {
    var processes: [AppProcess]

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

/// Blocks the first load until released; later loads return immediately.
private actor BlockingLifecycleInventory: ProcessInventoryProviding {
    private let processes: [AppProcess]
    private var count = 0
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        if count == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstLoadContinuation = $0 }
        }
        return .success(processes)
    }

    func waitForFirstLoad() async {
        guard count == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func loadCount() -> Int { count }
}

private actor MutableAutoStopInventory: ProcessInventoryProviding {
    private var processes: [AppProcess]

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func set(_ processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
