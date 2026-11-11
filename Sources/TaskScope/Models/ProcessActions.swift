import Darwin

enum ProcessActionResult: Equatable, Sendable {
    case stopped
    case requestedStillRunning
    /// A successful verification found the captured PID absent or already exited.
    case stale
    /// The PID is present, but its start time or executable evidence changed.
    case identityChanged
    /// Nothing was signalled for a reason that may clear on its own, such as an
    /// unreadable process list or a cancelled request. Retrying can succeed.
    case rejected
    /// Nothing was signalled and retrying cannot change that: the kernel denied
    /// the signal (for example `EPERM` on another user's process), or the target
    /// is TaskScope itself or a PID that must never be signalled.
    case refused

    var succeeded: Bool {
        self == .stopped
    }

    /// A stop signal was accepted but the process had not exited when it was
    /// last checked. The outcome is decided by a later observation, not by
    /// re-signalling immediately.
    var isAwaitingExit: Bool {
        self == .requestedStillRunning
    }
}

/// The kernel's answer to a signal request, as read from `errno`.
enum ProcessSignalDelivery: Equatable, Sendable {
    case delivered
    /// `ESRCH`: the target no longer exists. The requested outcome, a process
    /// that is not running, already holds.
    case noSuchProcess
    case rejected(errno: Int32)
}

/// PID values that must never reach `kill(2)`: 0 signals the caller's own
/// process group, a negative value signals a whole group, and 1 is launchd.
enum ProcessSignalGuard {
    /// Why a stop request for `process` was refused, worded the same for Stop,
    /// Force Stop, Stop Selected and Auto Stop. Retrying cannot change any of
    /// these. `errno` is the kernel's answer when a signal was attempted; a
    /// refusal of another user's process is explained by its owner, and `EPERM`
    /// for an own process needs no code.
    static func refusalDetail(
        for process: AppProcess,
        currentPID: Int32,
        currentUID: uid_t,
        errno code: Int32? = nil
    ) -> String {
        if process.pid == currentPID { return "TaskScope cannot stop itself; use Quit to close TaskScope." }
        if !isSignalablePID(process.pid) { return "This PID cannot be signalled." }
        if process.uid != currentUID { return "The process is not owned by the current user." }
        if let code, code != EPERM {
            return "The system refused the stop request (\(String(cString: strerror(code))))."
        }
        return "The system refused the stop request."
    }

    static func isSignalablePID(_ pid: Int32) -> Bool {
        pid > 1
    }

    /// `kill(pid, 0)` succeeds for a zombie, which has already exited and only
    /// awaits its parent's `waitpid`. When the kernel state can be read, a
    /// zombie is not alive; when it cannot (another user's process), the
    /// signal-based answer stands.
    static func isZombie(_ pid: Int32) -> Bool {
        zombieState(pid) == true
    }

    /// Whether the kernel reports `pid` as a zombie, or nil when its state
    /// cannot be read.
    static func zombieState(_ pid: Int32) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_proc.p_stat == UInt8(SZOMB)
    }
}

enum ProcessOperationState: Equatable {
    case idle
    case runningMutation
    case runningRefresh
    case queued
    case coalesced
}
