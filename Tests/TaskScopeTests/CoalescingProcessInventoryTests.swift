import XCTest
@testable import TaskScope

final class CoalescingProcessInventoryTests: XCTestCase {
    func testRecentBasicReadIsShared() async {
        let upstream = ScriptedInventory(processes: [])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: false)
        _ = await inventory.load(fetchExtendedStats: false)

        let modes = upstream.extendedStatsRequests
        XCTAssertEqual(modes, [false])
    }

    func testExtendedReadCanServeARecentBasicRequest() async {
        let upstream = ScriptedInventory(processes: [])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: true)
        _ = await inventory.load(fetchExtendedStats: false)

        let modes = upstream.extendedStatsRequests
        XCTAssertEqual(modes, [true])
    }

    /// A basic read that started first but finishes last must not replace the
    /// newer extended result that completed while it was blocked.
    func testAnOlderReadThatFinishesLateDoesNotOverwriteANewerCachedResult() async {
        let upstream = ModeBlockingCoalescingInventory(
            basic: [process(pid: 1, name: "OldBasic")],
            extended: [process(pid: 2, name: "NewExtended")]
        )
        let clock = TestClock()
        let inventory = CoalescingProcessInventory(
            upstream: upstream,
            maximumAge: 60,
            now: { clock.now() }
        )

        let basic = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilBasicStarted()
        clock.advance(1)
        let extended = await inventory.load(fetchExtendedStats: true)
        XCTAssertEqual(try extended.get().map(\.name), ["NewExtended"])

        await upstream.releaseBasic()
        _ = await basic.value

        let served = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try served.get().map(\.name), ["NewExtended"], "the older basic read must not win")
    }

    /// After a mutation the shared cache is invalidated, so the next observer
    /// reads fresh state instead of a list taken before the process stopped.
    func testInvalidationDiscardsTheCachedRead() async {
        let upstream = ScriptedInventory([
            .success([process(pid: 1, name: "BeforeStop")]),
            .success([process(pid: 2, name: "AfterStop")])
        ], repeatsLast: true)
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: false)
        await inventory.invalidate()
        let served = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(try served.get().map(\.name), ["AfterStop"])
    }

    /// A read already in flight when the cache is invalidated finished against
    /// pre-mutation state; its result must not become the cached list.
    func testAReadInFlightDuringInvalidationIsNotCached() async {
        let upstream = FirstCallBlockingInventory(results: [
            [process(pid: 1, name: "BeforeStop")],
            [process(pid: 2, name: "AfterStop")]
        ])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        let inFlight = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilFirstCallStarted()
        await inventory.invalidate()
        await upstream.releaseFirstCall()
        _ = await inFlight.value
        let served = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(try served.get().map(\.name), ["AfterStop"], "the pre-invalidation read must not be cached")
    }

    func testFailuresAreNeverCached() async {
        let upstream = ScriptedInventory([
            .failure(.commandFailed("ps unavailable")),
            .success([process(pid: 1, name: "Recovered")])
        ], repeatsLast: true)
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        let first = await inventory.load(fetchExtendedStats: false)
        let second = await inventory.load(fetchExtendedStats: false)
        let third = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(first, .failure(.commandFailed("ps unavailable")))
        XCTAssertEqual(try second.get().map(\.name), ["Recovered"])
        XCTAssertEqual(try third.get().map(\.name), ["Recovered"])
        let calls = upstream.readCount
        XCTAssertEqual(calls, 2, "the failure must not be served from cache; the success must")
    }

    func testIdenticalInFlightReadsJoinOneUpstreamRequest() async {
        let upstream = BlockingCoalescingInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let first = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilStarted()
        let second = Task { await inventory.load(fetchExtendedStats: false) }
        for _ in 0..<10 { await Task.yield() }

        let countWhileBlocked = await upstream.requestCount()
        XCTAssertEqual(countWhileBlocked, 1)
        await upstream.release()
        _ = await first.value
        _ = await second.value
        let finalCount = await upstream.requestCount()
        XCTAssertEqual(finalCount, 1)
    }
}

private func process(pid: Int32, name: String) -> AppProcess {
    AppProcess.fixture(
        pid: pid,
        parentPID: 1,
        cpu: 0,
        memoryMB: 0,
        command: "/tmp/\(name)",
        elapsedTime: "00:01",
        startTime: "start-\(pid)",
        netInKB: nil,
        netOutKB: nil,
        diskReadBytes: nil,
        diskWriteBytes: nil
    )
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

/// Blocks basic reads until released while extended reads complete at once.
private actor ModeBlockingCoalescingInventory: ProcessInventoryProviding {
    private let basic: [AppProcess]
    private let extended: [AppProcess]
    private var basicStarted = false
    private var basicWaiters: [CheckedContinuation<Void, Never>] = []
    private var basicContinuation: CheckedContinuation<Void, Never>?

    init(basic: [AppProcess], extended: [AppProcess]) {
        self.basic = basic
        self.extended = extended
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if fetchExtendedStats {
            return .success(extended)
        }
        basicStarted = true
        basicWaiters.forEach { $0.resume() }
        basicWaiters.removeAll()
        await withCheckedContinuation { basicContinuation = $0 }
        return .success(basic)
    }

    func waitUntilBasicStarted() async {
        guard !basicStarted else { return }
        await withCheckedContinuation { basicWaiters.append($0) }
    }

    func releaseBasic() {
        basicContinuation?.resume()
        basicContinuation = nil
    }
}

private actor BlockingCoalescingInventory: ProcessInventoryProviding {
    private var count = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadContinuation: CheckedContinuation<Void, Never>?

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { loadContinuation = $0 }
        return .success([])
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func requestCount() -> Int { count }

    func release() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}

private actor FirstCallBlockingInventory: ProcessInventoryProviding {
    private var results: [[AppProcess]]
    private var calls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallContinuation: CheckedContinuation<Void, Never>?

    init(results: [[AppProcess]]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        let result = results.isEmpty ? [] : results.removeFirst()
        if calls == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { firstCallContinuation = $0 }
        }
        return .success(result)
    }

    func waitUntilFirstCallStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}
