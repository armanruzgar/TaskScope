import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class Batch03PollingTests: XCTestCase {
    func testAutoRefreshLoadsInitialListWithOneExtendedReadAndReusesWatchedSnapshotForEnforcement() async {
        let upstream = ScriptedInventory([.success([])], repeatsLast: true)
        let verification = ScriptedInventory([.success([])], repeatsLast: true)
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let shared = CoalescingProcessInventory(upstream: upstream, now: { 0 })
        let manager = ProcessManager(processInventory: shared, verificationInventory: verification,
                                     processSignaler: FakeSignaler(), lifecycle: FakeLifecycle.allSucceeding(),
                                     settleAfterProcessChange: {}, pollingController: controller, dependencies: .inert)
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [.globalProtect] }
        manager.dependencies.keptOffPresets = { [.globalProtect] }
        await manager.beginExtendedMetrics()
        manager.setPolling(interval: 10, includeProcessList: true)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertTrue(manager.hasLoadedProcessList)
        XCTAssertEqual(upstream.extendedStatsRequests, [true])
        XCTAssertEqual(verification.extendedStatsRequests, [])
        manager.setPolling(interval: 10, includeProcessList: true, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(upstream.extendedStatsRequests, [true], "stopped polling must not execute another tick")
        manager.endExtendedMetrics()
    }

    func testWatchedOnlyTickKeepsListUnloadedAndStillEnforcesKeepOff() async {
        let ui = batch03Process(pid: 42, name: "GlobalProtect")
        let upstream = ScriptedInventory([.success([ui])], repeatsLast: true)
        let verification = ScriptedInventory([.success([])], repeatsLast: true)
        let lifecycle = FakeLifecycle.allSucceeding()
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: upstream, verificationInventory: verification,
                                     processSignaler: FakeSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, pollingController: controller, dependencies: .inert)
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [.globalProtect] }
        manager.dependencies.keptOffPresets = { [.globalProtect] }
        manager.dependencies.isPresetKeptOff = { _ in true }
        manager.setPolling(interval: 10, includeProcessList: false)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(upstream.extendedStatsRequests, [false])
        XCTAssertFalse(manager.hasLoadedProcessList)
        XCTAssertTrue(lifecycle.calls.contains("agents.disable"))
        // Only gated enforcement's before/final reads; no redundant pre-check.
        XCTAssertEqual(verification.extendedStatsRequests, [false, false])
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: false)
    }

    func testFailedListTickFallsBackToWatchedRefresh() async {
        let inventory = ScriptedInventory([.failure(.commandFailed("extended failed")), .success([])], repeatsLast: true)
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: FakeSignaler(),
                                     lifecycle: FakeLifecycle.allSucceeding(), settleAfterProcessChange: {}, pollingController: controller, dependencies: .inert)
        manager.enableNotifications = false
        await manager.beginExtendedMetrics()
        manager.setPolling(interval: 10, includeProcessList: true)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(inventory.extendedStatsRequests, [true, false])
        XCTAssertFalse(manager.hasLoadedProcessList)
        XCTAssertEqual(manager.watchedStatusAvailability, .current)
        XCTAssertNil(manager.watchedStatusLoadError)
        XCTAssertEqual(manager.processListLoadError, "extended failed")
        manager.setPolling(interval: 10, includeProcessList: true, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: false)
        manager.endExtendedMetrics()
    }

    /// Startup verification and a rejected duplicate launch never configure
    /// polling; a status view shown there must not start any automatic work.
    func testShowingStatusBeforePollingIsConfiguredStartsNothing() async {
        let inventory = ScriptedInventory([.success([])], repeatsLast: true)
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: FakeSignaler(),
                                     lifecycle: FakeLifecycle.allSucceeding(), settleAfterProcessChange: {},
                                     pollingController: controller, dependencies: .inert)
        manager.enableNotifications = false

        await manager.beginObservingStatus()
        for _ in 0..<20 { await Task.yield() }
        let requestsBeforeConfiguration = await sleeper.requestCount()
        XCTAssertEqual(requestsBeforeConfiguration, 0)
        XCTAssertTrue(inventory.extendedStatsRequests.isEmpty)

        // Once configured, the visible view keeps polling alive on its own.
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.waitForRequestCount(1)
        manager.endObservingStatus()
        await sleeper.resumeRequest(at: 0, returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inventory.extendedStatsRequests.isEmpty, "closing the last view stopped the poll")
    }

    /// Opening or closing a window while background work already needs the
    /// poll must not restart it: a restart cancels an in-flight tick, such as a
    /// background Keep Off pass.
    func testShowingStatusDoesNotRestartARunningPoll() async {
        let inventory = ScriptedInventory([.success([])], repeatsLast: true)
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: FakeSignaler(),
                                     lifecycle: FakeLifecycle.allSucceeding(), settleAfterProcessChange: {},
                                     pollingController: controller, dependencies: .inert)
        manager.enableNotifications = false
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: true)
        await sleeper.waitForRequestCount(1)

        await manager.beginObservingStatus()
        manager.endObservingStatus()
        for _ in 0..<20 { await Task.yield() }
        let requestsAfterViewCycle = await sleeper.requestCount()
        XCTAssertEqual(requestsAfterViewCycle, 1, "the poll was restarted")
        XCTAssertEqual(inventory.extendedStatsRequests, [false], "opening refreshed status once")

        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(inventory.extendedStatsRequests, [false, false], "the original poll kept ticking")
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: false)
    }

    /// With Auto-refresh on, the tick's list read is its only read, so it also
    /// feeds the history chart of a visible window.
    func testAutoRefreshTickFeedsTheHistoryFromItsListRead() async {
        let inventory = ScriptedInventory([.success([batch03Process(pid: 42, name: "Worker")])], repeatsLast: true)
        let historySleeper = ControlledPollingSleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await historySleeper.sleep(interval: $0) })
        let pollSleeper = ControlledPollingSleeper()
        let manager = ProcessManager(processInventory: inventory, processSignaler: FakeSignaler(),
                                     lifecycle: FakeLifecycle.allSucceeding(), settleAfterProcessChange: {},
                                     pollingController: ProcessPollingController { await pollSleeper.sleep(interval: $0) },
                                     processHistory: history, dependencies: .inert)
        manager.enableNotifications = false
        manager.setPolling(interval: 10, includeProcessList: true)
        await pollSleeper.waitForRequestCount(1)
        history.beginSampling(cadence: 10)
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        XCTAssertEqual(history.samples.count, 1, "the history reads once when the window opens")

        await pollSleeper.resumeRequest(at: 0, returning: true)
        await pollSleeper.waitForRequestCount(2)
        XCTAssertTrue(manager.hasLoadedProcessList)
        XCTAssertEqual(history.samples.count, 2, "the tick's list read did not feed the history")
        XCTAssertEqual(inventory.extendedStatsRequests, [false, false], "one read on opening, one per tick")
        let historySleeps = await historySleeper.requestCount()
        XCTAssertEqual(historySleeps, 0, "the history ran its own loop while the manager polls")

        history.endSampling()
        manager.setPolling(interval: 10, includeProcessList: true, backgroundActivity: false)
        await pollSleeper.resumeRequest(at: 1, returning: false)
    }

    func testHiddenIdleStopsPollingAndOpeningRefreshesStatus() async {
        let inventory = ScriptedInventory([.success([])], repeatsLast: true)
        let manager = ProcessManager(processInventory: inventory, processSignaler: FakeSignaler(),
                                     lifecycle: FakeLifecycle.allSucceeding(), settleAfterProcessChange: {},
                                     pollingController: ProcessPollingController(sleep: { _ in false }), dependencies: .inert)
        manager.enableNotifications = false
        manager.setPolling(interval: 2, includeProcessList: false, backgroundActivity: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inventory.extendedStatsRequests.isEmpty)
        await manager.beginObservingStatus()
        XCTAssertEqual(inventory.extendedStatsRequests, [false])
        XCTAssertEqual(manager.watchedStatusAvailability, .current)
        manager.endObservingStatus()
    }
}
