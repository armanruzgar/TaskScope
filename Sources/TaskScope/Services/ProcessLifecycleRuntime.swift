import Darwin
import Foundation

struct ProcessLifecycleRuntime: Sendable {
    var userID: uid_t
    var fileExists: @Sendable (String) -> Bool
    var launchAgentLabel: @Sendable (String) -> String? = { path in
        LaunchctlJobListing.plistLabel(at: path)
    }

    var runCommand: @Sendable (String, TimeInterval) async -> ShellCommandResult
    var loadProcessInventory: @Sendable () async -> Result<[AppProcess], ProcessInventoryError>
    var executablePathForPID: @Sendable (Int32) -> String? = {
        ProcessListReader.executablePath(for: $0)
    }
    var sendSignal: @Sendable (Int32, Int32) -> Bool = { signal, pid in
        ProcessLifecycleRuntime.liveSendSignal(signal, to: pid)
    }
    /// Liveness probe used while waiting for a graceful exit. Escalation itself
    /// never trusts it: the final SIGKILL decision is made from a fresh,
    /// identity-validated inventory.
    var isProcessAlive: @Sendable (Int32) -> Bool = { pid in
        DarwinProcessSignaler().isAlive(pid)
    }
    var sleep: @Sendable (UInt64) async -> Void
    var systemUptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// True when a path leads to an app bundle after following links. Open
    /// checks it first and again right before launching.
    var isAppBundle: @Sendable (String) -> Bool = { SystemProcessLifecycleService.isAppBundle(at: $0) }

    /// A signal to a target that no longer exists (`ESRCH`) counts as delivered:
    /// the process is not running, which is what the caller asked for. Any pid
    /// that may never be signalled is refused before `kill(2)`.
    static func liveSendSignal(_ signal: Int32, to pid: Int32) -> Bool {
        guard ProcessSignalGuard.isSignalablePID(pid) else { return false }
        errno = 0
        if Darwin.kill(pid, signal) == 0 {
            return true
        }
        return errno == ESRCH
    }

    static let live = ProcessLifecycleRuntime(
        userID: getuid(),
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        runCommand: { command, timeout in
            await ShellCommandRunner.run(command, timeout: timeout)
        },
        loadProcessInventory: {
            await ProcessListReader.currentProcessList(fetchExtendedStats: false)
        },
        executablePathForPID: { ProcessListReader.executablePath(for: $0) },
        sendSignal: { signal, pid in ProcessLifecycleRuntime.liveSendSignal(signal, to: pid) },
        isProcessAlive: { pid in DarwinProcessSignaler().isAlive(pid) },
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    )
}
