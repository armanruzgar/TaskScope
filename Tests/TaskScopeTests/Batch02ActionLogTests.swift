import AppKit
import OSLog
import SwiftUI
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the URL scheme, accessibility labels, the
// Keep Off card in settings recovery, scene titles, persisted list options,
// the registry of running shell commands, and the action log.

// MARK: - URL scheme (A01-15, T05-3)

// MARK: - Action log (L11-22)

final class Batch02ActionLogTests: XCTestCase {
    /// Pause, Resume and User 1/2 were logged as "signal 17" and the like.
    func testActionLogNamesEverySignalTaskScopeSends() {
        XCTAssertEqual(TaskScopeActionLog.name(ofSignal: SIGTERM), "SIGTERM")
        XCTAssertEqual(TaskScopeActionLog.name(ofSignal: SIGKILL), "SIGKILL")
        for action in ProcessSignalAction.allCases {
            XCTAssertEqual(TaskScopeActionLog.name(ofSignal: action.signal), action.signalName, "\(action)")
        }
        XCTAssertEqual(TaskScopeActionLog.name(ofSignal: SIGWINCH), "signal \(SIGWINCH)")
    }

    func testOnlyCommandsThatChangeSystemStateAreLogged() {
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(.launchctl("bootout", "gui/501/com.example")),
                       "launchctl bootout")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(.launchctl("disable", "system/com.example")),
                       "launchctl disable")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(.launchctl("bootstrap", "gui/501", "/x.plist")),
                       "launchctl bootstrap")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(.launchctl("kickstart", "gui/501/com.example")),
                       "launchctl kickstart")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(.administratorScript("/usr/bin/true", prompt: "Test")),
                       "Administrator request")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind(ExternalCommand("/usr/bin/open", ["/Applications/Example.app"])),
                       "Open application")
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind(.launchctl("print", "system/com.example")))
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind(.launchctl("print-disabled", "system")))
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind(ExternalCommand("/bin/ps", ["-axo", "pid"])))
        // The verb is the first argument and the tool its exact path: a target
        // that names a verb, or another program called launchctl, is not one.
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind(.launchctl("print", "bootout")))
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind(ExternalCommand("/tmp/launchctl", ["bootout", "gui/501/x"])))
    }

    /// A stop signal and a launchd change leave a Unified Log record after the
    /// fact. The signalled process is this test's own child.
    func testSignalsAndLaunchdChangesAreRecordedInTheUnifiedLog() async throws {
        let since = Date().addingTimeInterval(-1)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer { if child.isRunning { child.terminate() } }

        XCTAssertEqual(DarwinProcessSignaler().deliver(SIGTERM, to: pid), .delivered)
        child.waitUntilExit()
        TaskScopeActionLog.commandFinished(
            .launchctl("bootout", "gui/501/com.example.batch02"),
            result: ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 0)
        )
        TaskScopeActionLog.commandFinished(
            .launchctl("print", "gui/501/com.example.batch02"),
            result: ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 0)
        )

        let subsystem = TaskScopeLogging.subsystem()
        var messages: [String] = []
        // Opening the process's log store takes seconds; one read normally
        // finds both entries.
        for _ in 0..<10 {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            messages = try store.getEntries(
                at: store.position(date: since),
                matching: NSPredicate(
                    format: "subsystem == %@ AND category == %@", subsystem, TaskScopeActionLog.category
                )
            )
            .compactMap { $0 as? OSLogEntryLog }
            .map(\.composedMessage)
            if messages.contains(where: { $0.contains("launchctl bootout") }),
               messages.contains(where: { $0.contains("PID \(pid)") }) {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertTrue(messages.contains { $0.contains("Sent SIGTERM to PID \(pid)") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("launchctl bootout succeeded") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains("launchctl print") }, "Reads are not logged: \(messages)")
    }
}
