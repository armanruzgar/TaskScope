import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The shared inventory's cache, join and cancellation rules.
final class Batch05InventoryFixTests: XCTestCase {
    /// A load issued after `invalidate()` must not join a read that started
    /// before it (an observer's read in flight across a Stop).
    func testInvalidationDetachesBlockedBasicAndExtendedReads() async {
        for extended in [false, true] {
            let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
            let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
            let first = Task { await inventory.load(fetchExtendedStats: extended) }
            await upstream.waitUntilFirstCallStarted()
            await inventory.invalidate()

            let completed = expectation(description: "A read after invalidation does not wait for the old one")
            let second = Task {
                let result = await inventory.load(fetchExtendedStats: extended)
                completed.fulfill()
                return result
            }
            await fulfillment(of: [completed], timeout: 10)
            await upstream.releaseFirstCall()
            let fresh = await second.value
            _ = await first.value

            XCTAssertEqual(try fresh.get().map(\.pid), [43], "extended: \(extended)")
            let calls = await upstream.callCount()
            XCTAssertEqual(calls, 2)
        }
    }

    /// A basic cache entry has no network or disk values, so it never answers
    /// an extended request.
    func testBasicCacheCannotAnswerExtendedRequest() async {
        let upstream = ScriptedInventory(processes: [])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: false)
        _ = await inventory.load(fetchExtendedStats: true)

        let modes = upstream.extendedStatsRequests
        XCTAssertEqual(modes, [false, true])
    }

    /// An extended read already in flight answers both an extended and a basic
    /// request; neither starts a read of its own.
    func testBasicAndExtendedRequestsJoinAnExtendedReadInFlight() async {
        for extended in [false, true] {
            let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
            let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
            let first = Task { await inventory.load(fetchExtendedStats: true) }
            await upstream.waitUntilFirstCallStarted()
            let second = Task { await inventory.load(fetchExtendedStats: extended) }
            let joined = await batch05Eventually { await inventory.waitingCallerCount == 2 }
            XCTAssertTrue(joined)

            await upstream.releaseFirstCall()
            let firstResult = await first.value
            let secondResult = await second.value

            XCTAssertEqual(firstResult, secondResult)
            XCTAssertEqual(try secondResult.get().map(\.pid), [42], "extended: \(extended)")
            let calls = await upstream.callCount()
            XCTAssertEqual(calls, 1)
        }
    }

    /// The cache window starts when a read completes. Measured from its start,
    /// a read slower than the window was already stale when it finished, and
    /// the next consumer in the same poll tick read everything again.
    func testASlowReadIsSharedForAFullWindowAfterItCompletes() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
        let clock = Batch05Clock()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 0.5, now: { clock.now() })
        let first = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilFirstCallStarted()
        clock.advance(5)
        await upstream.releaseFirstCall()
        _ = await first.value

        let shared = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try shared.get().map(\.pid), [42])
        clock.advance(0.6)
        let expired = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try expired.get().map(\.pid), [43])
    }

    /// A cancelled sole caller returns at once with `.cancelled`, its read is
    /// cancelled too (so the commands behind it stop), and the next caller
    /// starts a fresh read.
    func testCancelledSoleCallerReturnsAtOnceAndCancelsTheRead() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let returned = expectation(description: "The cancelled caller returns before the read ends")
        let first = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            returned.fulfill()
            return result
        }
        await upstream.waitUntilFirstCallStarted()

        first.cancel()
        await fulfillment(of: [returned], timeout: 10)
        let detached = await batch05Eventually { await inventory.waitingCallerCount == 0 }
        XCTAssertTrue(detached)
        let freshDone = expectation(description: "The next caller starts a fresh read")
        let second = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            freshDone.fulfill()
            return result
        }
        await fulfillment(of: [freshDone], timeout: 10)
        await upstream.releaseFirstCall()

        let cancelledResult = await first.value
        let freshResult = await second.value
        XCTAssertEqual(cancelledResult, .failure(.cancelled))
        XCTAssertEqual(try freshResult.get().map(\.pid), [43])
        let cancelledReads = await batch05Eventually { await upstream.cancelledCallCount() == 1 }
        XCTAssertTrue(cancelledReads, "The abandoned read must see its cancellation")
    }

    /// Cancelling one of two callers sharing a read leaves the other one, and
    /// the read, untouched.
    func testCancellingOneJoinerLeavesTheOtherAndTheRead() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)]])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let first = Task { await inventory.load(fetchExtendedStats: true) }
        await upstream.waitUntilFirstCallStarted()
        let returned = expectation(description: "The cancelled joiner returns on its own")
        let second = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            returned.fulfill()
            return result
        }
        let joined = await batch05Eventually { await inventory.waitingCallerCount == 2 }
        XCTAssertTrue(joined)

        second.cancel()
        await fulfillment(of: [returned], timeout: 10)
        let remaining = await inventory.waitingCallerCount
        XCTAssertEqual(remaining, 1)
        await upstream.releaseFirstCall()

        // A regression that drops the other caller must fail, not hang.
        guard let firstResult = await batch05Value(of: first) else {
            return XCTFail("The caller still waiting was never answered")
        }
        let secondResult = await second.value
        XCTAssertEqual(try firstResult.get().map(\.pid), [42])
        XCTAssertEqual(secondResult, .failure(.cancelled))
        let cancelledReads = await upstream.cancelledCallCount()
        XCTAssertEqual(cancelledReads, 0, "A read someone still waits for must not be cancelled")
    }
}

func batch05Eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

/// The task's value, or nil when it has not finished within ten seconds; the
/// task is then left suspended instead of hanging the test.
func batch05Value<Value: Sendable>(of task: Task<Value, Never>) async -> Value? {
    let box = Batch05Box<Value>()
    Task { box.store(await task.value) }
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if let value = box.value { return value }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return box.value
}

private final class Batch05Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func store(_ value: Value) {
        lock.withLock { stored = value }
    }

    var value: Value? { lock.withLock { stored } }
}

/// Blocks its first read until released; later reads answer at once. Records
/// whether the blocked read saw its task cancelled.
actor Batch05BlockingUpstream: ProcessInventoryProviding {
    private var results: [[AppProcess]]
    private var calls = 0
    private var cancelledCalls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    init(results: [[AppProcess]]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        let result = results.isEmpty ? [] : results.removeFirst()
        if calls == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { gate = $0 }
            if Task.isCancelled {
                cancelledCalls += 1
                return .failure(.cancelled)
            }
        }
        return .success(result)
    }

    func waitUntilFirstCallStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        gate?.resume()
        gate = nil
    }

    func callCount() -> Int { calls }

    func cancelledCallCount() -> Int { cancelledCalls }
}

private final class Batch05Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
