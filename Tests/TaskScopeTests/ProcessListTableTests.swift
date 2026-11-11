import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-19 part 4: the visible rows and columns as tab-separated text or CSV,
/// never with a command line.
final class ProcessListTableTests: XCTestCase {
    private func row(_ pid: Int32, name: String = "Worker", path: String? = "/usr/bin/worker", owner: String? = "root") -> AppProcess {
        var process = AppProcess.fixture(
            pid: pid, parentPID: 1, uid: 0, ownerName: owner, cpu: 12.34, memoryMB: 256.6,
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
        let table = ProcessListTable(columns: ProcessListTable.columns(expandedWindow: true), rows: [row(42), row(43, owner: nil)])
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
