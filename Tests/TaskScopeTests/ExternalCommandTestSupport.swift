import Foundation
@testable import TaskScope

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
