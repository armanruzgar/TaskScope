import AppKit
import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The detail sheet, Copy Command Line, and where they appear.
@MainActor
final class ProcessCommandLineCopyTests: XCTestCase {
    private let process = AppProcess.fixture(
        pid: 4242, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1,
        command: "/usr/bin/python3", executablePath: "/usr/bin/python3", elapsedTime: "00:01",
        startTime: "Wed Oct 7 17:04:47 2026",
        netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
    )

    func testCopyWritesOnlyALoadedCommandLineAndNeverPutsItInTheMessage() async {
        var written: [String] = []
        let secret = "python3 worker.py --token=SECRET"
        let copied = await ProcessCommandLineCopy.perform(
            for: process, read: { _ in .loaded(secret) }, write: { written.append($0) }
        )
        XCTAssertEqual(written, [secret])
        XCTAssertEqual(copied, "Copied the command line of python3 (PID 4242).")
        XCTAssertFalse(copied.contains("SECRET"))

        for (result, reason) in [
            (CommandLineReadResult.identityChanged, "This PID now belongs to a different process."),
            (.gone, "This process is no longer running."),
            (.unavailable("ps exited with status 2"), "ps exited with status 2.")
        ] {
            let message = await ProcessCommandLineCopy.perform(for: process, read: { _ in result }, write: { written.append($0) })
            XCTAssertEqual(message, "Could not copy the command line of python3 (PID 4242). \(reason)")
        }
        XCTAssertEqual(written, [secret], "a refused read writes nothing")
    }

    func testClipboardEntryIsMarkedConfidential() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TaskScopeTests.CommandLine.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        ProcessCommandLineCopy.writeToClipboard("python3 worker.py", pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "python3 worker.py")
        XCTAssertTrue(pasteboard.types?.contains(ProcessCommandLineCopy.concealedType) == true)
    }

    /// The row's menu and VoiceOver actions offer the copy, and choosing it
    /// reads the row's own identity through the manager. A fake clipboard is
    /// used, so the real one is untouched.
    func testCopyCommandLineIsOfferedAndReadsTheRowIdentity() async throws {
        let detailReader = RecordingDetailReader(result: .loaded("python3 worker.py"))
        let inventory = ScriptedInventory(processes: [process])
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: FakeSignaler(), lifecycle: FakeLifecycle.forViewTests(),
            settleAfterProcessChange: {}, detailReader: detailReader,
            dependencies: .inert
        )
        manager.enableNotifications = false
        let fixture = await Batch10.fixture(processes: [process])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture, manager: manager)

        XCTAssertNoThrow(try view.processContextMenu(for: process).inspect().find(button: "Copy Command Line"))
        XCTAssertNoThrow(try view.processContextMenu(for: process).inspect().find(button: "Copy Executable Path"))
        XCTAssertNoThrow(try view.processAccessibilityActions(for: process).inspect().find(button: "Copy Command Line"))

        let clipboard = TextSink()
        view.copyCommandLine(of: process, write: { clipboard.texts.append($0) })
        let finished = await Batch10.waitUntil { manager.message == "Copied the command line of python3 (PID 4242)." }
        XCTAssertTrue(finished, manager.message)
        XCTAssertEqual(clipboard.texts, ["python3 worker.py"])
        let requested = await detailReader.requestedIdentities
        XCTAssertEqual(requested, [process.identity])
    }
}

@MainActor
private final class TextSink {
    var texts: [String] = []
}

private actor RecordingDetailReader: ProcessDetailReading {
    private let result: CommandLineReadResult
    private(set) var requestedIdentities: [ProcessIdentity] = []

    init(result: CommandLineReadResult) {
        self.result = result
    }

    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult {
        requestedIdentities.append(identity)
        return result
    }

    func readDetail(for process: AppProcess) async -> ProcessDetail? { nil }
}
