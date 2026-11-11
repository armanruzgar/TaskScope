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
