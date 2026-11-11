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

/// A signal the user can send to one process from its context menu, besides
/// Stop and Force Stop. Each goes through the same revalidated single-PID path
/// as Stop: never to a process group, never to a PID whose identity changed.
enum ProcessSignalAction: String, CaseIterable, Sendable {
    case pause, resume, hangup, interrupt, user1, user2

    /// The Send Signal submenu, in menu order.
    static let sendSignalMenu: [ProcessSignalAction] = [.hangup, .interrupt, .user1, .user2]

    var signal: Int32 {
        switch self {
        case .pause: SIGSTOP
        case .resume: SIGCONT
        case .hangup: SIGHUP
        case .interrupt: SIGINT
        case .user1: SIGUSR1
        case .user2: SIGUSR2
        }
    }

    var signalName: String {
        switch self {
        case .pause: "SIGSTOP"
        case .resume: "SIGCONT"
        case .hangup: "SIGHUP"
        case .interrupt: "SIGINT"
        case .user1: "SIGUSR1"
        case .user2: "SIGUSR2"
        }
    }

    /// The action's name, as in "Pause is not available for …".
    var name: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        case .hangup: "Hangup"
        case .interrupt: "Interrupt"
        case .user1: "User 1"
        case .user2: "User 2"
        }
    }

    /// The menu item. Every action but Resume asks first, like Stop.
    var menuTitle: String {
        switch self {
        case .pause: "Pause…"
        case .resume: "Resume"
        default: "\(name) (\(signalName))…"
        }
    }

    var requiresConfirmation: Bool {
        self != .resume
    }

    var confirmationTitle: String {
        self == .pause ? "Pause Process?" : "Send \(name) Signal?"
    }

    func confirmTitle(for process: AppProcess) -> String {
        self == .pause ? "Pause \(process.name)" : "Send \(signalName) to \(process.name)"
    }

    func confirmationMessage(for process: AppProcess) -> String {
        let pid = String(process.pid)
        switch self {
        case .pause:
            return "Send SIGSTOP to PID \(pid). The process stops running until you choose Resume; a paused app does not respond and its windows may not redraw."
        case .resume:
            return "Send SIGCONT to PID \(pid)."
        case .hangup:
            return "Send SIGHUP to PID \(pid). Many services reload their configuration; other programs quit."
        case .interrupt:
            return "Send SIGINT to PID \(pid), as Control-C does in Terminal. Most programs quit."
        case .user1, .user2:
            return "Send \(signalName) to PID \(pid). Its meaning depends on the program; a program that does not handle it quits."
        }
    }

    /// The status line after a delivered signal.
    func deliveredMessage(for process: AppProcess) -> String {
        switch self {
        case .pause: "\(process.name) is paused. Choose Resume to let it run again."
        case .resume: "\(process.name) resumed."
        default: "Sent \(signalName) to \(process.name)."
        }
    }
}

/// What came of a signal sent with `ProcessManager.sendSignal`.
enum ProcessSignalOutcome: Equatable, Sendable {
    case delivered
    /// The captured PID is gone or exited; nothing was sent.
    case notRunning
    /// The PID now belongs to a different process; nothing was sent.
    case identityChanged
    /// Nothing was sent for a reason that may clear on its own, such as an
    /// unreadable process list or a cancelled request.
    case rejected
    /// Nothing was sent and retrying cannot change that.
    case refused
}

/// Which processes Pause, Resume and Send Signal may reach. Stopping a process
/// ends it; pausing one keeps it alive but frozen, which for a part of the
/// login session (the Dock, loginwindow, the preferences daemon) can leave the
/// whole session unresponsive. So these signals reach only the user's own
/// processes that are not TaskScope, launchd or the kernel, GlobalProtect, or a
/// macOS system component.
enum ProcessSignalEligibility {
    /// Executables in these folders are macOS system components.
    static let systemComponentPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    /// Apple's user-facing apps, which pause like any other app.
    static let systemAppPrefix = "/System/Applications/"
    static let globalProtectBundle = "/Applications/GlobalProtect.app/"
    static let globalProtectNames: Set<String> = ["GlobalProtect", "PanGPA", "PanGPS"]

    /// Why a process is not eligible.
    enum Reason: Equatable, Sendable {
        case taskScope, launchdOrKernel, otherUser, globalProtect, unverifiedExecutable, systemComponent
    }

    /// Why `process` is not eligible, or nil when it is.
    static func ineligibility(for process: AppProcess, currentPID: Int32, currentUID: uid_t) -> Reason? {
        if process.pid == currentPID { return .taskScope }
        if !ProcessSignalGuard.isSignalablePID(process.pid) { return .launchdOrKernel }
        guard process.uid == currentUID else { return .otherUser }
        let path = process.executablePath
        if globalProtectNames.contains(process.name) || path?.hasPrefix(globalProtectBundle) == true {
            return .globalProtect
        }
        guard let path else { return .unverifiedExecutable }
        return isSystemComponent(path) ? .systemComponent : nil
    }

    /// Why Pause, Resume and Send Signal are unavailable for `process`, or nil.
    static func refusal(for process: AppProcess, currentPID: Int32, currentUID: uid_t) -> String? {
        switch ineligibility(for: process, currentPID: currentPID, currentUID: currentUID) {
        case nil: nil
        case .taskScope: "TaskScope does not pause or signal itself."
        case .launchdOrKernel: "This PID cannot be signalled."
        case .otherUser: "Only your own processes can be paused or signalled."
        case .globalProtect: "GlobalProtect is controlled only through its preset."
        case .unverifiedExecutable: "Its executable could not be verified."
        case .systemComponent: "It is part of macOS; pausing or signalling it can leave your session unresponsive."
        }
    }

    /// Why Stop With Children is unavailable with `process` as the parent, or
    /// nil. The parent must pass the same checks as Pause and Send Signal:
    /// otherwise its family can be most of the session (launchd's is nearly
    /// every process, loginwindow's ends the session).
    static func familyStopRefusal(for process: AppProcess, currentPID: Int32, currentUID: uid_t) -> String? {
        switch ineligibility(for: process, currentPID: currentPID, currentUID: currentUID) {
        case nil: nil
        case .taskScope: "TaskScope cannot stop itself; use Quit to close TaskScope."
        case .launchdOrKernel: "This is launchd or the kernel task; stopping its children would stop most of your session."
        case .otherUser: "Only your own processes can be stopped with their children."
        case .globalProtect: "GlobalProtect is controlled only through its preset."
        case .unverifiedExecutable: "Its executable could not be verified."
        case .systemComponent: "It is part of macOS; stopping it and its children can log you out or leave your session unresponsive."
        }
    }

    static func isSystemComponent(_ path: String) -> Bool {
        guard !path.hasPrefix(systemAppPrefix) else { return false }
        return systemComponentPrefixes.contains { path.hasPrefix($0) }
    }
}

/// A process and its descendants, as the last validated inventory shows them.
enum ProcessFamily {
    struct Members: Equatable {
        /// Eligible live descendants, breadth first, children in PID order.
        var included: [AppProcess]
        /// Live descendants left out: each ineligible one and everything below it.
        var leftOutCount: Int
    }

    /// The live descendants of `parent`. A descendant that is not eligible is
    /// left out together with its whole subtree, so nothing below a process
    /// that may not be stopped is stopped; a recycled PID cannot make the walk
    /// loop.
    static func descendants(
        of parent: AppProcess,
        in inventory: [AppProcess],
        isEligible: (AppProcess) -> Bool
    ) -> Members {
        let children = Dictionary(grouping: inventory.filter { !$0.hasExited }, by: \.parentPID)
        func sortedChildren(of pid: Int32) -> [AppProcess] {
            (children[pid] ?? []).sorted { $0.pid < $1.pid }
        }
        var visited: Set<Int32> = [parent.pid]
        var queue = [parent.pid]
        var members = Members(included: [], leftOutCount: 0)
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for child in sortedChildren(of: pid) where !visited.contains(child.pid) {
                visited.insert(child.pid)
                if isEligible(child) {
                    members.included.append(child)
                    queue.append(child.pid)
                    continue
                }
                // Count the whole subtree under a process that is left out.
                members.leftOutCount += 1
                var skipped = [child.pid]
                while !skipped.isEmpty {
                    for descendant in sortedChildren(of: skipped.removeFirst()) where !visited.contains(descendant.pid) {
                        visited.insert(descendant.pid)
                        members.leftOutCount += 1
                        skipped.append(descendant.pid)
                    }
                }
            }
        }
        return members
    }
}
