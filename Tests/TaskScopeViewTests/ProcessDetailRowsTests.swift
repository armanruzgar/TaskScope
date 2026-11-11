import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The User column and the detail sheet's new rows.
@MainActor
final class ProcessDetailRowsTests: XCTestCase {
    func testWindowRowsShowTheOwnerAndRatesAndThePopoverDoesNot() throws {
        var process = Batch10.process(51)
        process.ownerName = "root"
        process.netInRateKBps = 12.5
        process.netOutRateKBps = 0.25
        func row(_ expanded: Bool) -> ProcessRow {
            ProcessRow(process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
                       isHighlightedCPU: false, isHighlightedMEM: false, showsExpandedMetrics: expanded,
                       stopAction: {}, toggleSelection: {})
        }
        let window = try row(true).inspect()
        XCTAssertNoThrow(try window.find(text: "root"))
        XCTAssertNoThrow(try window.find(text: "12.5 / 0.2"))
        XCTAssertNoThrow(try window.find(text: "—"), "no disk rate yet")
        XCTAssertTrue(try window.find(ViewType.VStack.self).accessibilityValue().string().contains("user root"))
        XCTAssertTrue(try window.find(ViewType.VStack.self).accessibilityValue().string().contains("disk unavailable"))
        XCTAssertThrowsError(try row(false).inspect().find(text: "root"))

        process.diskReadBytes = 10
        process.diskWriteBytes = 0
        XCTAssertTrue(try row(true).inspect().find(ViewType.VStack.self).accessibilityValue().string()
            .contains("disk rate shown after the next refresh"))

        // A row without a name shows a dash: drawing never looks one up, so
        // fixed data (README screenshots) cannot show this Mac's account name.
        process.uid = getuid()
        process.ownerName = nil
        let unnamed = try row(true).inspect()
        XCTAssertNoThrow(try unnamed.find(text: "—"))
        XCTAssertThrowsError(try unnamed.find(text: ProcessOwnerNames.name(for: getuid())))
        XCTAssertTrue(try unnamed.find(ViewType.VStack.self).accessibilityValue().string().contains("user unknown"))
    }

    func testDetailSheetShowsEveryNewRowSelectably() throws {
        let process = Batch10.process(51)
        var detail = ProcessDetail(pid: 51, parentPID: 7, user: "me", startTime: "Wed Oct 7 17:04:47 2026", command: "Example")
        detail.executablePath = .available("/Applications/Example.app/Contents/MacOS/Example")
        detail.parent = .running(name: "launchd")
        detail.threadCount = .available(9)
        detail.openFiles = .available(ProcessOpenFiles(
            descriptorCount: 31,
            listeningPorts: [ListeningPort(transport: .tcp, port: 8080), ListeningPort(transport: .udp, port: 5353)]
        ))
        detail.codeSignature = .signed(identifier: "com.example.app", teamID: "ABCDE12345", isPlatformBinary: false, isAdHoc: false)
        detail.commandLine = .loaded("Example --flag")
        let sheet = ProcessDetailSheet(
            process: process, detail: detail, failed: false,
            now: Date(timeIntervalSince1970: 1_791_392_687 + 90_061), onClose: {}
        )
        let inspected = try sheet.inspect()
        for (label, value) in [
            ("Parent", "launchd (7)"), ("Elapsed", "1 day, 01:01:01"),
            ("Executable", "/Applications/Example.app/Contents/MacOS/Example"),
            ("Code Signature", "com.example.app, Team ID ABCDE12345"), ("Threads", "9"),
            ("Open Files", "31"), ("Listening Ports", "TCP 8080; UDP 5353"), ("Command Line", "Example --flag")
        ] {
            XCTAssertNoThrow(try inspected.find(text: label), label)
            XCTAssertNoThrow(try inspected.find(text: value), value)
        }
        XCTAssertTrue(try inspected.vStack().textSelectability(), "every value can be selected")

        detail.threadCount = .unavailable("macOS shows this only for your own processes.")
        detail.parent = .exited
        let refused = try ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {}).inspect()
        XCTAssertNoThrow(try refused.find(text: "macOS shows this only for your own processes."))
        XCTAssertNoThrow(try refused.find(text: "PID 7, no longer running"))
    }
}
