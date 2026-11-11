import Darwin
import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class Batch03LaunchctlTests: XCTestCase {
    // (e) launchctl failures for a user agent (fake runCommand; no shell runs)
    func testControlE1_launchctlDisableFailureIsReported() async {
        let harness = Batch03LaunchctlHarness(respond: { command in
            command.isLaunchctl("disable")
                ? .init(command: command, stdout: "", stderr: "Not privileged to disable service.", exitCode: 1)
                : .init(command: command, stdout: "", stderr: "", exitCode: 0)
        })
        let result = await ProcessLifecycleController.disableUserLaunchAgents(for: agentPreset(), runtime: harness.runtime())
        XCTAssertEqual(result.jobs.map(\.state), [.failed])
        XCTAssertEqual(result.jobs.first?.detail, "Not privileged to disable service.")
    }

    func testControlE2_launchctlBootstrapFailureIsReported() async {
        let harness = Batch03LaunchctlHarness(respond: { command in
            if command.isLaunchctl("print", "print-disabled") {
                return .init(command: command, stdout: "", stderr: "Could not find service \"example.agent\" in domain for user gui: 501", exitCode: 113)
            }
            if command.isLaunchctl("bootstrap") {
                return .init(command: command, stdout: "", stderr: "Bootstrap failed: 5: Input/output error", exitCode: 5)
            }
            return .init(command: command, stdout: "", stderr: "", exitCode: 0)
        })
        let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: agentPreset(), runtime: harness.runtime(label: "example.agent")
        )
        XCTAssertEqual(result.jobs.map(\.state), [.failed])
        XCTAssertEqual(result.jobs.first?.detail, "Bootstrap failed: 5: Input/output error")
    }

    func testControlE3_unreadablePlistLabelIsReported() async {
        let harness = Batch03LaunchctlHarness(respond: { command in
            .init(command: command, stdout: "", stderr: "", exitCode: 0)
        })
        let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: agentPreset(), runtime: harness.runtime(label: nil)
        )
        XCTAssertEqual(result.jobs.map(\.state), [.failed])
        XCTAssertEqual(result.jobs.first?.detail, "Could not read a valid Label from /Library/LaunchAgents/example.plist.")
        XCTAssertFalse(harness.commands.contains { $0.isLaunchctl("bootstrap") })
    }

    private func agentPreset() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(label: "example.agent", plistPath: "/Library/LaunchAgents/example.plist")]
        )
    }
}

final class Batch03LaunchctlHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable (ExternalCommand) -> ShellCommandResult
    private var recorded: [ExternalCommand] = []

    init(respond: @escaping @Sendable (ExternalCommand) -> ShellCommandResult) {
        self.respond = respond
    }

    var commands: [ExternalCommand] { lock.withLock { recorded } }

    func runtime(label: String? = "example.agent") -> ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: getuid(),
            fileExists: { _ in true },
            launchAgentLabel: { _ in label },
            runCommand: { [self] command, _ in
                lock.withLock { recorded.append(command) }
                return respond(command)
            },
            loadProcessInventory: { .success([]) },
            executablePathForPID: { _ in nil },
            sendSignal: { _, _ in false },
            isProcessAlive: { _ in false },
            sleep: { _ in },
            systemUptime: { 0 },
            isAppBundle: { _ in false }
        )
    }
}
