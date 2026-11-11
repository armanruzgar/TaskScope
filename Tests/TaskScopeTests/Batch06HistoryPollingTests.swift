import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// A05-8: while the manager polls, the history samples from the poll's reads
/// instead of running a second, out-of-phase read loop.
@MainActor
final class Batch06HistoryPollingTests: XCTestCase {
    func testOpeningWhilePollingReadsOnceThenSamplesOnlyOnPollTicks() async {
        let row = batch06Process(pid: 10, name: "Worker", cpu: 25, memory: 100)
        let inventory = ScriptedInventory([
            .success([row]), .success([row]), .failure(.commandFailed("unavailable")), .success([])
        ], repeatsLast: true)
        let historySleeper = Batch06Sleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await historySleeper.sleep(interval: $0) })
        let pollSleeper = Batch06Sleeper()
        let manager = batch06Manager(inventory: inventory, history: history, sleeper: pollSleeper)
        manager.setPolling(interval: 10, includeProcessList: false)
        await pollSleeper.waitForRequestCount(1)
        await pollSleeper.resumeRequest(at: 0, returning: true)
        await pollSleeper.waitForRequestCount(2)
        XCTAssertTrue(history.samples.isEmpty, "No consumer was visible at the first tick")

        // The window opens between ticks: one read now, then no timer of its own.
        history.beginSampling(cadence: 10)
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [25])
        let readsAfterOpening = inventory.readCount
        XCTAssertEqual(readsAfterOpening, 2)
        var historySleeps = await historySleeper.requestCount()
        XCTAssertEqual(historySleeps, 0, "The history must not run its own loop while the manager polls")

        // A failed poll read shows as Unavailable and keeps the good samples.
        await pollSleeper.resumeRequest(at: 1, returning: true)
        await pollSleeper.waitForRequestCount(3)
        XCTAssertEqual(history.state, .unavailable("unavailable"))
        XCTAssertEqual(history.samples.count, 1)
        history.updateConsumerCadence(20)
        XCTAssertEqual(history.state, .unavailable("unavailable"))

        // The next tick recovers and adds its sample.
        await pollSleeper.resumeRequest(at: 2, returning: true)
        await pollSleeper.waitForRequestCount(4)
        XCTAssertEqual(history.state, .sampling)
        XCTAssertEqual(history.samples.map(\.processCount), [1, 0])

        // Hidden: ticks no longer record.
        history.endSampling()
        await pollSleeper.resumeRequest(at: 3, returning: true)
        await pollSleeper.waitForRequestCount(5)
        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples.count, 2)

        let totalReads = inventory.readCount
        XCTAssertEqual(totalReads, 5, "Four ticks plus the one read when the window opened")
        historySleeps = await historySleeper.requestCount()
        XCTAssertEqual(historySleeps, 0)
        // Polling stops once nothing needs it.
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await pollSleeper.resumePendingRequests(returning: false)
        await historySleeper.resumePendingRequests(returning: false)
    }

    func testPollingTakesOverFromAnInFlightReadAndKeepsItsSample() async {
        let opened = batch06Process(pid: 10, name: "Opened", cpu: 10)
        let inventory = Batch06BlockingInventory(firstResult: .success([opened]), laterResult: .success([]))
        let historySleeper = Batch06Sleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await historySleeper.sleep(interval: $0) })

        // At launch the window's sampler starts first and bootstrap starts
        // polling while that first read is still running.
        history.beginSampling(cadence: 10)
        await inventory.waitForFirstLoad()
        history.setPollingActive(true)
        await inventory.releaseFirstLoad()
        await inventory.waitForFirstReturn()
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [10], "The first read is kept")
        let historySleeps = await historySleeper.requestCount()
        XCTAssertEqual(historySleeps, 0, "The own loop ends once polling is active")

        history.receivePolledInventory(.success([batch06Process(pid: 20, name: "Polled", cpu: 20)]))
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [10, 20])
        history.receivePolledInventory(.failure(.cancelled))
        XCTAssertEqual(history.state, .sampling, "A cancelled poll read is not a failure")
        XCTAssertEqual(history.samples.count, 2)

        history.endSampling()
        history.receivePolledInventory(.success([]))
        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples.count, 2, "Nothing is recorded while no consumer is visible")
        let loads = await inventory.loadCount()
        XCTAssertEqual(loads, 1)
        await historySleeper.resumePendingRequests(returning: false)
    }

    func testStoppingPollingRestartsTheHistorysOwnSampler() async {
        let row = batch06Process(pid: 10, name: "Worker", cpu: 5)
        let inventory = ScriptedInventory([.success([row])], repeatsLast: true)
        let historySleeper = Batch06Sleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await historySleeper.sleep(interval: $0) })
        let pollSleeper = Batch06Sleeper()
        let manager = batch06Manager(inventory: inventory, history: history, sleeper: pollSleeper)
        manager.setPolling(interval: 60, includeProcessList: false)
        await pollSleeper.waitForRequestCount(1)
        history.beginSampling(cadence: 30)
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        XCTAssertEqual(history.samples.count, 1)

        // Polling stops once nothing needs it.
        manager.setPolling(interval: 60, includeProcessList: false, backgroundActivity: false)
        await historySleeper.waitForRequestCount(1)
        let interval = await historySleeper.interval(at: 0)
        XCTAssertEqual(interval, 30)
        XCTAssertEqual(history.samples.count, 2, "Resuming the own sampler reads at once")
        await historySleeper.resumeRequest(at: 0, returning: true)
        await historySleeper.waitForRequestCount(2)
        XCTAssertEqual(history.samples.count, 3)
        let reads = inventory.readCount
        XCTAssertEqual(reads, 3)

        history.endSampling()
        await historySleeper.resumePendingRequests(returning: false)
        await pollSleeper.resumePendingRequests(returning: false)
    }
}

@MainActor
private func batch06Manager(
    inventory: any ProcessInventoryProviding,
    history: ProcessHistory,
    sleeper: Batch06Sleeper
) -> ProcessManager {
    let manager = ProcessManager(
        processInventory: inventory,
        processSignaler: FakeSignaler(rejectingAll: true),
        lifecycle: FakeLifecycle(),
        settleAfterProcessChange: {},
        pollingController: ProcessPollingController { await sleeper.sleep(interval: $0) },
        processHistory: history,
        dependencies: .inert
    )
    manager.enableNotifications = false
    return manager
}

/// Holds the first read until released; later reads return at once.
private actor Batch06BlockingInventory: ProcessInventoryProviding {
    private let firstResult: Result<[AppProcess], ProcessInventoryError>
    private let laterResult: Result<[AppProcess], ProcessInventoryError>
    private var loads = 0
    private var firstLoadStarted = false
    private var firstLoadReturned = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?

    init(
        firstResult: Result<[AppProcess], ProcessInventoryError>,
        laterResult: Result<[AppProcess], ProcessInventoryError>
    ) {
        self.firstResult = firstResult
        self.laterResult = laterResult
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        loads += 1
        guard loads == 1 else { return laterResult }
        firstLoadStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { firstLoadContinuation = $0 }
        firstLoadReturned = true
        returnWaiters.forEach { $0.resume() }
        returnWaiters.removeAll()
        return firstResult
    }

    func loadCount() -> Int { loads }

    func waitForFirstLoad() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func waitForFirstReturn() async {
        guard !firstLoadReturned else { return }
        await withCheckedContinuation { returnWaiters.append($0) }
    }
}
