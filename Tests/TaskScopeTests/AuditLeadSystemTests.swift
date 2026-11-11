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
        let oversized = String(repeating: "x", count: 2 * 1_048_576)

        let result = await ShellCommandRunner.run(executable: "/usr/bin/true", arguments: [oversized], hooks: hooks)

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Could not start the command: Argument list too long.")
        XCTAssertEqual(pipes.created.count, 4)
        XCTAssertEqual(pipes.stillOpenPipeEnds, [], "A created pipe was left open")
    }
}
