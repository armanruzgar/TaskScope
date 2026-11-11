import XCTest
@testable import TaskScope

@MainActor
final class ProcessHistoryTests: XCTestCase {
    func testSamplesFullObservedPopulationAndRetainsBoundedWindow() async {
        let inventory = ScriptedInventory([
            .success([process(pid: 1, cpu: 10, memory: 100), process(pid: 2, cpu: 20, memory: 200)]),
            .success([process(pid: 3, cpu: 5, memory: 50)]),
            .success([])
        ], repeatsLast: true)
        var timestamp = Date(timeIntervalSince1970: 100)
        let history = ProcessHistory(inventory: inventory, maxSamples: 2, now: { timestamp })

        await history.sampleNow()
        timestamp.addTimeInterval(10)
        await history.sampleNow()
        timestamp.addTimeInterval(10)
        await history.sampleNow()

        XCTAssertEqual(history.samples.count, 2)
        XCTAssertEqual(history.samples[0].observedProcessCPU, 5)
        XCTAssertEqual(history.samples[0].observedProcessMemoryMB, 50)
        XCTAssertEqual(history.samples[0].processCount, 1)
        XCTAssertEqual(history.samples[1].timestamp, timestamp)
        XCTAssertEqual(history.state, .sampling)
    }

    func testFailureIsVisibleAndPreservesLastGoodSamples() async {
        let inventory = ScriptedInventory([
            .success([process(pid: 1, cpu: 10, memory: 100)]),
            .failure(.commandFailed("ps unavailable"))
        ], repeatsLast: true)
        let history = ProcessHistory(inventory: inventory)

        await history.sampleNow()
        await history.sampleNow()

        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.state, .unavailable("ps unavailable"))
    }

    func testStopDiscardsResultFromInFlightSamplingGeneration() async {
        let inventory = BlockingHistoryInventory(
            firstResult: .success([process(pid: 1, cpu: 10, memory: 100)]),
            laterResult: .success([])
        )
        let history = ProcessHistory(inventory: inventory)

        history.start(cadence: 2)
        await inventory.waitForFirstLoad()
        history.stop()
        await inventory.releaseFirstLoad()
        await inventory.waitForFirstReturn()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples, [])
    }

    func testRestartDiscardsResultFromPreviousSamplingGeneration() async {
        let stale = process(pid: 1, cpu: 10, memory: 100)
        let current = process(pid: 2, cpu: 20, memory: 200)
        let inventory = BlockingHistoryInventory(
            firstResult: .success([stale]),
            laterResult: .success([current])
        )
        let history = ProcessHistory(inventory: inventory)

        history.start(cadence: 2)
        await inventory.waitForFirstLoad()
        history.start(cadence: 2)
        for _ in 0..<100 where history.samples.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [20])

        await inventory.releaseFirstLoad()
        await inventory.waitForFirstReturn()
        for _ in 0..<10 { await Task.yield() }

        history.stop()
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [20])
        XCTAssertEqual(history.state, .paused)
    }

    func testSamplingStartsOnlyWhileAConsumerIsVisible() async {
        let inventory = ScriptedInventory(processes: [])
        let history = ProcessHistory(inventory: inventory)

        for _ in 0..<10 { await Task.yield() }
        let initialLoadCount = inventory.readCount
        XCTAssertEqual(initialLoadCount, 0)

        history.beginSampling(cadence: 60)
        await inventory.waitForRead(1)
        let visibleLoadCount = inventory.readCount
        XCTAssertEqual(visibleLoadCount, 1)

        history.endSampling()
        XCTAssertEqual(history.state, .paused)
    }

    /// L11-14: reopening the window shows the samples still inside the time
    /// window. Nothing was read while paused, so the first new sample starts a
    /// new segment instead of joining them as if contiguous (the concern behind
    /// the old rule that discarded them).
    func testResumingFromZeroConsumersKeepsSamplesInsideTheWindowAsASeparateSegment() async {
        let inventory = ScriptedInventory([
            .success([process(pid: 1, cpu: 400, memory: 100)]),
            .success([process(pid: 2, cpu: 5, memory: 50)])
        ], repeatsLast: true)
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = ProcessHistory(inventory: inventory, now: { clock })

        history.beginSampling(cadence: 60)
        for _ in 0..<1000 where history.samples.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [400])

        history.endSampling()
        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [400], "Paused display keeps the last samples")

        clock.addTimeInterval(120)
        history.beginSampling(cadence: 60)
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [400], "Reopening shows what was collected")
        for _ in 0..<1000 where history.samples.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [400, 5])
        XCTAssertEqual(history.samples.map(\.startsNewSegment), [false, true], "The pause is not drawn as data")
        history.endSampling()
    }

    func testResumingAfterTheWindowDropsSamplesItNoLongerReaches() async {
        let inventory = ScriptedInventory([
            .success([process(pid: 1, cpu: 400, memory: 100)]),
            .success([process(pid: 2, cpu: 5, memory: 50)])
        ], repeatsLast: true)
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = ProcessHistory(inventory: inventory, maxSamples: 6, now: { clock })

        history.beginSampling(cadence: 10)
        for _ in 0..<1000 where history.samples.isEmpty {
            await Task.yield()
        }
        history.endSampling()
        XCTAssertEqual(history.windowDuration, 60, "6 samples at 10 s")

        clock.addTimeInterval(61)
        history.beginSampling(cadence: 10)
        XCTAssertEqual(history.samples, [], "Older than the window")
        for _ in 0..<1000 where history.samples.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [5])
        history.endSampling()
    }

    func testTheWindowFollowsTheCadenceAndRecordingDropsSamplesOutsideIt() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let history = ProcessHistory(inventory: ScriptedInventory([], repeatsLast: true), maxSamples: 60, now: { clock })
        XCTAssertEqual(history.windowDuration, 600, "10 minutes at the default 10 s")
        history.updateConsumerCadence(2)
        XCTAssertEqual(history.windowDuration, 120)
        history.updateConsumerCadence(1)
        XCTAssertEqual(history.cadence, 2, "The cadence has the poll's 2 s floor")

        history.record(processes: [process(pid: 1, cpu: 1, memory: 1)])
        clock.addTimeInterval(100)
        history.record(processes: [process(pid: 1, cpu: 2, memory: 1)])
        clock.addTimeInterval(30)
        history.record(processes: [process(pid: 1, cpu: 3, memory: 1)])
        XCTAssertEqual(history.samples.map(\.observedProcessCPU), [2, 3], "130 s back is outside a 120 s window")
        XCTAssertEqual(history.samples.map(\.processCount), [1, 1])
    }

    func testAdditionalConsumerDoesNotDiscardSamples() async {
        let inventory = ScriptedInventory([.success([process(pid: 1, cpu: 10, memory: 100)])], repeatsLast: true)
        let history = ProcessHistory(inventory: inventory)

        history.beginSampling(cadence: 60)
        for _ in 0..<1000 where history.samples.isEmpty {
            await Task.yield()
        }
        history.beginSampling(cadence: 60)
        XCTAssertEqual(history.samples.count, 1)
        history.endSampling()
        history.endSampling()
    }

    func testCadenceChangeKeepsUnavailableStateUntilNextRead() async {
        let inventory = ScriptedInventory([.failure(.commandFailed("ps unavailable"))], repeatsLast: true)
        let history = ProcessHistory(inventory: inventory)

        history.beginSampling(cadence: 10)
        for _ in 0..<1000 where history.state == .sampling {
            await Task.yield()
        }
        XCTAssertEqual(history.state, .unavailable("ps unavailable"))

        history.updateConsumerCadence(60)
        XCTAssertEqual(history.state, .unavailable("ps unavailable"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(history.state, .unavailable("ps unavailable"))
        history.endSampling()
        XCTAssertEqual(history.state, .paused)
    }

    func testCadenceChangeWhileLiveStaysLive() async {
        let inventory = ScriptedInventory([.success([process(pid: 1, cpu: 10, memory: 100)])], repeatsLast: true)
        let history = ProcessHistory(inventory: inventory)

        history.beginSampling(cadence: 10)
        for _ in 0..<1000 where history.samples.isEmpty {
            await Task.yield()
        }
        history.updateConsumerCadence(60)
        XCTAssertEqual(history.state, .sampling)
        XCTAssertEqual(history.samples.count, 1)
        history.endSampling()
    }

    private func process(pid: Int32, cpu: Double, memory: Double) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 1,
            cpu: cpu,
            memoryMB: memory,
            command: "Process\(pid)",
            elapsedTime: "00:01",
            startTime: "start\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

private actor BlockingHistoryInventory: ProcessInventoryProviding {
    private let firstResult: Result<[AppProcess], ProcessInventoryError>
    private let laterResult: Result<[AppProcess], ProcessInventoryError>
    private var loadCount = 0
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
        loadCount += 1
        guard loadCount == 1 else { return laterResult }

        firstLoadStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstLoadContinuation = continuation
        }
        firstLoadReturned = true
        returnWaiters.forEach { $0.resume() }
        returnWaiters.removeAll()
        return firstResult
    }

    func waitForFirstLoad() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func waitForFirstReturn() async {
        guard !firstLoadReturned else { return }
        await withCheckedContinuation { continuation in
            returnWaiters.append(continuation)
        }
    }
}
