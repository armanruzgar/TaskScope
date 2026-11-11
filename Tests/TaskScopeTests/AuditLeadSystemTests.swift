import Darwin
import XCTest
@testable import TaskScope

/// Leads from the November 2026 audit that verifiers noted but never checked:
/// child commands, Activity Monitor and the Open Watched App shortcut.
final class AuditLeadSystemTests: XCTestCase {
    // L05-4: `do shell script` hands osascript's environment to `/bin/sh`, and
    // with administrator privileges that shell runs as root. Variables that
    // change what a shell runs, exported bash functions and loader variables
    // never reach a child command; ordinary ones still do.
    func testChildCommandsDoNotInheritShellControlVariables() {
        let inherited = [
            "BASH_ENV": "/tmp/x", "ENV": "/tmp/y", "SHELLOPTS": "xtrace", "BASHOPTS": "extdebug",
            "PS4": "$(id)", "CDPATH": "/tmp", "GLOBIGNORE": "*", "IFS": "/",
            "BASH_FUNC_echo%%": "() { id; }", "DYLD_INSERT_LIBRARIES": "/tmp/z.dylib",
            "HOME": "/Users/example", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/example/", "USER": "example"
        ]
        XCTAssertEqual(ShellCommandRunner.childEnvironment(from: inherited), [
            "HOME": "/Users/example", "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp/example/", "USER": "example",
            "LC_CTYPE": "UTF-8", "LC_TIME": "C", "LC_NUMERIC": "C", "TZ": "UTC0"
        ])
    }

    // L04-5: no test reached the branch where posix_spawn itself fails. An
    // argument list over ARG_MAX makes it fail with E2BIG: the result has the
    // same shape as a pipe failure, and both pipes are closed.
    func testSpawnFailureIsReportedAndClosesItsPipes() async {
        let pipes = ScriptedPipeFactory(failingCall: 0)
        let hooks = batch05Hooks { hooks in hooks.makePipe = { pipes.make($0) } }
        let command = "/usr/bin/true " + String(repeating: "x", count: 2 * 1_048_576)

        let result = await ShellCommandRunner.run(command, hooks: hooks)

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Could not start the command: Argument list too long.")
        XCTAssertEqual(pipes.created.count, 4)
        XCTAssertEqual(pipes.stillOpenPipeEnds, [], "A created pipe was left open")
    }
}

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

@MainActor
final class AuditLeadIntentTests: XCTestCase {
    // T05-2: Open Watched App hard-coded the shared bus, so no test could
    // check what it submits.
    func testOpenWatchedAppSubmitsAnOpenForTheChosenPreset() async throws {
        let savedBus = OpenWatchedAppIntent.commandBus
        defer { OpenWatchedAppIntent.commandBus = savedBus }
        var submitted: [TaskScopeCommand] = []
        let bus = AppCommandBus()
        bus.install { command in
            submitted.append(command)
            return .init(status: .completed, message: "Opened Example.")
        }
        OpenWatchedAppIntent.commandBus = bus
        let intent = OpenWatchedAppIntent()
        intent.app = WatchedPresetEntity(id: UUID(), displayName: "Example")

        _ = try await intent.perform()

        XCTAssertEqual(submitted, [.openPresetEntity(intent.app.commandTarget)])
    }
}
