import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L15-6: flows that only work while SwiftUI keeps the popover's own state,
/// on the popover installed in a window (`hosted`): a sheet presented from
/// `@State`, and the detail the detail sheet's `.task` reads.
@MainActor
final class HostedPopoverTests: XCTestCase {
    func testSaveCurrentSelectionOpensItsSheetAndSavesTheSelection() async throws {
        let alpha = Batch10.process(61, name: "Alpha")
        let beta = Batch10.process(62, name: "Beta")
        let fixture = await Batch10.fixture(processes: [alpha, beta])
        defer { fixture.stores.cleanup() }
        fixture.manager.select([alpha, beta])
        let view = try await hosted(Batch10.popover(fixture))

        XCTAssertThrowsError(try view.find(SaveSelectionSheet.self), "No sheet before it is asked for")
        try view.find(button: "Save Current Selection…").tap()
        let sheet = try view.find(SaveSelectionSheet.self)
        XCTAssertNoThrow(try sheet.find(text: "Save 2 selected processes as a named selection for quick recall."))
        XCTAssertTrue(try sheet.find(button: "Save").isDisabled(), "An empty name cannot be saved")
        try sheet.find(ViewType.TextField.self).setInput("Work")
        try view.find(SaveSelectionSheet.self).find(button: "Save").tap()

        XCTAssertEqual(fixture.stores.savedSelections.selections.map(\.name), ["Work"])
        XCTAssertEqual(Set(fixture.stores.savedSelections.selections.first?.pids ?? []), [alpha.pid, beta.pid])
        XCTAssertThrowsError(try view.find(SaveSelectionSheet.self), "Saving closes the sheet")
    }

    func testCancellingTheSaveSheetSavesNothing() async throws {
        let alpha = Batch10.process(61, name: "Alpha")
        let fixture = await Batch10.fixture(processes: [alpha])
        defer { fixture.stores.cleanup() }
        fixture.manager.select([alpha])
        let view = try await hosted(Batch10.popover(fixture))

        try view.find(button: "Save Current Selection…").tap()
        let sheet = try view.find(SaveSelectionSheet.self)
        XCTAssertNoThrow(try sheet.find(text: "Save 1 selected process as a named selection for quick recall."))
        try sheet.find(ViewType.TextField.self).setInput("Unsaved")
        try sheet.find(button: "Cancel").tap()

        XCTAssertTrue(fixture.stores.savedSelections.selections.isEmpty)
        XCTAssertThrowsError(try view.find(SaveSelectionSheet.self), "Cancel closes the sheet")
    }

    func testTheDetailSheetShowsTheDetailItsReadReturns() async throws {
        let target = Batch10.process(71, name: "Target")
        let reader = ScriptedDetailReader([71: [.loaded(detail(for: target, user: "fixture-user"))]])
        let fixture = await Batch10.fixture(processes: [target], detailReader: reader)
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = try await hosted(Batch10.popover(fixture, state: state))

        state.detailProcess = target
        let shown = try await waitForSheet(in: view) { $0.detail != nil }

        XCTAssertEqual(shown.detail?.user, "fixture-user")
        XCTAssertEqual(reader.readPIDs, [71], "One read for the process the sheet shows")
    }

    func testAFailedDetailReadShowsTheFailureAndRetryReadsAgain() async throws {
        let target = Batch10.process(72, name: "Target")
        let reader = ScriptedDetailReader([72: [.readFailed("ps timed out"), .loaded(detail(for: target, user: "second"))]])
        let fixture = await Batch10.fixture(processes: [target], detailReader: reader)
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = try await hosted(Batch10.popover(fixture, state: state))

        state.detailProcess = target
        let failed = try await waitForSheet(in: view) { $0.failed }
        XCTAssertNil(failed.detail)
        XCTAssertEqual(failed.failure, .readFailed("ps timed out"))

        try view.find(ProcessDetailSheet.self).find(button: "Retry").tap()
        let loaded = try await waitForSheet(in: view) { $0.detail != nil }
        XCTAssertEqual(loaded.detail?.user, "second")
        XCTAssertEqual(reader.readPIDs, [72, 72])
    }

    func testClosingTheDetailSheetForgetsItsProcess() async throws {
        let target = Batch10.process(73, name: "Target")
        let reader = ScriptedDetailReader([73: [.loaded(detail(for: target, user: "fixture-user"))]])
        let fixture = await Batch10.fixture(processes: [target], detailReader: reader)
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = try await hosted(Batch10.popover(fixture, state: state))

        state.detailProcess = target
        _ = try await waitForSheet(in: view) { $0.detail != nil }
        try view.find(ProcessDetailSheet.self).find(button: "Close").tap()

        XCTAssertNil(state.detailProcess)
        XCTAssertThrowsError(try view.find(ProcessDetailSheet.self), "Close dismisses the sheet")
    }

    // MARK: Helpers

    private func detail(for process: AppProcess, user: String) -> ProcessDetail {
        ProcessDetail(pid: process.pid, parentPID: process.parentPID, user: user, startTime: process.startTime, command: process.command)
    }

    /// Waits until the installed popover's detail sheet satisfies `condition`;
    /// the sheet's `.task` reads asynchronously.
    private func waitForSheet(
        in view: InspectableView<ViewType.ClassifiedView>,
        timeout: TimeInterval = 10,
        _ condition: (ProcessDetailSheet) -> Bool
    ) async throws -> ProcessDetailSheet {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let sheet = try? view.find(ProcessDetailSheet.self).actualView(), condition(sheet) {
                return sheet
            }
            if Date() > deadline {
                XCTFail("The detail sheet never reached the expected state")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
