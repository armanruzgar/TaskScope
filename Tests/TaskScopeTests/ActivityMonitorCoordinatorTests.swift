import XCTest
@testable import TaskScope

@MainActor
final class ActivityMonitorCoordinatorTests: XCTestCase {
    func testSuccessfulHandoffOpensAndSelectsRequestedPID() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, true])
        let selector = FakeActivityMonitorProcessSelector(results: [.selected])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(identity: identity(42))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(selector.requestedPIDs, [42])
    }

    func testMissingProcessDoesNotOpenActivityMonitor() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [false])
        let selector = FakeActivityMonitorProcessSelector(results: [])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(identity: identity(77))

        XCTAssertEqual(outcome, .missingProcess)
        XCTAssertEqual(opener.openCount, 0)
        XCTAssertTrue(selector.requestedPIDs.isEmpty)
        XCTAssertTrue(outcome.message(for: 77).contains("no longer running"))
    }

    func testLaunchFailureReturnsTypedOutcome() async {
        let opener = FakeActivityMonitorOpener(error: TestOpenError.failed)
        let checker = FakeActivityMonitorProcessChecker(results: [true])
        let selector = FakeActivityMonitorProcessSelector(results: [])
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(identity: identity(88))

        XCTAssertEqual(outcome, .appLaunchFailed("Activity Monitor launch failed."))
        XCTAssertTrue(outcome.message(for: 88).contains("Could not open Activity Monitor"))
        XCTAssertTrue(selector.requestedPIDs.isEmpty)
    }

    func testAccessibilityDenialStopsRetryingAndProvidesRecoveryInstructions() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.accessibilityDenied("Accessibility access is not granted.")]
        )
        let coordinator = makeCoordinator(opener: opener, checker: checker, selector: selector)

        let outcome = await coordinator.openAndSelect(identity: identity(99))

        XCTAssertEqual(
            outcome,
            .accessibilityDenied("Accessibility access is not granted.")
        )
        XCTAssertEqual(selector.requestedPIDs, [99])
        XCTAssertTrue(outcome.message(for: 99).contains("Privacy & Security > Accessibility"))
    }

    func testReadinessIsRetriedUntilSelectionSucceeds() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, true, true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.notReady, .failed("Application is not ready."), .selected]
        )
        var sleepDurations: [UInt64] = []
        let coordinator = ActivityMonitorCoordinator(
            opener: opener,
            processChecker: checker,
            selector: selector,
            maximumSelectionAttempts: 3,
            retryDelayNanoseconds: 123,
            sleep: { sleepDurations.append($0) }
        )

        let outcome = await coordinator.openAndSelect(identity: identity(1234))

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(selector.requestedPIDs, [1234, 1234, 1234])
        XCTAssertEqual(sleepDurations, [123, 123])
    }

    func testRetryBudgetProducesTimeoutWithLastError() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, true])
        let selector = FakeActivityMonitorProcessSelector(
            results: [.notReady, .failed("Activity Monitor was busy.")]
        )
        let coordinator = makeCoordinator(
            opener: opener,
            checker: checker,
            selector: selector,
            maximumAttempts: 2
        )

        let outcome = await coordinator.openAndSelect(identity: identity(321))

        XCTAssertEqual(outcome, .timedOut(lastError: "Activity Monitor was busy."))
        XCTAssertEqual(selector.requestedPIDs, [321, 321])
        XCTAssertTrue(outcome.message(for: 321).contains("retry timed out"))
    }

    func testProcessEndingDuringRetryReturnsMissingProcess() async {
        let opener = FakeActivityMonitorOpener()
        let checker = FakeActivityMonitorProcessChecker(results: [true, true, false])
        let selector = FakeActivityMonitorProcessSelector(results: [.notReady])
        let coordinator = makeCoordinator(
            opener: opener,
            checker: checker,
            selector: selector,
            maximumAttempts: 3
        )

        let outcome = await coordinator.openAndSelect(identity: identity(654))

        XCTAssertEqual(outcome, .missingProcess)
        XCTAssertEqual(selector.requestedPIDs, [654])
    }

    /// App termination restores Activity Monitor immediately instead of
    /// waiting for the scheduled delay that would never fire.
    func testRestoreRequestReachesTheSelectorAndTheRuntime() {
        let selector = FakeActivityMonitorProcessSelector(results: [])
        let coordinator = makeCoordinator(
            opener: FakeActivityMonitorOpener(),
            checker: FakeActivityMonitorProcessChecker(results: []),
            selector: selector
        )

        coordinator.restoreActivityMonitorState()
        XCTAssertEqual(selector.restoreCount, 1)

        let runtime = FakeActivityMonitorAccessibilityRuntime(
            trusted: true,
            applicationPID: 700,
            result: .selected
        )
        SystemActivityMonitorProcessSelector(runtime: runtime).restorePreparedState()
        XCTAssertEqual(runtime.restoreCount, 1)
    }

    /// Menu items are matched by title, never by position, and the scope
    /// group is bounded by separators so a marked item elsewhere in the View
    /// menu is never mistaken for the previous process scope.
    func testMenuMatcherFindsItemsByTitleAndBoundsTheScopeGroupBySeparators() {
        let viewTitles: [String?] = [
            "Columns", "Dock Icon", "Update Frequency", "",
            "All Processes", "All Processes, Hierarchically", "My Processes", "System Processes",
            "", "Filter Processes", "Show Deltas for Process"
        ]

        let allIndex = ActivityMonitorMenuMatcher.allProcessesIndex(titles: viewTitles)
        XCTAssertEqual(allIndex, 4)
        XCTAssertEqual(
            ActivityMonitorMenuMatcher.scopeGroupRange(titles: viewTitles, around: 4),
            4..<8
        )
        XCTAssertEqual(ActivityMonitorMenuMatcher.allProcessesIndex(titles: ["Columns", "Todos los procesos"]), nil)
        XCTAssertEqual(ActivityMonitorMenuMatcher.pidColumnIndex(titles: ["% CPU", "Threads", "PID", "User"]), 2)
        XCTAssertEqual(ActivityMonitorMenuMatcher.pidColumnIndex(titles: ["% CPU", "Process ID"]), 1)
        XCTAssertNil(ActivityMonitorMenuMatcher.pidColumnIndex(titles: ["% CPU", "PIDs", "User"]))
        XCTAssertEqual(ActivityMonitorMenuMatcher.scopeGroupRange(titles: viewTitles, around: 42), 42..<42)
    }

    func testSystemSelectorRequestsAccessibilityAndReturnsDenialWithoutSelecting() async {
        let runtime = FakeActivityMonitorAccessibilityRuntime(
            trusted: false,
            applicationPID: 700,
            result: .selected
        )
        let selector = SystemActivityMonitorProcessSelector(runtime: runtime)

        let result = await selector.select(pid: 42, timeout: 5)

        guard case .accessibilityDenied = result else {
            return XCTFail("Expected an Accessibility denial, got \(result)")
        }
        XCTAssertEqual(runtime.promptValues, [true])
        XCTAssertTrue(runtime.selectionRequests.isEmpty)
    }

    func testSystemSelectorRetriesWhenActivityMonitorHasNotRegisteredYet() async {
        let runtime = FakeActivityMonitorAccessibilityRuntime(
            trusted: true,
            applicationPID: nil,
            result: .selected
        )
        let selector = SystemActivityMonitorProcessSelector(runtime: runtime)

        let result = await selector.select(pid: 42, timeout: 5)
        XCTAssertEqual(result, .notReady)
        XCTAssertEqual(runtime.promptValues, [true])
        XCTAssertTrue(runtime.selectionRequests.isEmpty)
    }

    func testSystemSelectorForwardsExactPIDToAccessibilityRuntime() async {
        let runtime = FakeActivityMonitorAccessibilityRuntime(
            trusted: true,
            applicationPID: 700,
            result: .selected
        )
        let selector = SystemActivityMonitorProcessSelector(runtime: runtime)

        let result = await selector.select(pid: 42, timeout: 5)
        XCTAssertEqual(result, .selected)
        XCTAssertEqual(runtime.selectionRequests, [.init(applicationPID: 700, targetPID: 42)])
    }

    func testPIDCellMatcherUsesStableColumnIdentifierAndExactValue() {
        XCTAssertEqual(
            ActivityMonitorPIDCellMatcher.pidColumnIndex(
                in: ["Command", "CPUUsage", "PID", "UID"]
            ),
            2
        )
        XCTAssertNil(
            ActivityMonitorPIDCellMatcher.pidColumnIndex(
                in: ["Command", "Process ID", "UID"]
            )
        )
        XCTAssertTrue(
            ActivityMonitorPIDCellMatcher.matches(
                value: "21081" as NSString,
                targetPID: 21_081
            )
        )
        XCTAssertFalse(
            ActivityMonitorPIDCellMatcher.matches(
                value: "121081" as NSString,
                targetPID: 21_081
            )
        )
    }

    func testPIDCellMatcherUsesAXColumnRangeWhenEmptyCellsAreOmitted() {
        let visibleCellColumnRanges: [CFRange?] = [
            CFRange(location: 0, length: 1),
            CFRange(location: 1, length: 1),
            CFRange(location: 2, length: 1),
            CFRange(location: 3, length: 1),
            CFRange(location: 5, length: 1),
            CFRange(location: 6, length: 1),
            CFRange(location: 7, length: 1),
            CFRange(location: 8, length: 1),
            CFRange(location: 9, length: 1),
        ]

        XCTAssertEqual(
            ActivityMonitorPIDCellMatcher.cellIndex(
                columnRanges: visibleCellColumnRanges,
                containing: 8
            ),
            7
        )
        XCTAssertNil(
            ActivityMonitorPIDCellMatcher.cellIndex(
                columnRanges: visibleCellColumnRanges,
                containing: 4
            )
        )
    }

    func testPIDCellMatcherSupportsSpansAndRejectsInvalidRanges() {
        let columnRanges: [CFRange?] = [
            nil,
            CFRange(location: -1, length: 1),
            CFRange(location: 2, length: 0),
            CFRange(location: 4, length: 3),
        ]

        XCTAssertEqual(
            ActivityMonitorPIDCellMatcher.cellIndex(
                columnRanges: columnRanges,
                containing: 6
            ),
            3
        )
        XCTAssertNil(
            ActivityMonitorPIDCellMatcher.cellIndex(
                columnRanges: columnRanges,
                containing: -1
            )
        )
        XCTAssertNil(
            ActivityMonitorPIDCellMatcher.cellIndex(
                columnRanges: columnRanges,
                containing: 7
            )
        )
    }

    private func identity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: "fixture", command: "fixture", executablePath: "/fixture")
    }

    private func makeCoordinator(
        opener: FakeActivityMonitorOpener,
        checker: FakeActivityMonitorProcessChecker,
        selector: FakeActivityMonitorProcessSelector,
        maximumAttempts: Int = 3
    ) -> ActivityMonitorCoordinator {
        ActivityMonitorCoordinator(
            opener: opener,
            processChecker: checker,
            selector: selector,
            maximumSelectionAttempts: maximumAttempts,
            retryDelayNanoseconds: 0,
            sleep: { _ in }
        )
    }
}

@MainActor
private final class FakeActivityMonitorOpener: ActivityMonitorOpening {
    private(set) var openCount = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func open() async throws {
        openCount += 1
        if let error {
            throw error
        }
    }
}

@MainActor
private final class FakeActivityMonitorProcessChecker: ActivityMonitorProcessChecking {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func processMatches(identity: ProcessIdentity) -> Bool {
        results.isEmpty ? false : results.removeFirst()
    }
}

@MainActor
private final class FakeActivityMonitorProcessSelector: ActivityMonitorProcessSelecting {
    private var results: [ActivityMonitorSelectionAttempt]
    private(set) var requestedPIDs: [Int32] = []
    private(set) var requestedTimeouts: [TimeInterval] = []
    private(set) var restoreCount = 0

    init(results: [ActivityMonitorSelectionAttempt]) {
        self.results = results
    }

    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        requestedPIDs.append(pid)
        requestedTimeouts.append(timeout)
        return results.isEmpty ? .notReady : results.removeFirst()
    }

    func restorePreparedState() {
        restoreCount += 1
    }
}

@MainActor
private final class FakeActivityMonitorAccessibilityRuntime:
    ActivityMonitorAccessibilityRuntime
{
    struct SelectionRequest: Equatable {
        let applicationPID: pid_t
        let targetPID: Int32
    }

    private let trusted: Bool
    private let applicationPID: pid_t?
    private let result: ActivityMonitorSelectionAttempt
    private(set) var promptValues: [Bool] = []
    private(set) var selectionRequests: [SelectionRequest] = []
    private(set) var restoreCount = 0

    func restorePreparedState() {
        restoreCount += 1
    }

    init(
        trusted: Bool,
        applicationPID: pid_t?,
        result: ActivityMonitorSelectionAttempt
    ) {
        self.trusted = trusted
        self.applicationPID = applicationPID
        self.result = result
    }

    func isProcessTrusted(prompt: Bool) -> Bool {
        promptValues.append(prompt)
        return trusted
    }

    func activityMonitorProcessIdentifier() -> pid_t? {
        applicationPID
    }

    func selectProcessRow(
        applicationPID: pid_t,
        targetPID: Int32,
        timeout: TimeInterval
    ) async -> ActivityMonitorSelectionAttempt {
        selectionRequests.append(
            .init(applicationPID: applicationPID, targetPID: targetPID)
        )
        return result
    }
}

private enum TestOpenError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Activity Monitor launch failed."
    }
}
