import XCTest
@testable import TaskScope

/// L11-21: while the menu-bar icon is the only background reader, the poll
/// reads every 30 seconds (or at a longer interval); a window or popover that
/// shows status, notifications and Keep Off keep the interval. The poll timer
/// is a recorder, so no real interval elapses.
@MainActor
final class MenuBarPollingTests: XCTestCase {
    private func makeManager(_ polling: Batch02PollingRecorder) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler(rejectingAll: true),
            settleAfterProcessChange: {},
            pollingController: polling.controller(),
            dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testEachBackgroundNeedPicksItsCadence() async {
        let polling = Batch02PollingRecorder()
        let manager = makeManager(polling)
        XCTAssertNil(manager.effectivePollInterval, "nothing is configured yet")

        manager.setPolling(interval: 10, includeProcessList: false, background: .menuBarIcon)
        XCTAssertEqual(manager.effectivePollInterval, 30)
        await waitUntil { polling.intervals.count == 1 }

        manager.setPolling(interval: 45, includeProcessList: false, background: .menuBarIcon)
        XCTAssertEqual(manager.effectivePollInterval, 45, "a longer interval is kept")
        await waitUntil { polling.intervals.count == 2 }

        manager.setPolling(interval: 10, includeProcessList: false, background: .interval)
        XCTAssertEqual(manager.effectivePollInterval, 10)
        await waitUntil { polling.intervals.count == 3 }
        XCTAssertEqual(polling.intervals, [30, 45, 10])

        manager.setPolling(interval: 10, includeProcessList: false, background: .off)
        XCTAssertNil(manager.effectivePollInterval)
        await waitUntil { polling.cancellations == 3 }
        XCTAssertEqual(polling.intervals, [30, 45, 10], "nothing polls with no reader")

        // The Bool form other callers use maps onto the same cadences.
        manager.setPolling(interval: 12, includeProcessList: false, backgroundActivity: true)
        XCTAssertEqual(manager.effectivePollInterval, 12)
        manager.setPolling(interval: 12, includeProcessList: false, backgroundActivity: false)
        XCTAssertNil(manager.effectivePollInterval)
        manager.stopPolling()
    }

    func testAViewThatShowsStatusReadsAtTheIntervalUntilTheLastOneCloses() async {
        let polling = Batch02PollingRecorder()
        let manager = makeManager(polling)
        manager.setPolling(interval: 10, includeProcessList: false, background: .menuBarIcon)
        await waitUntil { polling.intervals.count == 1 }

        await manager.beginObservingStatus()
        XCTAssertEqual(manager.effectivePollInterval, 10)
        await waitUntil { polling.intervals.count == 2 }
        await manager.beginObservingStatus()
        manager.endObservingStatus()
        XCTAssertEqual(manager.effectivePollInterval, 10, "another view still shows status")
        XCTAssertEqual(polling.intervals, [30, 10], "no restart while the cadence stays")

        manager.endObservingStatus()
        XCTAssertEqual(manager.effectivePollInterval, 30)
        await waitUntil { polling.intervals.count == 3 }
        XCTAssertEqual(polling.intervals, [30, 10, 30])
        manager.stopPolling()
    }

    func testViewsDoNotRestartAPollThatAlreadyKeepsTheInterval() async {
        let polling = Batch02PollingRecorder()
        let manager = makeManager(polling)
        manager.setPolling(interval: 10, includeProcessList: false, background: .interval)
        await waitUntil { polling.intervals.count == 1 }
        await manager.beginObservingStatus()
        manager.endObservingStatus()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(polling.intervals, [10])
        XCTAssertEqual(polling.cancellations, 0)

        // With no background reader, a view starts the poll and its close stops it.
        manager.setPolling(interval: 10, includeProcessList: false, background: .off)
        await waitUntil { polling.cancellations == 1 }
        await manager.beginObservingStatus()
        await waitUntil { polling.intervals.count == 2 }
        manager.endObservingStatus()
        await waitUntil { polling.cancellations == 2 }
        XCTAssertEqual(polling.intervals, [10, 10])
        XCTAssertNil(manager.effectivePollInterval)
        manager.stopPolling()
    }

    /// The slower cadence never makes the status unknown or stale by itself:
    /// only a failed read marks it stale, and a preset with no snapshot yet is
    /// read at once when the presets change (see TaskScopeRuntime).
    func testAFresherReadIsNotRequiredToStayCurrent() async {
        var clock = Date(timeIntervalSince1970: 1_000)
        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler(rejectingAll: true),
            settleAfterProcessChange: {},
            pollingController: Batch02PollingRecorder().controller(),
            now: { clock },
            dependencies: .inert
        )
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [WatchedAppPreset.globalProtect] }
        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(manager.watchedStatusAvailability, .current)
        clock.addTimeInterval(10 * 60)
        XCTAssertEqual(
            manager.watchedStatusAvailability.forPresets([.globalProtect], snapshots: manager.snapshots),
            .current,
            "an older successful read is still current"
        )
        XCTAssertEqual(
            MenuBarStatus.resolve(
                presets: [.globalProtect], snapshots: manager.snapshots,
                availability: manager.watchedStatusAvailability, isKeptOff: { _ in false }, pendingPromptCount: 0
            ),
            .normal
        )
    }
}
