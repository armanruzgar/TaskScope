import XCTest
@testable import TaskScope

@MainActor
final class ProcessPollingControllerTests: XCTestCase {
    func testPollingClampsIntervalAndRunsOneActionPerTick() async {
        let sleeper = ControlledPollingSleeper()
        let actionRan = expectation(description: "poll action ran")
        let controller = ProcessPollingController { interval in
            await sleeper.sleep(interval: interval)
        }

        controller.restart(interval: 0.1) {
            actionRan.fulfill()
        }
        await sleeper.waitForRequestCount(1)
        let requestedInterval = await sleeper.interval(at: 0)
        XCTAssertEqual(requestedInterval, 2)
        await sleeper.resumeRequest(at: 0, returning: true)
        await fulfillment(of: [actionRan], timeout: 1)

        await sleeper.waitForRequestCount(2)
        controller.stop()
        await sleeper.resumeRequest(at: 1, returning: false)
    }

    func testStopCancelsPendingTickWithoutRunningAction() async {
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { interval in
            await sleeper.sleep(interval: interval)
        }
        var actionCount = 0

        controller.restart(interval: 10) {
            actionCount += 1
        }
        await sleeper.waitForRequestCount(1)
        controller.stop()
        await sleeper.resumeRequest(at: 0, returning: true)
        await Task.yield()

        XCTAssertEqual(actionCount, 0)
    }

    func testImmediateModeRunsBeforeTheFirstSleep() async {
        let sleeper = ControlledPollingSleeper()
        let actionRan = expectation(description: "initial action ran")
        let controller = ProcessPollingController { interval in
            await sleeper.sleep(interval: interval)
        }

        controller.restart(interval: 10, performImmediately: true) {
            actionRan.fulfill()
        }
        await fulfillment(of: [actionRan], timeout: 1)
        await sleeper.waitForRequestCount(1)
        controller.stop()
        await sleeper.resumeRequest(at: 0, returning: false)
    }
}

actor ControlledPollingSleeper {
    private var intervals: [TimeInterval] = []
    private var requests: [CheckedContinuation<Bool, Never>] = []
    private var requestCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(interval: TimeInterval) async -> Bool {
        intervals.append(interval)
        let readyWaiters = requestCountWaiters.filter { intervals.count >= $0.count }
        requestCountWaiters.removeAll { intervals.count >= $0.count }
        readyWaiters.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { continuation in
            requests.append(continuation)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard intervals.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append((count, continuation))
        }
    }

    func interval(at index: Int) -> TimeInterval {
        intervals[index]
    }

    func requestCount() -> Int {
        intervals.count
    }

    func resumeRequest(at index: Int, returning value: Bool) {
        requests[index].resume(returning: value)
    }
}
