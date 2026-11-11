import XCTest
@testable import TaskScope

final class GlobalProtectDisconnectTests: XCTestCase {
    func testConnectionFailureRequiresTheCompleteIdleView() async {
        let idle = GlobalProtectConnectionObservation(
            status: "Error", showsConnectionFailed: true, canConnect: true, hasDisconnect: false
        )
        XCTAssertEqual(idle.state, .disconnected)
        let runtime = FakeDisconnectRuntime(states: [idle.state])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 5)
        XCTAssertEqual(counts.presses, 0)
    }

    func testErrorOrIncompleteAndContradictoryFailureControlsNeverAuthorizeShutdown() {
        for observation in [
            GlobalProtectConnectionObservation(status: "Error"),
            GlobalProtectConnectionObservation(status: "Error", showsConnectionFailed: true),
            GlobalProtectConnectionObservation(status: "Error", canConnect: true),
            GlobalProtectConnectionObservation(status: "Error", showsConnectionFailed: true, canConnect: true, hasDisconnect: true),
            GlobalProtectConnectionObservation(status: nil, showsConnectionFailed: true, canConnect: true),
            GlobalProtectConnectionObservation(status: "Unknown", showsConnectionFailed: true, canConnect: true)
        ] {
            XCTAssertEqual(observation.state, .unavailable)
        }
        for (status, expected) in [("Connected", GlobalProtectConnectionState.connected), ("Connecting...", .busy), ("Disconnecting...", .busy)] {
            XCTAssertEqual(GlobalProtectConnectionObservation(status: status, showsConnectionFailed: true, canConnect: true).state, expected)
        }
    }

    func testConnectedVPNIsDisconnectedOnceAndWaitsForStableDisconnectedState() async {
        let runtime = FakeDisconnectRuntime(states: [
            .connected, .connected, .busy, .disconnected, .busy,
            .disconnected, .disconnected, .disconnected, .disconnected, .disconnected
        ])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.presses, 1)
        XCTAssertEqual(counts.reads, 10)
    }

    /// A just-launched interface needs time to create its menu bar item. The
    /// startup budget covers that, and once state is readable the normal
    /// three-strike limit applies again.
    func testJustLaunchedInterfaceGetsAStartupBudgetBeforeItsFirstReadableState() async {
        let lateStart = FakeDisconnectRuntime(
            states: Array(repeating: .unavailable, count: 8) + [.disconnected]
        )
        let launched = await GlobalProtectDisconnectController.disconnect(
            using: lateStart,
            startupUnavailableObservations: 20
        )
        XCTAssertEqual(launched, .disconnected)

        let alreadyRunning = FakeDisconnectRuntime(
            states: Array(repeating: .unavailable, count: 8) + [.disconnected]
        )
        let running = await GlobalProtectDisconnectController.disconnect(using: alreadyRunning)
        XCTAssertNotEqual(running, .disconnected)

        let lostAfterStart = FakeDisconnectRuntime(
            states: [.disconnected, .unavailable, .unavailable, .unavailable, .disconnected]
        )
        let lost = await GlobalProtectDisconnectController.disconnect(
            using: lostAfterStart,
            startupUnavailableObservations: 20
        )
        XCTAssertNotEqual(lost, .disconnected, "the startup budget must not extend past the first readable state")
    }

    func testIdleVPNDoesNotPressDisconnect() async {
        let runtime = FakeDisconnectRuntime(states: [.disconnected])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.presses, 0)
        XCTAssertEqual(counts.reads, 5)
    }

    func testConnectedObservationResetsTheDisconnectedStreak() async {
        let runtime = FakeDisconnectRuntime(states: [
            .connected, .disconnected, .disconnected, .disconnected, .disconnected,
            .connected, .disconnected, .disconnected, .disconnected, .disconnected, .disconnected
        ])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 11)
        XCTAssertEqual(counts.presses, 1)
    }

    func testLostPopoverCanRecoverButResetsTheIdleObservationStreak() async {
        let runtime = FakeDisconnectRuntime(states: [
            .disconnected, .disconnected, .unavailable, .unavailable,
            .disconnected, .disconnected, .disconnected, .disconnected, .disconnected
        ])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 9)
        XCTAssertEqual(counts.presses, 0)
    }

    func testPersistentlyUnreadableStateFailsAfterBoundedRetries() async {
        let runtime = FakeDisconnectRuntime(states: [.unavailable])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        guard case .failed(let detail) = result else { return XCTFail("Unreadable state must fail") }
        XCTAssertTrue(detail.contains("could not verify"))
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(counts.presses, 0)
    }

    func testFailedPressUnknownStateAndTimeoutNeverReportDisconnected() async {
        for runtime in [
            FakeDisconnectRuntime(states: [.connected], pressSucceeds: false),
            FakeDisconnectRuntime(states: [.unavailable]),
            FakeDisconnectRuntime(states: [.connected, .busy]),
            FakeDisconnectRuntime(states: [.busy])
        ] {
            let result = await GlobalProtectDisconnectController.disconnect(using: runtime, observationLimit: 6)
            guard case .failed = result else { return XCTFail("Unverified disconnect reported success") }
        }
    }

    func testWallClockDeadlineBoundsSlowObservationsBeforeTheCountLimit() async {
        let clock = DisconnectTestClock()
        let runtime = FakeDisconnectRuntime(states: [.busy], clock: clock, readSeconds: 31)
        let result = await GlobalProtectDisconnectController.disconnect(
            using: runtime, deadline: GlobalProtectDisconnectDeadline(now: { clock.now() })
        )
        assertTimedOut(result)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 3)
        XCTAssertEqual(counts.presses, 0)
    }

    func testDeadlineRejectsTheFinalIdleObservationIfItArrivesTooLate() async {
        let clock = DisconnectTestClock()
        let runtime = FakeDisconnectRuntime(states: [.disconnected], clock: clock, readSeconds: 18)
        let result = await GlobalProtectDisconnectController.disconnect(
            using: runtime, deadline: GlobalProtectDisconnectDeadline(now: { clock.now() })
        )
        assertTimedOut(result)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 5)
        XCTAssertEqual(counts.presses, 0)
    }

    func testDeadlineIncludesDisconnectPressAndObservationWaits() async {
        for duringPress in [true, false] {
            let clock = DisconnectTestClock()
            let runtime = FakeDisconnectRuntime(
                states: [.connected, .disconnected], clock: clock,
                pressSeconds: duringPress ? 90 : 0, waitSeconds: duringPress ? 0 : 90
            )
            let result = await GlobalProtectDisconnectController.disconnect(
                using: runtime, deadline: GlobalProtectDisconnectDeadline(now: { clock.now() })
            )
            assertTimedOut(result)
            let counts = await runtime.counts()
            XCTAssertEqual(counts.reads, 1)
            XCTAssertEqual(counts.presses, 1)
        }
    }

    func testExpiredDeadlineDoesNotReadOrPressTheVendorUI() async {
        let clock = DisconnectTestClock()
        let deadline = GlobalProtectDisconnectDeadline(timeLimit: 2, now: { clock.now() })
        clock.advance(2)
        let runtime = FakeDisconnectRuntime(states: [.connected])
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime, deadline: deadline)
        assertTimedOut(result)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.presses, 0)
    }

    private func assertTimedOut(_ result: GlobalProtectDisconnectResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let message) = result else {
            return XCTFail("A deadline must never authorize service shutdown", file: file, line: line)
        }
        XCTAssertTrue(message.contains("did not finish disconnecting"), file: file, line: line)
        XCTAssertTrue(message.contains("services were left running"), file: file, line: line)
    }
}

private actor FakeDisconnectRuntime: GlobalProtectDisconnectRuntime {
    private var states: [GlobalProtectConnectionState]
    private let pressSucceeds: Bool
    private var reads = 0
    private var presses = 0
    private let clock: DisconnectTestClock?
    private let readSeconds: TimeInterval
    private let pressSeconds: TimeInterval
    private let waitSeconds: TimeInterval

    init(
        states: [GlobalProtectConnectionState],
        pressSucceeds: Bool = true,
        clock: DisconnectTestClock? = nil,
        readSeconds: TimeInterval = 0,
        pressSeconds: TimeInterval = 0,
        waitSeconds: TimeInterval = 0
    ) {
        self.states = states
        self.pressSucceeds = pressSucceeds
        self.clock = clock
        self.readSeconds = readSeconds
        self.pressSeconds = pressSeconds
        self.waitSeconds = waitSeconds
    }

    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState {
        reads += 1
        clock?.advance(readSeconds)
        if states.count > 1 { return states.removeFirst() }
        return states[0]
    }

    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectDisconnectPressResult {
        presses += 1
        clock?.advance(pressSeconds)
        return pressSucceeds ? .pressed : .notPressable
    }

    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async {
        clock?.advance(waitSeconds)
    }
    func counts() -> (reads: Int, presses: Int) { (reads, presses) }
}

private final class DisconnectTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        seconds += interval
    }
}
