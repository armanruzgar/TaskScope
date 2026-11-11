import Darwin
import Foundation

/// Every side effect a lifecycle action can have: launchd commands, process
/// inventory reads, signals and waits. No member has a default: a runtime
/// built for a test must say what each one does, so a forgotten closure can
/// never reach the real system. Production code uses `.live`.
struct ProcessLifecycleRuntime: Sendable {
    var userID: uid_t
    var fileExists: @Sendable (String) -> Bool
    /// The `Label` of the plist at a path, or nil when it cannot be read.
    var launchAgentLabel: @Sendable (String) -> String?
    /// Runs one fixed tool, never through a shell.
    var runCommand: @Sendable (ExternalCommand, TimeInterval) async -> ShellCommandResult
    var loadProcessInventory: @Sendable () async -> Result<[AppProcess], ProcessInventoryError>
    var executablePathForPID: @Sendable (Int32) -> String?
    var sendSignal: @Sendable (Int32, Int32) -> Bool
    /// Liveness probe used while waiting for a graceful exit. Escalation itself
    /// never trusts it: the final SIGKILL decision is made from a fresh,
    /// identity-validated inventory.
    var isProcessAlive: @Sendable (Int32) -> Bool
    var sleep: @Sendable (UInt64) async -> Void
    var systemUptime: @Sendable () -> TimeInterval
    /// True when a path leads to an app bundle after following links. Open
    /// checks it first and again right before launching.
    var isAppBundle: @Sendable (String) -> Bool

    /// A signal to a target that no longer exists (`ESRCH`) counts as delivered:
    /// the process is not running, which is what the caller asked for. Any pid
    /// that may never be signalled is refused before `kill(2)`. Only tests pass
    /// another `kill`, so the mapping can be checked without signalling.
    static func liveSendSignal(
        _ signal: Int32,
        to pid: Int32,
        kill: DarwinProcessSignaler.KillCall = DarwinProcessSignaler.systemKill
    ) -> Bool {
        guard ProcessSignalGuard.isSignalablePID(pid) else { return false }
        let call = kill(pid, signal)
        if call.result == 0 {
            TaskScopeActionLog.signalSent(signal, to: pid, delivered: true)
            return true
        }
        guard call.errno != ESRCH else { return true }
        TaskScopeActionLog.signalSent(signal, to: pid, delivered: false, errorNumber: call.errno)
        return false
    }

    /// The real system, every member spelled out.
    static let live = ProcessLifecycleRuntime(
        userID: getuid(),
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        launchAgentLabel: { path in
            LaunchctlJobListing.plistLabel(at: path)
        },
        runCommand: { command, timeout in
            let result = await ShellCommandRunner.run(command, timeout: timeout)
            TaskScopeActionLog.commandFinished(command, result: result)
            return result
        },
        loadProcessInventory: {
            await ProcessListReader.currentProcessList(fetchExtendedStats: false)
        },
        executablePathForPID: { ProcessListReader.executablePath(for: $0) },
        sendSignal: { signal, pid in ProcessLifecycleRuntime.liveSendSignal(signal, to: pid) },
        isProcessAlive: { pid in DarwinProcessSignaler().isAlive(pid) },
        sleep: { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        systemUptime: { ProcessInfo.processInfo.systemUptime },
        isAppBundle: { SystemProcessLifecycleService.isAppBundle(at: $0) }
    )
}
