import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The menu items, the VoiceOver actions and what they copy or export. A fake
/// clipboard, save panel and file writer are used.
@MainActor
final class ProcessListExportViewTests: XCTestCase {
    func testRowActionsOfferCopyAndExport() async throws {
        let target = Batch10.process(500, name: "Example")
        let fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)
        let menu = try view.processContextMenu(for: target).inspect()
        XCTAssertNoThrow(try menu.find(button: "Copy Visible Rows"))
        XCTAssertNoThrow(try menu.find(button: "Export Visible Rows…"))
        let actions = try view.processAccessibilityActions(for: target).inspect()
        XCTAssertNoThrow(try actions.find(button: "Copy Visible Rows"))
        XCTAssertNoThrow(try actions.find(button: "Export Visible Rows…"))
    }

    func testCopyTakesTheDisplayedRowsAndColumns() async throws {
        var rows: [AppProcess] = []
        for index in 1...5 {
            let name = index == 5 ? "Other" : "Worker"
            rows.append(Batch10.process(Int32(600 + index), name: name, cpu: Double(index)))
        }
        let fixture = await Batch10.fixture(processes: rows)
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.searchText = "Worker"
        var copied: [ProcessListTable] = []
        Batch10.popover(fixture, style: .menuBarCompact).copyVisibleRows { copied.append($0) }
        XCTAssertEqual(copied.first?.rows.map(\.pid), [604, 603, 602, 601], "the search and the sort apply")
        XCTAssertEqual(copied.first?.columns, ProcessListTable.columns(expandedWindow: false))
        XCTAssertEqual(fixture.manager.message, "Copied 4 rows with their column titles.")

        copied = []
        Batch10.popover(fixture, style: .expandedWindow).copyVisibleRows { copied.append($0) }
        XCTAssertEqual(copied.first?.columns, ProcessListTable.columns(expandedWindow: true))

        fixture.stores.settings.searchText = "nothing matches"
        copied = []
        Batch10.popover(fixture).copyVisibleRows { copied.append($0) }
        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(fixture.manager.message, "There are no rows to copy.")
    }

    func testTreeViewCopiesTheRowsItDraws() async throws {
        let parent = Batch10.process(700, name: "Parent")
        let child = Batch10.process(701, parent: 700, name: "Child", cpu: 50)
        let fixture = await Batch10.fixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        let list = ProcessListInteractionState()
        list.treeMode = true
        list.expandedTreePids = [700]
        var copied: [ProcessListTable] = []
        Batch10.popover(fixture, listState: list).copyVisibleRows { copied.append($0) }
        XCTAssertEqual(copied.first?.rows.map(\.pid), [700, 701])
        list.expandedTreePids = []
        copied = []
        Batch10.popover(fixture, listState: list).copyVisibleRows { copied.append($0) }
        XCTAssertEqual(copied.first?.rows.map(\.pid), [700], "a collapsed child is not on screen")
    }

    func testExportWritesCSVWhereTheUserChoseAndReportsFailures() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(800, name: "Exported", cpu: 3)])
        defer { fixture.stores.cleanup() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TaskScopeTests.Export.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("rows.csv")
        let view = Batch10.popover(fixture)

        var suggested: [String] = []
        view.exportVisibleRows(chooseDestination: { suggested.append($0); return destination })
        XCTAssertEqual(suggested.count, 1)
        XCTAssertTrue(suggested[0].hasPrefix("TaskScope Processes ") && suggested[0].hasSuffix(".csv"), suggested[0])
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(written, view.visibleRowsTable.commaSeparated)
        XCTAssertTrue(written.hasPrefix("Name,PID,Executable,PPID,User,"))
        XCTAssertTrue(written.contains("Exported,800,"))
        XCTAssertEqual(fixture.manager.message, "Exported 1 row to rows.csv.")

        fixture.manager.setMessage("Idle.")
        var writes = 0
        view.exportVisibleRows(chooseDestination: { _ in nil }, write: { _, _ in writes += 1 })
        XCTAssertEqual(writes, 0, "a cancelled save panel writes nothing")
        XCTAssertEqual(fixture.manager.message, "Idle.")

        view.exportVisibleRows(
            chooseDestination: { _ in destination },
            write: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertTrue(fixture.manager.message.hasPrefix("Could not export the rows: "), fixture.manager.message)
    }
}
