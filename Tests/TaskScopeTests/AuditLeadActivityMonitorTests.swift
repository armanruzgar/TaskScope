import Darwin
import XCTest
@testable import TaskScope

@MainActor
final class AuditLeadActivityMonitorTests: XCTestCase {
    // A03-10: a first attempt can run while a cold-launched Activity Monitor
    // has its menus but not yet its window. The scope and PID column were
    // changed then, but the search field was never found later, so a saved
    // search that hid the row was never replaced and the handoff timed out.
    func testSearchFieldFoundAfterTheFirstAttemptIsStillUsed() async {
        let mine = Batch09FakeActivityMonitor.Process(pid: 4321, name: "Safari", mine: true)
        let target = Batch09FakeActivityMonitor.Process(pid: 1, name: "launchd", mine: false)
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        monitor.windowsReady = false
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let first = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(first.attempt, .notReady)
        XCTAssertEqual(monitor.scope, .all)
        XCTAssertTrue(monitor.pidColumnVisible)
        XCTAssertEqual(monitor.search, "chrome", "no window yet, so no search field")

        monitor.windowsReady = true
        let second = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(second.attempt, .notReady)
        XCTAssertEqual(monitor.search, "launchd")
        let third = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(third.attempt, .selected)
        XCTAssertEqual(monitor.selectedPID, 1)

        // The search is restored to what the user had, not to the empty value
        // of the field that did not exist at the first attempt.
        let absent = Batch09FakeActivityMonitor(
            processes: [mine], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        absent.windowsReady = false
        let failing = ActivityMonitorAccessibilityWorker(transport: absent)
        _ = await failing.selectOrPrepare(applicationPID: 900, targetPID: 77, processName: "ghost")
        absent.windowsReady = true
        _ = await failing.selectOrPrepare(applicationPID: 900, targetPID: 77, processName: "ghost")
        XCTAssertEqual(absent.search, "ghost")
        failing.restoreNow()
        XCTAssertEqual(absent.search, "chrome")
        XCTAssertEqual(absent.scope, .mine)
        XCTAssertFalse(absent.pidColumnVisible)
    }
}
