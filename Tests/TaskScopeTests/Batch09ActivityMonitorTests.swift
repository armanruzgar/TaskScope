import ApplicationServices
import XCTest
@testable import TaskScope

/// Activity Monitor handoff fixes. Nothing here opens or drives the real
/// Activity Monitor: the coordinator gets fake openers and selectors, and the
/// worker's Accessibility traversal runs against an in-memory element tree.
@MainActor
final class Batch09ActivityMonitorCoordinatorTests: XCTestCase {
    // A04-1: the inventory stores /tmp/x and /var/x for binaries whose kernel
    // path is /private/tmp/x or /private/var/x.
    func testIdentityCheckAcceptsTheKernelPrivatePathOfAStandardizedInventoryPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Batch09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("tool")
        try Data("fixture".utf8).write(to: binary)

        let standardized = binary.standardizedFileURL.path
        guard standardized.hasPrefix("/var/") || standardized.hasPrefix("/tmp/") else {
            throw XCTSkip("The temporary directory is not below /private.")
        }
        let kernelPath = "/private" + standardized
        // What ProcessListReader.attachExecutablePaths stores for that kernel path.
        let inventoryPath = URL(fileURLWithPath: kernelPath).standardizedFileURL.path
        XCTAssertNotEqual(kernelPath, inventoryPath, "precondition: the inventory drops /private")

        let identity = ProcessIdentity(
            pid: 4242, startTime: "Sun Sep 13 12:26:40 2020", command: "tool", executablePath: inventoryPath
        )
        let checker = SystemActivityMonitorProcessChecker(
            readStartTime: { _ in (1_600_000_000, 0) },
            executablePathForPID: { _ in kernelPath }
        )
        XCTAssertTrue(checker.processMatches(identity: identity))

        let replaced = SystemActivityMonitorProcessChecker(
            readStartTime: { _ in (1_600_000_000, 0) },
            executablePathForPID: { _ in kernelPath + "-replacement" }
        )
        XCTAssertFalse(replaced.processMatches(identity: identity), "a different file must still be refused")
    }

    // A03-2: a second handoff waits for the first instead of fighting over
    // Activity Monitor's search field between retries.
    func testOverlappingHandoffsRunOneAfterAnother() async {
        let selector = Batch09GatedSelector()
        let opener = Batch09CountingOpener()
        let coordinator = ActivityMonitorCoordinator(
            opener: opener, processChecker: Batch09MatchingChecker(), selector: selector,
            maximumSelectionAttempts: 2, retryDelayNanoseconds: 0, sleep: { _ in }
        )
        let firstStarted = expectation(description: "first handoff selecting")
        selector.onStart = { pid in if pid == 1 { firstStarted.fulfill() } }

        let first = Task { await coordinator.openAndSelect(identity: Self.identity(1)) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task { await coordinator.openAndSelect(identity: Self.identity(2)) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(selector.events, ["start 1"], "the second handoff must not start while the first runs")
        XCTAssertEqual(opener.openCount, 1)

        selector.release()
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        XCTAssertEqual(firstOutcome, .success)
        XCTAssertEqual(secondOutcome, .success)
        XCTAssertEqual(selector.events, ["start 1", "end 1", "start 2", "end 2"])
        XCTAssertEqual(opener.openCount, 2)
    }

    // A03-7: an unresponsive Activity Monitor is bounded by wall-clock time,
    // each attempt gets only the remaining budget, and the reason is reported.
    func testUnresponsiveActivityMonitorStopsAtTheTimeBudget() async {
        var clock: TimeInterval = 100
        let selector = Batch09ScriptedSelector(results: Array(repeating: .unresponsive, count: 8))
        selector.onSelect = { clock += 1 }
        let coordinator = ActivityMonitorCoordinator(
            opener: Batch09CountingOpener(onOpen: { clock += 30 }),
            processChecker: Batch09MatchingChecker(), selector: selector,
            maximumSelectionAttempts: 8, retryDelayNanoseconds: 0,
            selectionTimeBudget: 3, now: { clock }, sleep: { _ in }
        )

        let outcome = await coordinator.openAndSelect(identity: Self.identity(7))

        XCTAssertEqual(outcome, .timedOut(lastError: ActivityMonitorCoordinator.notRespondingMessage))
        XCTAssertEqual(selector.timeouts, [3, 2, 1], "the budget starts after the open and shrinks per attempt")
        XCTAssertTrue(outcome.message(for: 7).contains("Activity Monitor is not responding."))
    }

    func testAnUnresponsiveAttemptIsRetriedWithinTheBudget() async {
        let selector = Batch09ScriptedSelector(results: [.unresponsive, .selected])
        let coordinator = ActivityMonitorCoordinator(
            opener: Batch09CountingOpener(), processChecker: Batch09MatchingChecker(), selector: selector,
            maximumSelectionAttempts: 3, retryDelayNanoseconds: 0, sleep: { _ in }
        )

        let outcome = await coordinator.openAndSelect(identity: Self.identity(8))

        XCTAssertEqual(outcome, .success, "a cold or briefly busy Activity Monitor must not end the handoff")
        XCTAssertEqual(selector.timeouts.count, 2)
    }

    func testCancelledHandoffStopsWithoutSelecting() async {
        let selector = Batch09ScriptedSelector(results: [.selected])
        let coordinator = ActivityMonitorCoordinator(
            opener: Batch09CountingOpener(), processChecker: Batch09MatchingChecker(), selector: selector,
            retryDelayNanoseconds: 0, sleep: { _ in }
        )
        let handoff = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.openAndSelect(identity: Self.identity(9))
        }

        let outcome = await handoff.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(selector.timeouts.isEmpty)
        XCTAssertEqual(outcome.message(for: 9), "Selecting PID 9 in Activity Monitor was cancelled.")
    }

    // A03-4: the app's termination work restores Activity Monitor.
    func testTerminationCleanupRestoresActivityMonitor() {
        var events: [String] = []
        let coordinator = Batch09RestoringCoordinator { events.append("restore") }
        TaskScopeTerminationCleanup(activityMonitor: coordinator).perform()
        XCTAssertEqual(events, ["restore"])
    }

    // A03-8: only the Activity Monitor in /System, running its own executable,
    // is driven, even when a look-alike reports the same bundle identifier.
    func testOnlyTheSystemActivityMonitorInstanceIsDriven() {
        typealias Candidate = SystemActivityMonitorAccessibilityRuntime.ApplicationCandidate
        let system = SystemActivityMonitorAccessibilityRuntime.applicationPath
        let systemExecutable = SystemActivityMonitorAccessibilityRuntime.executablePath
        let paths: [pid_t: String] = [
            10: "/Users/someone/Downloads/Activity Monitor.app/Contents/MacOS/Activity Monitor",
            11: systemExecutable,
            12: "/private/tmp/Impostor",
            13: systemExecutable
        ]
        let candidates = [
            Candidate(pid: 10, bundlePath: "/Users/someone/Downloads/Activity Monitor.app", isTerminated: false),
            Candidate(pid: 11, bundlePath: system, isTerminated: true),
            Candidate(pid: 12, bundlePath: system, isTerminated: false),
            Candidate(pid: 13, bundlePath: system, isTerminated: false)
        ]

        XCTAssertEqual(
            SystemActivityMonitorAccessibilityRuntime.systemActivityMonitorPID(
                in: candidates, executablePath: { paths[$0] }
            ),
            13
        )
        XCTAssertNil(
            SystemActivityMonitorAccessibilityRuntime.systemActivityMonitorPID(
                in: Array(candidates.prefix(3)), executablePath: { paths[$0] }
            ),
            "a look-alike must never be driven"
        )
    }

    // A03-6: root-owned and other users' processes have no proc_name for this
    // user, but their kernel executable path gives the name to search for.
    func testSearchNameFallsBackToTheExecutableFileName() {
        typealias Runtime = SystemActivityMonitorAccessibilityRuntime
        XCTAssertEqual(
            Runtime.searchName(localizedName: nil, kernelName: nil, executablePath: { "/usr/libexec/logd" }),
            "logd"
        )
        XCTAssertEqual(
            Runtime.searchName(localizedName: " Safari ", kernelName: "com.apple.WebKit", executablePath: { nil }),
            "Safari"
        )
        XCTAssertEqual(
            Runtime.searchName(localizedName: "  ", kernelName: "launchd", executablePath: { "/sbin/launchd" }),
            "launchd"
        )
        XCTAssertNil(Runtime.searchName(localizedName: nil, kernelName: nil, executablePath: { nil }))
    }

    // T05-7: the NSNumber branch of the PID-cell matcher.
    func testPIDCellMatcherComparesNumericCellsExactly() {
        XCTAssertTrue(ActivityMonitorPIDCellMatcher.matches(value: NSNumber(value: 21_081), targetPID: 21_081))
        XCTAssertFalse(ActivityMonitorPIDCellMatcher.matches(value: NSNumber(value: 121_081), targetPID: 21_081))
        XCTAssertFalse(ActivityMonitorPIDCellMatcher.matches(value: NSNumber(value: 2_108), targetPID: 21_081))
        XCTAssertFalse(ActivityMonitorPIDCellMatcher.matches(value: NSNumber(value: 0), targetPID: 21_081))
        XCTAssertFalse(ActivityMonitorPIDCellMatcher.matches(value: nil, targetPID: 21_081))
        XCTAssertFalse(ActivityMonitorPIDCellMatcher.matches(value: NSDate(), targetPID: 21_081))
    }

    static func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: "fixture", command: "fixture", executablePath: "/fixture")
    }
}

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

/// The worker's Accessibility traversal against an in-memory Activity Monitor.
@MainActor
final class Batch09ActivityMonitorTraversalTests: XCTestCase {
    private let target = Batch09FakeActivityMonitor.Process(pid: 1, name: "launchd", mine: false)
    private let mine = Batch09FakeActivityMonitor.Process(pid: 4321, name: "Safari", mine: true)

    func testVisibleRowIsSelectedWithoutChangingTheTable() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")

        XCTAssertEqual(outcome.attempt, .selected)
        XCTAssertNil(outcome.preparedState)
        XCTAssertEqual(monitor.selectedPID, 1)
        XCTAssertTrue(monitor.requestTimeouts.allSatisfy { $0 > 0 && $0 <= 1 }, "\(monitor.requestTimeouts)")
    }

    // A03-3: the handoff widened the scope, showed the PID column and replaced
    // the search. After it selected the row, restoration hides the PID column
    // again but keeps the scope and search, so the row stays listed.
    func testRestorationAfterASelectionKeepsTheRowListed() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let prepared = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(prepared.attempt, .notReady)
        XCTAssertEqual(monitor.scope, .all)
        XCTAssertTrue(monitor.pidColumnVisible)
        XCTAssertEqual(monitor.search, "launchd")

        let selected = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(selected.attempt, .selected)
        XCTAssertEqual(monitor.selectedPID, 1)

        worker.restoreNow()

        XCTAssertFalse(monitor.pidColumnVisible, "the PID column is hidden again")
        XCTAssertEqual(monitor.scope, .all, "My Processes would hide the selected root-owned row")
        XCTAssertEqual(monitor.search, "launchd", "the old search would hide the selected row")
        XCTAssertTrue(monitor.listedPIDs.contains(1))
    }

    func testRestorationAfterAFailedHandoffPutsEverythingBack() async {
        let absent = Batch09FakeActivityMonitor.Process(pid: 77, name: "ghost", mine: false)
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let first = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)
        let second = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)
        XCTAssertEqual(first.attempt, .notReady)
        XCTAssertEqual(second.attempt, .notReady)

        worker.restoreNow()

        XCTAssertEqual(monitor.scope, .mine)
        XCTAssertFalse(monitor.pidColumnVisible)
        XCTAssertEqual(monitor.search, "chrome")
    }

    func testRestorationLeavesASearchTheUserChangedAfterTheHandoff() async {
        let absent = Batch09FakeActivityMonitor.Process(pid: 77, name: "ghost", mine: false)
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)
        _ = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)

        monitor.userTypesSearch("mail")
        worker.restoreNow()

        XCTAssertEqual(monitor.search, "mail", "the user's own search wins")
        XCTAssertEqual(monitor.scope, .mine, "fields the user did not touch are still restored")
        XCTAssertFalse(monitor.pidColumnVisible)
    }

    // A03-6: without any name for the target, a stale search is cleared
    // instead of being left to hide the row.
    func testUnknownNameClearsAStaleSearch() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .all, pidColumnVisible: true, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let prepared = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: nil)
        XCTAssertEqual(prepared.attempt, .notReady)
        XCTAssertEqual(monitor.search, "")

        let selected = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: nil)
        XCTAssertEqual(selected.attempt, .selected)
        XCTAssertEqual(monitor.selectedPID, 1)
    }

    // A03-7: a request that cannot complete ends the attempt at once instead
    // of every further request waiting out its own timeout, and the attempt
    // reports that Activity Monitor is not responding.
    func testUnresponsiveActivityMonitorEndsTheAttemptAfterOneRequest() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        monitor.isResponding = false
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")

        XCTAssertEqual(outcome.attempt, .unresponsive)
        XCTAssertEqual(monitor.requestCount, 1)
        XCTAssertEqual(monitor.requestTimeouts, [1])
    }

    func testAnUnresponsiveAttemptKeepsStateFromEarlierAttempts() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: true, search: ""
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)
        _ = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(monitor.scope, .all)

        monitor.isResponding = false
        let stalled = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(stalled.attempt, .unresponsive)
        XCTAssertNotNil(stalled.preparedState, "what the handoff changed must still be restorable")

        monitor.isResponding = true
        worker.restoreNow()
        XCTAssertEqual(monitor.scope, .mine)
        XCTAssertEqual(monitor.search, "")
    }

    func testTheAttemptDeadlineBoundsEveryRequest() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(
            applicationPID: 900, targetPID: 1, processName: "launchd", timeout: 0.25
        )

        XCTAssertEqual(outcome.attempt, .selected)
        XCTAssertFalse(monitor.requestTimeouts.isEmpty)
        XCTAssertTrue(monitor.requestTimeouts.allSatisfy { $0 > 0 && $0 <= 0.25 }, "\(monitor.requestTimeouts)")

        let expired = await worker.selectOrPrepare(
            applicationPID: 900, targetPID: 1, processName: "launchd", timeout: 0
        )
        XCTAssertEqual(expired.attempt, .notReady, "an exhausted budget makes no requests")
    }
}

// MARK: - Fakes

@MainActor
private final class Batch09CountingOpener: ActivityMonitorOpening {
    private(set) var openCount = 0
    private let onOpen: () -> Void
    init(onOpen: @escaping () -> Void = {}) { self.onOpen = onOpen }
    func open() async throws {
        openCount += 1
        onOpen()
    }
}

@MainActor
private struct Batch09MatchingChecker: ActivityMonitorProcessChecking {
    func processMatches(identity: ProcessIdentity) -> Bool { true }
}

@MainActor
private final class Batch09ScriptedSelector: ActivityMonitorProcessSelecting {
    private var results: [ActivityMonitorSelectionAttempt]
    private(set) var timeouts: [TimeInterval] = []
    var onSelect: () -> Void = {}
    init(results: [ActivityMonitorSelectionAttempt]) { self.results = results }
    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        timeouts.append(timeout)
        onSelect()
        return results.isEmpty ? .notReady : results.removeFirst()
    }
}

/// Holds the first handoff's selection until the test releases it.
@MainActor
private final class Batch09GatedSelector: ActivityMonitorProcessSelecting {
    private(set) var events: [String] = []
    var onStart: (Int32) -> Void = { _ in }
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        events.append("start \(pid)")
        onStart(pid)
        if pid == 1, !released {
            await withCheckedContinuation { gate = $0 }
        }
        events.append("end \(pid)")
        return .selected
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}

@MainActor
private struct Batch09RestoringCoordinator: ActivityMonitorCoordinating {
    let onRestore: () -> Void
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome { .missingProcess }
    func restoreActivityMonitorState() { onRestore() }
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

/// An in-memory Activity Monitor: a window with a search field and a process
/// outline, and a View menu with the Columns submenu and the process scopes.
/// Elements are application elements for made-up PIDs, used only as tokens:
/// no request ever reaches the Accessibility API.
final class Batch09FakeActivityMonitor: ActivityMonitorAXTransport, @unchecked Sendable {
    struct Process: Equatable {
        let pid: Int32
        let name: String
        let mine: Bool
    }

    enum Scope { case mine, all }

    private enum Node: Hashable {
        case application, window, searchField, outline
        case column(Int), row(Int32), cell(Int32, Int)
        case menuBar, fileMenuBarItem, fileMenu, fileFirstItem
        case viewMenuBarItem, viewMenu, columnsItem, columnsSubmenu, columnItem(Int)
        case separator(Int), myProcessesItem, allProcessesItem
    }

    private let lock = NSLock()
    private let processes: [Process]
    private var _scope: Scope
    private var _pidColumnVisible: Bool
    private var _search: String
    private var _selectedPID: Int32?
    private var _isResponding = true
    private var _windowsReady = true
    private var _requestCount = 0
    private var _requestTimeouts: [Float] = []
    private var nodes: [pid_t: Node] = [:]
    private var tokens: [Node: pid_t] = [:]
    private static let columnTitles = ["Process Name", "% CPU", "CPU Time", "Threads", "Idle Wake Ups", "Kind",
                                       "% GPU", "GPU Time", "PID", "User", "Ports", "Memory", "Real Memory",
                                       "Purgeable Memory", "Compressed Memory", "Sudden Termination", "Sandbox",
                                       "Restricted", "Preventing Sleep", "App Nap"]

    init(processes: [Process], scope: Scope, pidColumnVisible: Bool, search: String = "") {
        self.processes = processes
        _scope = scope
        _pidColumnVisible = pidColumnVisible
        _search = search
    }

    var scope: Scope { lock.withLock { _scope } }
    var pidColumnVisible: Bool { lock.withLock { _pidColumnVisible } }
    var search: String { lock.withLock { _search } }
    var selectedPID: Int32? { lock.withLock { _selectedPID } }
    var requestCount: Int { lock.withLock { _requestCount } }
    var requestTimeouts: [Float] { lock.withLock { _requestTimeouts } }
    var listedPIDs: [Int32] { lock.withLock { visibleProcesses().map(\.pid) } }
    var isResponding: Bool {
        get { lock.withLock { _isResponding } }
        set { lock.withLock { _isResponding = newValue } }
    }
    /// False models a cold launch whose menus exist before its window does.
    var windowsReady: Bool {
        get { lock.withLock { _windowsReady } }
        set { lock.withLock { _windowsReady = newValue } }
    }

    func userTypesSearch(_ text: String) {
        lock.withLock { _search = text }
    }

    // MARK: ActivityMonitorAXTransport

    func applicationElement(pid: pid_t) -> AXUIElement {
        lock.withLock { element(.application) }
    }

    func setTimeout(_ element: AXUIElement, seconds: Float) {
        lock.withLock { _requestTimeouts.append(seconds) }
    }

    func copyAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            guard let node = node(for: element),
                  let result = attributeValue(node, attribute as String) else { return .noValue }
            value = result
            return .success
        }
    }

    func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            switch (node(for: element), attribute as String) {
            case (.searchField?, kAXValueAttribute):
                _search = (value as? String) ?? ""
                return .success
            case (.outline?, kAXSelectedRowsAttribute):
                guard let rows = value as? [AXUIElement], rows.count == 1,
                      case .row(let pid)? = node(for: rows[0]) else { return .illegalArgument }
                _selectedPID = pid
                return .success
            default:
                return .attributeUnsupported
            }
        }
    }

    func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            switch (node(for: element), action as String) {
            case (.allProcessesItem?, kAXPressAction):
                _scope = .all
            case (.myProcessesItem?, kAXPressAction):
                _scope = .mine
            case (.columnItem(let index)?, kAXPressAction) where Self.columnTitles[index] == "PID":
                _pidColumnVisible.toggle()
            case (.searchField?, kAXConfirmAction):
                break
            default:
                return .actionUnsupported
            }
            return .success
        }
    }

    // MARK: Model (called with the lock held)

    private func visibleProcesses() -> [Process] {
        processes.filter { process in
            (_scope == .all || process.mine)
                && (_search.isEmpty || process.name.localizedCaseInsensitiveContains(_search))
        }
    }

    private var visibleColumns: [String] {
        _pidColumnVisible ? ["Command", "PID"] : ["Command"]
    }

    private func attributeValue(_ node: Node, _ attribute: String) -> CFTypeRef? {
        switch (node, attribute) {
        case (.application, kAXWindowsAttribute): return elements(_windowsReady ? [.window] : [])
        case (.application, kAXMainWindowAttribute): return _windowsReady ? element(.window) : nil
        case (.application, kAXMenuBarAttribute): return element(.menuBar)
        case (.window, kAXRoleAttribute): return kAXWindowRole as CFString
        case (.window, kAXChildrenAttribute): return elements([.searchField, .outline])
        case (.searchField, kAXRoleAttribute): return kAXTextFieldRole as CFString
        case (.searchField, kAXSubroleAttribute): return kAXSearchFieldSubrole as CFString
        case (.searchField, kAXValueAttribute): return _search as CFString
        case (.outline, kAXRoleAttribute): return kAXOutlineRole as CFString
        case (.outline, kAXColumnsAttribute): return elements(visibleColumns.indices.map { .column($0) })
        case (.outline, kAXRowsAttribute): return elements(visibleProcesses().map { .row($0.pid) })
        case (.column(let index), kAXIdentifierAttribute): return visibleColumns[index] as CFString
        case (.row(let pid), kAXChildrenAttribute): return elements(visibleColumns.indices.map { .cell(pid, $0) })
        case (.cell(_, let column), kAXColumnIndexRangeAttribute):
            var range = CFRange(location: column, length: 1)
            return AXValueCreate(.cfRange, &range)
        case (.cell(let pid, let column), kAXValueAttribute):
            guard visibleColumns.indices.contains(column),
                  let process = processes.first(where: { $0.pid == pid }) else { return nil }
            return (visibleColumns[column] == "PID" ? String(pid) : process.name) as CFString
        case (.menuBar, kAXChildrenAttribute): return elements([.fileMenuBarItem, .viewMenuBarItem])
        case (.fileMenuBarItem, kAXChildrenAttribute): return elements([.fileMenu])
        case (.fileMenu, kAXChildrenAttribute): return elements([.fileFirstItem])
        case (.viewMenuBarItem, kAXChildrenAttribute): return elements([.viewMenu])
        case (.viewMenu, kAXChildrenAttribute):
            return elements([.columnsItem, .separator(0), .myProcessesItem, .allProcessesItem, .separator(1)])
        case (.columnsItem, kAXChildrenAttribute): return elements([.columnsSubmenu])
        case (.columnsSubmenu, kAXChildrenAttribute):
            return elements(Self.columnTitles.indices.map { .columnItem($0) })
        case (.columnsItem, kAXTitleAttribute): return "Columns" as CFString
        case (.separator, kAXTitleAttribute): return "" as CFString
        case (.myProcessesItem, kAXTitleAttribute): return "My Processes" as CFString
        case (.allProcessesItem, kAXTitleAttribute): return "All Processes" as CFString
        case (.columnItem(let index), kAXTitleAttribute): return Self.columnTitles[index] as CFString
        case (.myProcessesItem, kAXMenuItemMarkCharAttribute): return _scope == .mine ? "✓" as CFString : nil
        case (.allProcessesItem, kAXMenuItemMarkCharAttribute): return _scope == .all ? "✓" as CFString : nil
        case (.columnItem(let index), kAXMenuItemMarkCharAttribute):
            let marked = Self.columnTitles[index] == "PID" ? _pidColumnVisible : index == 0
            return marked ? "✓" as CFString : nil
        default:
            return nil
        }
    }

    private func element(_ node: Node) -> AXUIElement {
        if let token = tokens[node] {
            return AXUIElementCreateApplication(token)
        }
        let token = pid_t(800_000 + tokens.count)
        tokens[node] = token
        nodes[token] = node
        return AXUIElementCreateApplication(token)
    }

    private func elements(_ list: [Node]) -> CFArray {
        list.map { element($0) } as CFArray
    }

    private func node(for element: AXUIElement) -> Node? {
        var token: pid_t = 0
        guard AXUIElementGetPid(element, &token) == .success else { return nil }
        return nodes[token]
    }
}
