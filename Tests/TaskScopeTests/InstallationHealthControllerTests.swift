import Security
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class InstallationHealthControllerTests: XCTestCase {
    func testPermissionRevocationAndRecoveryRequireFreshEvidence() async {
        var current = healthReport()
        var opened: [InstallationHealthReport.Recovery] = []
        let controller = InstallationHealthController(collect: { _ in current },
            availableRecoveries: { [.systemSettings] }, performRecovery: { opened.append($0); return true }, now: { healthDate })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        XCTAssertEqual(controller.report?[.notifications].state, .healthy)
        controller.invalidate()
        let staleAttempt = await controller.recover(.systemSettings)
        XCTAssertFalse(staleAttempt)
        current = healthReport(notifications: .denied, accessibility: false, login: .requiresApproval)
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        XCTAssertEqual(controller.report?[.notifications].state, .denied)
        XCTAssertEqual(controller.report?[.accessibility].state, .unverified)
        let openedSettings = await controller.recover(.systemSettings)
        XCTAssertTrue(openedSettings)
        XCTAssertEqual(opened, [.systemSettings])
        XCTAssertTrue(controller.invalidated)
        XCTAssertEqual(controller.report?[.notifications].state, .denied)
    }

    func testRecoveryRechecksDestinationAndReportsOpenFailureWithoutAssumingRepair() async {
        var available: Set<InstallationHealthReport.Recovery> = [.systemSettings]
        var attempts = 0
        let controller = InstallationHealthController(collect: { _ in healthReport() },
            availableRecoveries: { available }, performRecovery: { _ in attempts += 1; return false }, now: { healthDate })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        available = []
        let missing = await controller.recover(.systemSettings)
        XCTAssertFalse(missing)
        XCTAssertEqual(attempts, 0)
        available = [.systemSettings]
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        let failed = await controller.recover(.systemSettings)
        XCTAssertFalse(failed)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.actionMessage?.contains("could not be opened") == true)
    }

    func testExpiredEvidenceCannotOpenRecoveryEvenBeforeViewRendersAgain() async {
        var date = healthDate
        var attempts = 0
        let controller = InstallationHealthController(collect: { _ in healthReport() },
            availableRecoveries: { [.systemSettings] }, performRecovery: { _ in attempts += 1; return true }, now: { date })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        date = healthDate.addingTimeInterval(61)
        let result = await controller.recover(.systemSettings)
        XCTAssertFalse(result)
        XCTAssertEqual(attempts, 0)
    }

    func testLateCollectionCannotOverwriteNewerAppReplacementResult() async {
        var first: CheckedContinuation<InstallationHealthReport, Never>?
        var calls = 0
        let controller = InstallationHealthController(collect: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { first = $0 } }
            return healthReport(identity: .stale)
        }, availableRecoveries: { [] }, performRecovery: { _ in XCTFail("Unexpected action"); return false }, now: { healthDate })
        controller.refresh(healthInput)
        for _ in 0..<100 where first == nil { await Task.yield() }
        XCTAssertNotNil(first)
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        first?.resume(returning: healthReport())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.report?[.bundleIdentity].state, .stale)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testRowDisplaysStateAndOnlyOfferedRecovery() throws {
        var selected: InstallationHealthReport.Recovery?
        let row = InstallationHealthRow(finding: healthReport(notifications: .denied)[.notifications]) { selected = $0 }
        XCTAssertNoThrow(try row.inspect().find(text: "Denied"))
        try row.inspect().find(button: "Open System Settings").tap()
        XCTAssertEqual(selected, .systemSettings)
        let stale = healthReport().displayedFindings(at: healthDate.addingTimeInterval(61), invalidated: false)[0]
        let staleRow = InstallationHealthRow(finding: stale) { _ in XCTFail("Stale action") }
        XCTAssertTrue(try staleRow.inspect().findAll(ViewType.Button.self).isEmpty)
        XCTAssertNoThrow(try staleRow.inspect().find(text: "Stale"))
    }

    private func waitForRefresh(_ controller: InstallationHealthController) async {
        for _ in 0..<100 where controller.isRefreshing { await Task.yield() }
        XCTAssertFalse(controller.isRefreshing)
    }
}
