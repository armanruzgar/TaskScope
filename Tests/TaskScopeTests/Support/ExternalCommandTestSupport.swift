import Darwin
import Foundation
@testable import TaskScope

extension ShellCommandRunner {
    /// Runs shell syntax for a test, through an explicit `/bin/sh -c`.
    /// TaskScope itself never starts a shell.
    static func runShellScript(
        _ script: String,
        timeout: TimeInterval = 15,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        },
        hooks: Hooks = Hooks()
    ) async -> ShellCommandResult {
        await run(
            executable: "/bin/sh", arguments: ["-c", script],
            timeout: timeout, waitForChild: waitForChild, hooks: hooks
        )
    }
}

/// Fakes answer with the command they were handed; the result names it the
/// way the runner does.
extension ShellCommandResult {
    init(
        command: ExternalCommand,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        terminatedBySignal: Int32? = nil
    ) {
        self.init(
            command: command.description,
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            terminatedBySignal: terminatedBySignal
        )
    }
}

/// Fakes match commands by their argument vectors, never by substrings of a
/// command line.
extension ExternalCommand {
    /// `/bin/launchctl` whose first argument is one of `verbs`.
    func isLaunchctl(_ verbs: String...) -> Bool {
        executable == "/bin/launchctl" && arguments.first.map(verbs.contains) == true
    }

    /// True when any element of the argument vector contains `text`. For
    /// "never" assertions, so a word inside an administrator script counts too.
    func mentions(_ text: String) -> Bool {
        argumentVector.contains { $0.contains(text) }
    }

    /// An administrator request: osascript, the only tool that asks for it.
    var isAdministratorRequest: Bool {
        executable == "/usr/bin/osascript"
    }

    /// The AppleScript of an administrator request, which is osascript's one
    /// `-e` argument, or nil for any other command.
    var administratorAppleScript: String? {
        guard isAdministratorRequest, arguments.count == 2, arguments[0] == "-e" else { return nil }
        return arguments[1]
    }
}
