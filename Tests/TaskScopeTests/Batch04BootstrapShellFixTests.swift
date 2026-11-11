import Foundation
import XCTest
@testable import TaskScope

final class Batch04BootstrapShellFixTests: XCTestCase {
    func testPrivilegedBootstrapBranchesWithOnlyFakeShellCommands() async throws {
        let job = WatchedAppPreset.globalProtectSystemDaemon
        for (enable, loaded, bootstrap, expected, verbs) in [
            (7, false, 0, 7, ["enable"]), (0, true, 0, 0, ["enable", "print"]),
            (0, false, 0, 0, ["enable", "print", "bootstrap"]), (0, false, 9, 9, ["enable", "print", "bootstrap"])
        ] {
            let body = ProcessLifecycleController.adminBootstrapScript(for: job).replacingOccurrences(of: "/bin/launchctl", with: "fake_launchd")
            guard !body.contains("launchctl") else { return XCTFail("Refusing to execute a script containing a real launchctl command") }
            let script = """
            exec 3>&1
            fake_launchd() {
              echo "$*" >&3
              case "$1" in
                enable) return \(enable);;
                print) return \(loaded ? 0 : 113);;
                bootstrap) return \(bootstrap);;
                *) return 99;;
              esac
            }
            \(body)
            """
            let result = await ShellCommandRunner.run("/bin/sh -c \(ShellCommandRunner.shellQuoted(script))", timeout: 5)
            XCTAssertEqual(result.exitCode, Int32(expected))
            let calls = result.stdout.split(separator: "\n").map(String.init)
            XCTAssertEqual(calls.map { String($0.split(separator: " ")[0]) }, verbs)
            if verbs.contains("bootstrap") { XCTAssertEqual(calls.last, "bootstrap system \(job.plistPath)") }
        }
    }
}
