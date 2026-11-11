import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class Batch03PollingTests: XCTestCase {
    func testAutoRefreshLoadsInitialListWithOneExtendedReadAndReusesWatchedSnapshotForEnforcement() async {
        let upstream = ManagerTestInventory(results: [.success([])])
        let verification = ManagerTestInventory(results: [.success([])])
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let shared = CoalescingProcessInventory(upstream: upstream, now: { 0 })
        let manager = ProcessManager(processInventory: shared, verificationInventory: verification,
                                     processSignaler: ManagerTestSignaler(), lifecycle: ManagerTestLifecycle(),
                                     settleAfterProcessChange: {}, pollingController: controller)
        manager.enableNotifications = false
        manager.watchedAppsProvider = { [.globalProtect] }
        manager.keptOffPresetsProvider = { [.globalProtect] }
        await manager.beginExtendedMetrics()
        manager.setPolling(interval: 10, includeProcessList: true)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertTrue(manager.hasLoadedProcessList)
        XCTAssertEqual(upstream.fetchExtendedRequests, [true])
        XCTAssertEqual(verification.fetchExtendedRequests, [])
        manager.setPolling(interval: 10, includeProcessList: true, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(upstream.fetchExtendedRequests, [true], "stopped polling must not execute another tick")
        manager.endExtendedMetrics()
    }

    func testWatchedOnlyTickKeepsListUnloadedAndStillEnforcesKeepOff() async {
        let ui = batch03Process(pid: 42, name: "GlobalProtect")
        let upstream = ManagerTestInventory(results: [.success([ui])])
        let verification = ManagerTestInventory(results: [.success([])])
        let lifecycle = ManagerTestLifecycle()
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: upstream, verificationInventory: verification,
                                     processSignaler: ManagerTestSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, pollingController: controller)
        manager.enableNotifications = false
        manager.watchedAppsProvider = { [.globalProtect] }
        manager.keptOffPresetsProvider = { [.globalProtect] }
        manager.isPresetKeptOffProvider = { _ in true }
        manager.setPolling(interval: 10, includeProcessList: false)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(upstream.fetchExtendedRequests, [false])
        XCTAssertFalse(manager.hasLoadedProcessList)
        XCTAssertTrue(lifecycle.calls.contains("agents.disable"))
        // Only gated enforcement's before/final reads; no redundant pre-check.
        XCTAssertEqual(verification.fetchExtendedRequests, [false, false])
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: false)
    }

    func testFailedListTickFallsBackToWatchedRefresh() async {
        let inventory = ManagerTestInventory(results: [.failure(.commandFailed("extended failed")), .success([])])
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {}, pollingController: controller)
        manager.enableNotifications = false
        await manager.beginExtendedMetrics()
        manager.setPolling(interval: 10, includeProcessList: true)
        await sleeper.waitForRequestCount(1)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(inventory.fetchExtendedRequests, [true, false])
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
        let inventory = ManagerTestInventory(results: [.success([])])
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {},
                                     pollingController: controller)
        manager.enableNotifications = false

        await manager.beginObservingStatus()
        for _ in 0..<20 { await Task.yield() }
        let requestsBeforeConfiguration = await sleeper.requestCount()
        XCTAssertEqual(requestsBeforeConfiguration, 0)
        XCTAssertTrue(inventory.fetchExtendedRequests.isEmpty)

        // Once configured, the visible view keeps polling alive on its own.
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.waitForRequestCount(1)
        manager.endObservingStatus()
        await sleeper.resumeRequest(at: 0, returning: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inventory.fetchExtendedRequests.isEmpty, "closing the last view stopped the poll")
    }

    /// Opening or closing a window while background work already needs the
    /// poll must not restart it: a restart cancels an in-flight tick, such as a
    /// background Keep Off pass.
    func testShowingStatusDoesNotRestartARunningPoll() async {
        let inventory = ManagerTestInventory(results: [.success([])])
        let sleeper = ControlledPollingSleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {},
                                     pollingController: controller)
        manager.enableNotifications = false
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: true)
        await sleeper.waitForRequestCount(1)

        await manager.beginObservingStatus()
        manager.endObservingStatus()
        for _ in 0..<20 { await Task.yield() }
        let requestsAfterViewCycle = await sleeper.requestCount()
        XCTAssertEqual(requestsAfterViewCycle, 1, "the poll was restarted")
        XCTAssertEqual(inventory.fetchExtendedRequests, [false], "opening refreshed status once")

        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.waitForRequestCount(2)
        XCTAssertEqual(inventory.fetchExtendedRequests, [false, false], "the original poll kept ticking")
        manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        await sleeper.resumeRequest(at: 1, returning: false)
    }

    /// With Auto-refresh on, the tick's list read is its only read, so it also
    /// feeds the history chart of a visible window.
    func testAutoRefreshTickFeedsTheHistoryFromItsListRead() async {
        let inventory = ManagerTestInventory(results: [.success([batch03Process(pid: 42, name: "Worker")])])
        let historySleeper = ControlledPollingSleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await historySleeper.sleep(interval: $0) })
        let pollSleeper = ControlledPollingSleeper()
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {},
                                     pollingController: ProcessPollingController { await pollSleeper.sleep(interval: $0) },
                                     processHistory: history)
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
        XCTAssertEqual(inventory.fetchExtendedRequests, [false, false], "one read on opening, one per tick")
        let historySleeps = await historySleeper.requestCount()
        XCTAssertEqual(historySleeps, 0, "the history ran its own loop while the manager polls")

        history.endSampling()
        manager.setPolling(interval: 10, includeProcessList: true, backgroundActivity: false)
        await pollSleeper.resumeRequest(at: 1, returning: false)
    }

    func testHiddenIdleStopsPollingAndOpeningRefreshesStatus() async {
        let inventory = ManagerTestInventory(results: [.success([])])
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {},
                                     pollingController: ProcessPollingController(sleep: { _ in false }))
        manager.enableNotifications = false
        manager.setPolling(interval: 2, includeProcessList: false, backgroundActivity: false)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inventory.fetchExtendedRequests.isEmpty)
        await manager.beginObservingStatus()
        XCTAssertEqual(inventory.fetchExtendedRequests, [false])
        XCTAssertEqual(manager.watchedStatusAvailability, .current)
        manager.endObservingStatus()
    }
}
