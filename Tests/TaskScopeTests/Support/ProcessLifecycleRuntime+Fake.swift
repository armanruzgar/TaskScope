import Foundation
import XCTest
@testable import TaskScope

extension ProcessLifecycleRuntime {
    /// A runtime for tests (L07-8). Pass the members the test expects to be
    /// reached; any other member fails the test when reached and answers with
    /// a failure. So every launchd command, inventory read, signal, wait and
    /// clock a test can reach is one it wrote, and `.live` stays the only real
    /// runtime.
    static func fake(
        userID: uid_t = 501,
        fileExists: (@Sendable (String) -> Bool)? = nil,
        launchAgentLabel: (@Sendable (String) -> String?)? = nil,
        runCommand: (@Sendable (ExternalCommand, TimeInterval) async -> ShellCommandResult)? = nil,
        loadProcessInventory: (@Sendable () async -> Result<[AppProcess], ProcessInventoryError>)? = nil,
        executablePathForPID: (@Sendable (Int32) -> String?)? = nil,
        sendSignal: (@Sendable (Int32, Int32) -> Bool)? = nil,
        isProcessAlive: (@Sendable (Int32) -> Bool)? = nil,
        sleep: (@Sendable (UInt64) async -> Void)? = nil,
        systemUptime: (@Sendable () -> TimeInterval)? = nil,
        isAppBundle: (@Sendable (String) -> Bool)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ProcessLifecycleRuntime {
        @Sendable func unexpected(_ member: String) {
            XCTFail("Unexpected runtime call \(member): the test did not provide it", file: file, line: line)
        }
        return ProcessLifecycleRuntime(
            userID: userID,
            fileExists: fileExists ?? { unexpected("fileExists(\($0))"); return false },
            launchAgentLabel: launchAgentLabel ?? { unexpected("launchAgentLabel(\($0))"); return nil },
            runCommand: runCommand ?? { command, _ in
                unexpected("runCommand(\(command))")
                return ShellCommandResult(
                    command: command.description, stdout: "",
                    stderr: "The test did not provide this command.", exitCode: 1
                )
            },
            loadProcessInventory: loadProcessInventory ?? {
                unexpected("loadProcessInventory")
                return .failure(.commandFailed("The test did not provide a process inventory."))
            },
            executablePathForPID: executablePathForPID ?? { unexpected("executablePathForPID(\($0))"); return nil },
            sendSignal: sendSignal ?? { signal, pid in unexpected("sendSignal(\(signal), \(pid))"); return false },
            isProcessAlive: isProcessAlive ?? { unexpected("isProcessAlive(\($0))"); return false },
            sleep: sleep ?? { _ in unexpected("sleep") },
            systemUptime: systemUptime ?? { unexpected("systemUptime"); return 0 },
            isAppBundle: isAppBundle ?? { unexpected("isAppBundle(\($0))"); return false }
        )
    }
}
