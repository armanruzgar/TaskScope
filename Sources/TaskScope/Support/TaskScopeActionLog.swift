import Darwin
import Foundation
import os

/// Records in the Unified Log every signal TaskScope sends and every command
/// that changes launchd state, opens an app or asks for administrator rights,
/// with its outcome, so what TaskScope did can be reconstructed after it quits:
/// `log show --predicate 'subsystem == "<bundle id>" AND category == "Actions"'`.
/// The action, signal, PID and outcome are public; process names, launchd
/// labels and command lines are private.
enum TaskScopeActionLog {
    static let category = "Actions"
    private static let logger = Logger(subsystem: TaskScopeLogging.subsystem(), category: category)

    /// After `kill(2)`: `delivered` is false when the kernel refused the signal.
    static func signalSent(_ signal: Int32, to pid: Int32, delivered: Bool, errorNumber: Int32 = 0) {
        let signalName = name(ofSignal: signal)
        let processName = processName(of: pid)
        if delivered {
            logger.notice(
                "Sent \(signalName, privacy: .public) to PID \(pid, privacy: .public) (\(processName, privacy: .private))."
            )
        } else {
            logger.error(
                "\(signalName, privacy: .public) to PID \(pid, privacy: .public) (\(processName, privacy: .private)) failed: errno \(errorNumber, privacy: .public)."
            )
        }
    }

    /// Logs a finished lifecycle command if it changed system state; reads such
    /// as `launchctl print` are not logged.
    static func commandFinished(_ command: String, result: ShellCommandResult) {
        guard let kind = loggedCommandKind(command) else { return }
        if result.exitCode == 0 {
            logger.notice(
                "\(kind, privacy: .public) succeeded: \(command, privacy: .private)"
            )
        } else {
            logger.error(
                "\(kind, privacy: .public) failed with exit status \(result.exitCode, privacy: .public): \(command, privacy: .private)"
            )
        }
    }

    /// The commands worth a record: launchctl verbs that change a job, opening
    /// an app, and osascript, which TaskScope runs only to request
    /// administrator approval for a system service change.
    static func loggedCommandKind(_ command: String) -> String? {
        let words = command.split(separator: " ", maxSplits: 2).map(String.init)
        guard let tool = words.first else { return nil }
        switch tool {
        case "/bin/launchctl":
            guard words.count > 1, mutatingLaunchctlVerbs.contains(words[1]) else { return nil }
            return "launchctl \(words[1])"
        case "/usr/bin/osascript":
            return "Administrator request"
        case "/usr/bin/open":
            return "Open application"
        default:
            return nil
        }
    }

    private static let mutatingLaunchctlVerbs: Set<String> = [
        "bootout", "bootstrap", "disable", "enable", "kickstart", "kill", "load", "unload", "remove"
    ]

    private static func name(ofSignal signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        default: "signal \(signal)"
        }
    }

    private static func processName(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "exited" }
        return String(cString: buffer)
    }
}
