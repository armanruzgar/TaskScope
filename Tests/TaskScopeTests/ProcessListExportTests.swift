import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-19 part 4: the visible rows and columns as tab-separated text or CSV,
/// never with a command line.
final class ProcessListTableTests: XCTestCase {
    private func row(_ pid: Int32, name: String = "Worker", path: String? = "/usr/bin/worker", uid: uid_t? = 0) -> AppProcess {
        var process = AppProcess(
            pid: pid, parentPID: 1, uid: uid, cpu: 12.34, memoryMB: 256.6,
            command: path ?? name, executablePath: path, elapsedTime: "00:01", startTime: "",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
        process.netInRateKBps = 1.25
        process.netOutRateKBps = 0.5
        return process
    }

    func testColumnsFollowThePresentation() {
        XCTAssertEqual(ProcessListTable.columns(expandedWindow: false).map(\.title),
                       ["Name", "PID", "Executable", "CPU %", "Memory MB"])
        XCTAssertEqual(ProcessListTable.columns(expandedWindow: true).map(\.title), [
            "Name", "PID", "Executable", "PPID", "User", "Net In KB/s", "Net Out KB/s",
            "Disk Read MB/s", "Disk Write MB/s", "CPU %", "Memory MB"
        ])
        XCTAssertFalse(ProcessListTable.Column.allCases.contains { $0.title.localizedCaseInsensitiveContains("command") },
                       "no column carries a command line")
    }

    func testTabSeparatedTextHasTitlesAndTheListsValues() {
        let table = ProcessListTable(columns: ProcessListTable.columns(expandedWindow: true), rows: [row(42), row(43, uid: nil)])
        XCTAssertEqual(table.tabSeparated, """
        Name\tPID\tExecutable\tPPID\tUser\tNet In KB/s\tNet Out KB/s\tDisk Read MB/s\tDisk Write MB/s\tCPU %\tMemory MB
        worker\t42\t/usr/bin/worker\t1\troot\t1.2\t0.5\t\t\t12.3\t257
        worker\t43\t/usr/bin/worker\t1\t\t1.2\t0.5\t\t\t12.3\t257

        """, "a dash in the list is an empty value")
    }

    func testCSVQuotesWhatNeedsIt() {
        // The name is the path's last component: `a,b "c"` and a line break, then `d`.
        let odd = row(44, path: "/tmp/a,b \"c\"\nd")
        let table = ProcessListTable(columns: ProcessListTable.columns(expandedWindow: false), rows: [odd])
        XCTAssertEqual(
            table.commaSeparated,
            "Name,PID,Executable,CPU %,Memory MB\r\n"
                + "\"a,b \"\"c\"\"\nd\",44,\"/tmp/a,b \"\"c\"\"\nd\",12.3,257\r\n"
        )
        XCTAssertEqual(ProcessListTable(columns: [.name, .path], rows: [odd]).tabSeparated,
                       "Name\tExecutable\na,b \"c\" d\t/tmp/a,b \"c\" d\n",
                       "a line break inside a value becomes a space")
    }

    /// `-zsh` and `=cmd()` must not become formulas when pasted or opened.
    func testTextThatSpreadsheetsWouldEvaluateIsKeptAsText() {
        let shell = row(45, name: "-zsh", path: nil)
        let formula = row(46, name: "=HYPERLINK(\"x\")", path: nil)
        let table = ProcessListTable(columns: [.name, .pid], rows: [shell, formula])
        XCTAssertEqual(table.tabSeparated, "Name\tPID\n'-zsh\t45\n'=HYPERLINK(\"x\")\t46\n")
        XCTAssertEqual(table.commaSeparated, "Name,PID\r\n'-zsh,45\r\n\"'=HYPERLINK(\"\"x\"\")\",46\r\n")
        XCTAssertEqual(ProcessListTable.spreadsheetSafe("+1"), "'+1")
        XCTAssertEqual(ProcessListTable.spreadsheetSafe("@sum"), "'@sum")
        XCTAssertEqual(ProcessListTable.spreadsheetSafe("zsh"), "zsh")
        XCTAssertEqual(ProcessListTable.spreadsheetSafe(""), "")
    }

    @MainActor
    func testFileNameAndClipboardTypes() throws {
        XCTAssertEqual(
            ProcessListExport.suggestedFileName(at: Date(timeIntervalSince1970: 1_791_392_687), timeZone: TimeZone(identifier: "UTC")!),
            "TaskScope Processes 2026-10-07 at 17.04.47.csv"
        )
        XCTAssertEqual(ProcessListExport.rowCount(1), "1 row")
        XCTAssertEqual(ProcessListExport.rowCount(3), "3 rows")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TaskScopeTests.Rows.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let table = ProcessListTable(columns: [.name], rows: [row(47)])
        ProcessListExport.writeToClipboard(table, pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Name\nworker\n")
        XCTAssertEqual(pasteboard.string(forType: .tabularText), "Name\nworker\n")
    }
}

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
