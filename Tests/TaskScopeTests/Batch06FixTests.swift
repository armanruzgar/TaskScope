import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class Batch06ListModelTests: XCTestCase {
    /// A05-3: the tree follows the Sort setting at every level.
    func testTreeRootsAndSiblingsFollowEverySortKeyWithAncestorContext() {
        let parent = batch06Process(pid: 100, name: "Bravo", cpu: 1, memory: 30)
        let children = [
            batch06Process(pid: 101, parent: 100, name: "Zulu", cpu: 5, memory: 20),
            batch06Process(pid: 102, parent: 100, name: "Alpha", cpu: 95, memory: 40),
            batch06Process(pid: 103, parent: 100, name: "Echo", cpu: 10, memory: 10)
        ]
        let other = batch06Process(pid: 200, name: "Charlie", cpu: 60, memory: 5)
        let last = batch06Process(pid: 300, name: "Delta", cpu: 3, memory: 100)
        var projection = ProcessListProjection(inventory: children.reversed() + [last, parent, other])
        let expectations: [(ProcessSortKey, [Int32], [Int32])] = [
            (.cpu, [200, 300, 100], [102, 103, 101]),
            (.memory, [300, 100, 200], [102, 101, 103]),
            (.name, [100, 200, 300], [102, 103, 101]),
            (.pid, [100, 200, 300], [101, 102, 103])
        ]
        for (key, roots, siblings) in expectations {
            let tree = projection.treeRoots(for: batch06Query(), sortKey: key, limit: 80)
            XCTAssertEqual(tree.map(\.id), roots, "\(key)")
            XCTAssertEqual(tree.first { $0.id == 100 }?.children.map(\.id), siblings, "\(key)")
        }
        // With the limit truncating the matches, the ancestor kept for context
        // is placed by its own rank, after the busier root.
        let limited = projection.treeRoots(for: batch06Query(), sortKey: .cpu, limit: 2)
        XCTAssertEqual(limited.map(\.id), [200, 100])
        XCTAssertEqual(limited.last?.children.map(\.id), [102])
    }

    /// T07-6: one parent with many children always lists them in a stable order.
    func testManySiblingsHaveStablePIDOrderAcrossInputPermutations() {
        let parent = batch06Process(pid: 100, name: "Parent")
        let children = (101...140).map { batch06Process(pid: Int32($0), parent: 100, name: "Worker") }
        let expected = children.map(\.pid)
        for offset in 0..<20 {
            let permuted = Array(children.dropFirst(offset)) + Array(children.prefix(offset))
            let inventory = [parent] + permuted.reversed()
            let parents = Dictionary(uniqueKeysWithValues: inventory.map { ($0.pid, $0.parentPID) })
            let tree = ProcessTreeBuilder.build(from: inventory, ppidMap: parents)
            XCTAssertEqual(tree.first?.children.map(\.id), expected)
            var projection = ProcessListProjection(inventory: inventory)
            for sortKey in [ProcessSortKey.cpu, .memory, .name, .pid] {
                let projected = projection.treeRoots(for: batch06Query(), sortKey: sortKey, limit: 80)
                XCTAssertEqual(projected.first?.children.map(\.id), expected, "\(sortKey)")
            }
        }
    }

    /// T07-6: ranked rows come first in rank order; equal and missing ranks
    /// fall back to PID order.
    func testBuilderOrdersSiblingsByRankThenPID() {
        let parent = batch06Process(pid: 1_000, name: "Parent")
        let children = [105, 101, 104, 102, 103].map {
            batch06Process(pid: Int32($0), parent: 1_000, name: "Child")
        }
        let inventory = [parent] + children
        let parents = Dictionary(uniqueKeysWithValues: inventory.map { ($0.pid, $0.parentPID) })
        let tree = ProcessTreeBuilder.build(
            from: inventory,
            ppidMap: parents,
            sortRanks: [1_000: 0, 104: 1, 102: 2, 105: 2]
        )
        XCTAssertEqual(tree.map(\.id), [1_000])
        XCTAssertEqual(tree.first?.children.map(\.id), [104, 102, 105, 101, 103])
    }

    /// L04-1: the per-query memo caches stay bounded while the inventory lives.
    func testQueryCachesStayBoundedWithoutReplacingInventory() throws {
        let parent = batch06Process(pid: 100, name: "Parent")
        let child = batch06Process(pid: 101, parent: 100, name: "Worker", cpu: 90)
        var projection = ProcessListProjection(inventory: [parent, child])
        for index in 0..<100 {
            var query = batch06Query()
            query.searchText = String(repeating: " ", count: index)
            query.cpuHighlightThreshold = Double(index)
            XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).processes, [child])
            XCTAssertEqual(projection.treeRoots(for: query, sortKey: .cpu, limit: 1).first?.children.map(\.id), [101])
            for label in ["displayListCache", "treeRootsCache"] {
                let cache = try XCTUnwrap(Mirror(reflecting: projection).children.first { $0.label == label })
                XCTAssertLessThanOrEqual(Mirror(reflecting: cache.value).children.count, 8, label)
            }
        }
        // Eviction must preserve match counts, limits, and ancestor reconstruction.
        let list = projection.displayList(for: batch06Query(), sortKey: .cpu, limit: 1)
        XCTAssertEqual(list.processes, [child])
        XCTAssertEqual(list.matchCount, 2)
        XCTAssertEqual(projection.treeRoots(for: batch06Query(), sortKey: .cpu, limit: 1).first?.process, parent)
    }

    /// L08-11: the ranked tie-break gives the order a direct natural-name
    /// comparison gives, and the names are ranked once per inventory.
    func testRankedTieBreakKeepsTheNaturalNameOrder() throws {
        let names = [
            "Worker10", "Worker2", "worker2", "Worker 2", "WORKER1", "Éclair", "Eclair", "eclair",
            "com.apple.WebKit.WebContent", "com.apple.WebKit.Networking", "Google Chrome Helper (Renderer)",
            "Google Chrome Helper", "zsh", "Zsh", "a10b2", "a2b10", "a2b9", "-dash", "_under", "123"
        ]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let inventory: [AppProcess] = (0..<300).map { index in
            batch06Process(
                pid: Int32(10_000 - index * 7),
                name: index < names.count ? names[index] : names[next(names.count)],
                cpu: next(10) < 8 ? 0 : Double(next(4)),
                memory: Double(next(3))
            )
        }
        var projection = ProcessListProjection(inventory: inventory)
        for key in [ProcessSortKey.cpu, .memory, .name, .pid, .cpu] {
            let expected = inventory.sorted { lhs, rhs in
                switch key {
                case .cpu where lhs.cpu != rhs.cpu: return lhs.cpu > rhs.cpu
                case .memory where lhs.memoryMB != rhs.memoryMB: return lhs.memoryMB > rhs.memoryMB
                case .pid: return lhs.pid < rhs.pid
                default:
                    let comparison = lhs.name.localizedStandardCompare(rhs.name)
                    return comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
                }
            }
            XCTAssertEqual(projection.displayProcesses(sortKey: key, limit: 500).map(\.pid), expected.map(\.pid), "\(key)")
        }
        let cache = try XCTUnwrap(Mirror(reflecting: projection).children.first { $0.label == "nameRanksCache" })
        let ranks = try XCTUnwrap(Mirror(reflecting: cache.value).children.first?.value as? [String: Int])
        XCTAssertEqual(ranks.count, Set(inventory.map(\.name)).count, "One rank per distinct name, computed once")
        XCTAssertLessThan(try XCTUnwrap(ranks["Worker2"]), try XCTUnwrap(ranks["Worker10"]))
    }
}

/// A05-10: guards that no test pinned before.
@MainActor
final class Batch06GuardTests: XCTestCase {
    func testUnobservedAndEditedPresetsHaveUnknownAvailability() {
        let preset = WatchedAppPreset.globalProtect
        let snapshot = WatchedAppSnapshot(preset: preset, runningNames: [])
        var edited = preset
        edited.mainProcessName = "EditedMain"
        for availability in [WatchedStatusAvailability.current, .stale, .unknown] {
            XCTAssertEqual(availability.forPresets([preset], snapshots: []), .unknown)
            XCTAssertEqual(availability.forPresets([edited], snapshots: [snapshot]), .unknown)
            XCTAssertEqual(availability.forPresets([preset], snapshots: [snapshot]), availability)
        }
    }

    func testSearchTrimsSurroundingWhitespaceAndNewlines() {
        let process = batch06Process(pid: 10, name: "Safari")
        for text in [" Safari ", "\nSafari\t", " \n\t"] {
            var query = batch06Query()
            query.searchText = text
            XCTAssertTrue(query.matches(process), text)
        }
    }

    func testUnbalancedEndDoesNotConsumeTheNextSamplingConsumer() async {
        let inventory = Batch06ScriptedInventory(results: [.success([])])
        let sleeper = Batch06Sleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await sleeper.sleep(interval: $0) })
        history.endSampling()
        history.endSampling()
        history.beginSampling(cadence: 60)
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.state, .sampling)
        history.endSampling()
        await sleeper.resumePendingRequests(returning: false)
    }

    func testRootCannotHaveACurrentUserGlobalProtectLaunchAgent() {
        let path = "/Applications/GlobalProtect.app/Contents/MacOS/PanGPS"
        for uid: uid_t in [0, 501] {
            var agent = batch06Process(pid: 10, name: "PanGPS")
            agent.uid = uid
            agent.executablePath = path
            let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: uid)
                .snapshot(for: .globalProtect, in: [agent])
            XCTAssertEqual(snapshot.hasCurrentUserLaunchAgent, uid != 0)
        }
    }

    func testRestartCancelsThePreviousPollingLoop() async {
        let sleeper = Batch06Sleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        var oldActions = 0
        var newActions = 0
        controller.restart(interval: 10) { oldActions += 1 }
        await sleeper.waitForRequestCount(1)
        controller.restart(interval: 20) { newActions += 1 }
        await sleeper.waitForRequestCount(2)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.resumeRequest(at: 1, returning: true)
        await sleeper.waitForRequestCount(3)
        for _ in 0..<100 { await Task.yield() }
        controller.stop()
        // Drain every pending request even under a broken restart implementation.
        await sleeper.resumePendingRequests(returning: false)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(newActions, 1)
    }

    func testSparklineAccessibilityDescribesEmptyAndLatestSamples() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let samples = [
            ProcessHistory.Sample(timestamp: timestamp, observedProcessCPU: 10, observedProcessMemoryMB: 100, processCount: 1),
            ProcessHistory.Sample(timestamp: timestamp, observedProcessCPU: 25.5, observedProcessMemoryMB: 200, processCount: 2)
        ]
        for values in [[], samples] {
            let chart = SparklineView(samples: values, keyPath: \.observedProcessCPU, color: .blue, label: "CPU", unit: "percent")
            let stack = try chart.inspect().find(ViewType.VStack.self)
            XCTAssertEqual(try stack.accessibilityLabel().string(), "CPU")
            let latest = 25.5.formatted(.number.precision(.fractionLength(1)))
            XCTAssertEqual(try stack.accessibilityValue().string(), values.isEmpty ? "No samples" : "Latest \(latest) percent, peak \(latest) percent, 2 samples")
        }
    }
}

/// A05-8: while the manager polls, the history samples from the poll's reads
/// instead of running a second, out-of-phase read loop.
@MainActor
final class Batch06HistoryPollingTests: XCTestCase {
    func testOpeningWhilePollingReadsOnceThenSamplesOnlyOnPollTicks() async {
        let row = batch06Process(pid: 10, name: "Worker", cpu: 25, memory: 100)
        let inventory = Batch06ScriptedInventory(results: [
            .success([row]), .success([row]), .failure(.commandFailed("unavailable")), .success([])
        ])
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
        let readsAfterOpening = await inventory.callCount()
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

        let totalReads = await inventory.callCount()
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
        let inventory = Batch06ScriptedInventory(results: [.success([row])])
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
        let reads = await inventory.callCount()
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
        processSignaler: Batch06InertSignaler(),
        lifecycle: Batch06InertLifecycle(),
        settleAfterProcessChange: {},
        pollingController: ProcessPollingController { await sleeper.sleep(interval: $0) },
        processHistory: history,
        dependencies: .inert
    )
    manager.enableNotifications = false
    return manager
}

private func batch06Query() -> ProcessListQuery {
    ProcessListQuery(searchText: "", filterMode: .all, watchedScopes: [], cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1024)
}

private func batch06Process(
    pid: Int32, parent: Int32 = 1, name: String, cpu: Double = 0, memory: Double = 0
) -> AppProcess {
    AppProcess(
        pid: pid, parentPID: parent, uid: 501, cpu: cpu, memoryMB: memory,
        command: name, elapsedTime: "00:10", startTime: "start\(pid)",
        netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
    )
}

/// Each `sleep` call waits until the test resumes it by index.
private actor Batch06Sleeper {
    private var intervals: [TimeInterval] = []
    private var requests: [CheckedContinuation<Bool, Never>?] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(interval: TimeInterval) async -> Bool {
        intervals.append(interval)
        let ready = countWaiters.filter { intervals.count >= $0.count }
        countWaiters.removeAll { intervals.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { requests.append($0) }
    }

    func waitForRequestCount(_ count: Int) async {
        guard intervals.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func requestCount() -> Int { intervals.count }

    func interval(at index: Int) -> TimeInterval { intervals[index] }

    func resumeRequest(at index: Int, returning value: Bool) {
        requests[index]?.resume(returning: value)
        requests[index] = nil
    }

    func resumePendingRequests(returning value: Bool) {
        for index in requests.indices {
            resumeRequest(at: index, returning: value)
        }
    }
}

/// Returns the scripted results in order, repeating the last one.
private actor Batch06ScriptedInventory: ProcessInventoryProviding {
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private var calls = 0

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        guard results.count > 1 else { return results.first ?? .success([]) }
        return results.removeFirst()
    }

    func callCount() -> Int { calls }
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

private struct Batch06InertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct Batch06InertLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { false }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        .noMatchingProcesses
    }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .failed("Fake launch failed.") }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}
