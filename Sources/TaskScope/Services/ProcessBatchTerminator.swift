import Darwin
import Foundation

protocol ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool
    /// Like `send`, but distinguishes a target that no longer exists from a
    /// signal the kernel refused.
    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery
    func isAlive(_ pid: Int32) -> Bool
}

extension ProcessSignaling {
    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        send(signal, to: pid) ? .delivered : .rejected(errno: EPERM)
    }
}

struct DarwinProcessSignaler: ProcessSignaling {
    /// `kill(2)`'s result and the `errno` it left, read together.
    typealias KillCall = @Sendable (_ pid: Int32, _ signal: Int32) -> (result: Int32, errno: Int32)

    /// The real system call. Only tests inject another, so the errno mapping
    /// below can be checked without signalling a process; the PID guard runs
    /// before any injected call as well.
    static let systemKill: KillCall = { pid, signal in
        errno = 0
        let result = Darwin.kill(pid, signal)
        return (result, errno)
    }

    private let kill: KillCall

    init(kill: @escaping KillCall = DarwinProcessSignaler.systemKill) {
        self.kill = kill
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        deliver(signal, to: pid) == .delivered
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        guard ProcessSignalGuard.isSignalablePID(pid) else {
            return .rejected(errno: EINVAL)
        }
        let call = kill(pid, signal)
        if call.result == 0 {
            return .delivered
        }
        return call.errno == ESRCH ? .noSuchProcess : .rejected(errno: call.errno)
    }

    func isAlive(_ pid: Int32) -> Bool {
        guard ProcessSignalGuard.isSignalablePID(pid) else { return false }
        let call = kill(pid, 0)
        guard call.result == 0 || call.errno == EPERM else { return false }
        return !ProcessSignalGuard.isZombie(pid)
    }
}

struct ProcessBatchTerminationOutcome {
    var report: ProcessBatchActionReport
    var message: String
    var inventoryError: String?
    var shouldClearSelection: Bool
    var shouldRefresh: Bool
    var wasCancelled = false
}

/// Revalidates a captured selection and performs one batch signal operation.
/// Presentation state and post-mutation inventory publishing remain owned by
/// `ProcessManager`.
@MainActor
struct ProcessBatchTerminator {
    private let inventory: any ProcessInventoryProviding
    private let signaler: any ProcessSignaling
    private let settleAfterProcessChange: () async -> Void
    private let currentPID: Int32

    init(
        inventory: any ProcessInventoryProviding,
        signaler: any ProcessSignaling,
        settleAfterProcessChange: @escaping () async -> Void,
        currentPID: Int32
    ) {
        self.inventory = inventory
        self.signaler = signaler
        self.settleAfterProcessChange = settleAfterProcessChange
        self.currentPID = currentPID
    }

    func terminate(
        _ requestedIdentities: [ProcessIdentity],
        forceKill: Bool
    ) async -> ProcessBatchTerminationOutcome {
        let title = forceKill ? "Force Stop Results" : "Stop Results"
        let inventoryResult = await inventory.load(fetchExtendedStats: false)
        guard !Task.isCancelled, case .success(let currentProcesses) = inventoryResult else {
            let error: String?
            if case .failure(let inventoryError) = inventoryResult {
                error = inventoryError.localizedDescription
            } else {
                error = nil
            }
            return ProcessBatchTerminationOutcome(
                report: ProcessBatchActionReport(
                    title: title,
                    targets: requestedIdentities.map {
                        ProcessTargetActionResult(
                            identity: $0,
                            name: displayName(for: $0),
                            state: .unverified
                        )
                    }
                ),
                message: "Could not verify selected processes.",
                inventoryError: error,
                shouldClearSelection: false,
                shouldRefresh: false,
                wasCancelled: Task.isCancelled || inventoryResult == .failure(.cancelled)
            )
        }

        let currentByIdentity = Dictionary(
            currentProcesses.filter { !$0.hasExited }.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let verified = requestedIdentities.compactMap { currentByIdentity[$0] }
        var targetResults = requestedIdentities.compactMap { identity -> ProcessTargetActionResult? in
            guard currentByIdentity[identity] == nil else { return nil }
            return ProcessTargetActionResult(
                identity: identity,
                name: displayName(for: identity),
                state: currentProcesses.contains { $0.pid == identity.pid && !$0.hasExited } ? .identityChanged : .stale
            )
        }
        let staleCount = targetResults.count
        let selfTargets = verified.filter { $0.pid == currentPID }
        targetResults.append(contentsOf: selfTargets.map {
            ProcessTargetActionResult(
                identity: $0.identity,
                name: $0.name,
                state: .selfProcess
            )
        })
        // A pid that may never be signalled (0, negative, or launchd) cannot
        // come from the parser, but the guard is enforced here regardless.
        let unsignalable = verified.filter {
            $0.pid != currentPID && !ProcessSignalGuard.isSignalablePID($0.pid)
        }
        targetResults.append(contentsOf: unsignalable.map {
            ProcessTargetActionResult(
                identity: $0.identity,
                name: $0.name,
                state: .signalRejected
            )
        })
        let signalTargets = verified.filter {
            $0.pid != currentPID && ProcessSignalGuard.isSignalablePID($0.pid)
        }
        guard !signalTargets.isEmpty else {
            sort(&targetResults, by: requestedIdentities)
            let message: String
            if selfTargets.isEmpty {
                message = "Selection changed; \(staleCount) no longer matched. Nothing was stopped."
            } else if staleCount == 0 {
                message = "TaskScope cannot stop itself; use Quit."
            } else {
                message = "Nothing was stopped; \(selfTargets.count) TaskScope target rejected, \(staleCount) no longer matched."
            }
            return ProcessBatchTerminationOutcome(
                report: ProcessBatchActionReport(title: title, targets: targetResults),
                message: message,
                inventoryError: nil,
                shouldClearSelection: true,
                shouldRefresh: true
            )
        }

        let signal: Int32 = forceKill ? SIGKILL : SIGTERM
        var acceptedIdentities: Set<ProcessIdentity> = []
        for process in signalTargets {
            switch signaler.deliver(signal, to: process.pid) {
            case .delivered:
                acceptedIdentities.insert(process.identity)
            case .noSuchProcess:
                // It exited between the identity check and the signal; the
                // requested outcome holds, so this is not a rejected signal.
                targetResults.append(ProcessTargetActionResult(
                    identity: process.identity,
                    name: process.name,
                    state: .stopped
                ))
            case .rejected(let code):
                targetResults.append(ProcessTargetActionResult(
                    identity: process.identity,
                    name: process.name,
                    state: .signalRejected,
                    detail: ProcessSignalGuard.refusalDetail(
                        for: process, currentPID: currentPID, currentUID: getuid(), errno: code
                    )
                ))
            }
        }
        if forceKill {
            await settleAfterProcessChange()
        } else {
            await Self.waitForExit(
                of: signalTargets.filter { acceptedIdentities.contains($0.identity) }.map(\.pid),
                signaler: signaler,
                settle: settleAfterProcessChange
            )
        }

        for process in signalTargets where acceptedIdentities.contains(process.identity) {
            targetResults.append(ProcessTargetActionResult(
                identity: process.identity,
                name: process.name,
                state: signaler.isAlive(process.pid) ? .requestedStillRunning : .stopped
            ))
        }
        sort(&targetResults, by: requestedIdentities)

        let stopped = targetResults.filter { $0.state == .stopped }.count
        var parts: [String] = []
        let stillRunning = targetResults.filter { $0.state == .requestedStillRunning }.count
        let rejected = targetResults.filter { $0.state == .signalRejected }.count
        if stillRunning > 0 { parts.append("\(stillRunning) still running") }
        if rejected > 0 { parts.append("\(rejected) signal\(rejected == 1 ? "" : "s") rejected") }
        if !selfTargets.isEmpty { parts.append("\(selfTargets.count) TaskScope target rejected") }
        if staleCount > 0 { parts.append("\(staleCount) no longer matched") }
        let summary = "\(forceKill ? "Force stopped" : "Stopped") \(stopped) of \(requestedIdentities.count) selected"
        let message = summary + (parts.isEmpty ? "." : "; " + parts.joined(separator: ", ") + ".")

        return ProcessBatchTerminationOutcome(
            report: ProcessBatchActionReport(title: title, targets: targetResults),
            message: message,
            inventoryError: nil,
            shouldClearSelection: true,
            shouldRefresh: true
        )
    }

    /// How many settles a delivered SIGTERM may wait for its targets to exit:
    /// ten production settles of 300 ms are the three-second graceful window
    /// that preset stops use.
    static let gracefulExitSettles = 10

    /// Waits after a delivered SIGTERM until every target has exited, for at
    /// most `gracefulExitSettles` settles. Manual Stop never escalates: this
    /// only decides when the outcome is read, so a process that needs more than
    /// one settle to shut down is not reported as still running. The first
    /// settle always runs, as before; the wait is attempt-bounded so a no-op
    /// test settle cannot spin.
    static func waitForExit(
        of pids: [Int32],
        signaler: any ProcessSignaling,
        settle: () async -> Void
    ) async {
        await settle()
        for _ in 1..<gracefulExitSettles {
            guard pids.contains(where: { signaler.isAlive($0) }) else { return }
            await settle()
        }
    }

    private func displayName(for identity: ProcessIdentity) -> String {
        identity.command.isEmpty
            ? "PID \(identity.pid)"
            : URL(fileURLWithPath: identity.command).lastPathComponent
    }

    private func sort(
        _ results: inout [ProcessTargetActionResult],
        by requestedIdentities: [ProcessIdentity]
    ) {
        results.sort { lhs, rhs in
            let lhsIndex = requestedIdentities.firstIndex(of: lhs.identity) ?? Int.max
            let rhsIndex = requestedIdentities.firstIndex(of: rhs.identity) ?? Int.max
            return lhsIndex < rhsIndex
        }
    }
}
