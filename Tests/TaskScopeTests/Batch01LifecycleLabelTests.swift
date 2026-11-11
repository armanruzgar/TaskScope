import XCTest
@testable import TaskScope

@MainActor
final class Batch01LifecycleLabelTests: XCTestCase {
    func testUnvalidatedLabelsCannotReachAnyUserAgentLifecycleCommand() async {
        for label in ["/", "/x", "//", "a/b", "/Users/test/Library/LaunchAgents/a.plist", "a\0b", "a\u{202E}b"] {
            let path = "/nonexistent-batch01/agent.plist"
            let harness = LifecycleRuntimeHarness(
                existingPaths: [path], launchAgentLabels: [path: label],
                commandResults: [], respond: { command in
                    .init(command: command, stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0)
                }
            )
            let preset = WatchedAppPreset(
                displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
                protectedProcessNames: [], appPath: "/nonexistent-batch01/Example.app",
                userLaunchAgentJobs: [.init(label: label, plistPath: path)]
            )
            let stopped = await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: harness.runtime)
            let disabled = await ProcessLifecycleController.disableUserLaunchAgents(for: preset, runtime: harness.runtime)
            let enabled = await ProcessLifecycleController.enableUserLaunchAgents(for: preset, runtime: harness.runtime)
            let started = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: harness.runtime)
            for result in [stopped, disabled, enabled, started] {
                XCTAssertEqual(result.jobs.map(\.state), [.failed], label)
                XCTAssertTrue(result.failureSummary?.contains("label") == true, label)
            }
            XCTAssertTrue(harness.commands.allSatisfy { $0.isLaunchctl("print-disabled") }, label)
            XCTAssertTrue(harness.signals.isEmpty, label)
        }
    }
}
