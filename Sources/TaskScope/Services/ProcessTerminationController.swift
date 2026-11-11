import Darwin
import Foundation

enum ProcessTerminationController {
    /// How long a target is given to exit after SIGTERM before an escalating
    /// policy sends SIGKILL. Confirmation dialogs quote this value.
    static let gracefulExitWindowSeconds: TimeInterval = 3
    /// Liveness is re-checked this often during the graceful window so a target
    /// that exits promptly does not hold the action open for the whole window.
    static let livenessPollNanoseconds: UInt64 = 250_000_000

    static func settle(runtime: ProcessLifecycleRuntime) async {
        await runtime.sleep(300_000_000)
    }

    /// Signals current-user processes named `name` that run from inside
    /// `expectedExecutableDirectory`. The directory is mandatory: a name alone
    /// is never sufficient to signal a process.
    static func terminate(
        named name: String,
        policy: TerminationPolicy,
        expectedExecutableDirectory: String,
        excludingPID currentPID: Int32,
        runtime: ProcessLifecycleRuntime
    ) async -> ProcessTerminationOutcome {
        let outcomes = await terminate(
            requests: [Request(name: name, expectedExecutableDirectory: expectedExecutableDirectory)],
            policy: policy,
            excludingPID: currentPID,
            runtime: runtime
        )
        return outcomes[0]
    }

    /// One scoped stop target: a process name and the directory its executable
    /// must run from.
    struct Request: Equatable, Sendable {
        var name: String
        var expectedExecutableDirectory: String
    }

    /// Stops several scoped names as one operation: one inventory read before
    /// SIGTERM, one shared graceful window, and one identity-validated read
    /// before SIGKILL. Every target passes the same checks as a single-name
    /// stop (current user, executable directory, kernel path immediately before
    /// signalling), and a process matched by two names is signalled only once.
    /// Outcomes are returned per request, in request order.
    static func terminate(
        requests: [Request],
        policy: TerminationPolicy,
        excludingPID currentPID: Int32,
        runtime: ProcessLifecycleRuntime
    ) async -> [ProcessTerminationOutcome] {
        guard !requests.isEmpty else { return [] }
        guard case .success(let initialInventory) = await runtime.loadProcessInventory() else {
            return requests.map { _ in .inventoryUnavailable }
        }

        let termTargets = requests.map { request in
            terminationTargets(
                named: request.name,
                expectedExecutableDirectory: request.expectedExecutableDirectory,
                excludingPID: currentPID,
                currentUID: runtime.userID,
                in: initialInventory
            ).filter {
                ProcessSignalGuard.isSignalablePID($0.pid)
                    && executablePathStillMatches(
                        $0,
                        expectedExecutableDirectory: request.expectedExecutableDirectory,
                        runtime: runtime
                    )
            }
        }
        guard termTargets.contains(where: { !$0.isEmpty }) else {
            return requests.map { _ in .noMatchingProcesses }
        }

        var terms = SignalLedger(signal: SIGTERM)
        let signalWasRejected = termTargets.map { targets in
            targets.map { terms.send(to: $0, runtime: runtime) }.contains(false)
        }
        guard policy.allowsEscalation else {
            return termTargets.indices.map { index in
                termTargets[index].isEmpty
                    ? .noMatchingProcesses
                    : signalWasRejected[index] ? .signalRejected : .signalled
            }
        }

        await waitForGracefulExit(of: termTargets.flatMap { $0 }, runtime: runtime)
        guard case .success(let refreshedInventory) = await runtime.loadProcessInventory() else {
            return termTargets.indices.map { index in
                termTargets[index].isEmpty
                    ? .noMatchingProcesses
                    : signalWasRejected[index] ? .signalRejected : .escalationUnavailable
            }
        }

        var kills = SignalLedger(signal: SIGKILL)
        return requests.indices.map { index in
            guard !termTargets[index].isEmpty else { return .noMatchingProcesses }
            let request = requests[index]
            let originalIdentities = Set(termTargets[index].map(\.identity))
            let remainingTargets = terminationTargets(
                named: request.name,
                expectedExecutableDirectory: request.expectedExecutableDirectory,
                excludingPID: currentPID,
                currentUID: runtime.userID,
                in: refreshedInventory
            ).filter {
                // Implied by the identity check (every original target passed
                // it before SIGTERM), and kept as defence in depth.
                originalIdentities.contains($0.identity)
                    && ProcessSignalGuard.isSignalablePID($0.pid)
                    && executablePathStillMatches(
                        $0,
                        expectedExecutableDirectory: request.expectedExecutableDirectory,
                        runtime: runtime
                    )
            }
            if signalWasRejected[index], remainingTargets.isEmpty {
                return .targetsExited
            }
            let killWasRejected = remainingTargets.map { kills.send(to: $0, runtime: runtime) }.contains(false)
            return signalWasRejected[index] || killWasRejected ? .signalRejected : .signalled
        }
    }

    /// Sends one signal at most once per process identity, so a process that
    /// two requests both match is not signalled twice; a repeated target
    /// reports the kernel's first answer.
    private struct SignalLedger {
        let signal: Int32
        private var accepted: [ProcessIdentity: Bool] = [:]

        init(signal: Int32) {
            self.signal = signal
        }

        mutating func send(to process: AppProcess, runtime: ProcessLifecycleRuntime) -> Bool {
            if let earlier = accepted[process.identity] { return earlier }
            let result = runtime.sendSignal(signal, process.pid)
            accepted[process.identity] = result
            return result
        }
    }

    /// Polls liveness for up to the graceful window and returns early once
    /// every target has gone. Attempt-bounded so an injected no-op sleep cannot
    /// spin. The liveness probe only shortens the wait; whether anything is
    /// force-stopped is decided from a fresh identity-validated inventory.
    private static func waitForGracefulExit(
        of targets: [AppProcess],
        runtime: ProcessLifecycleRuntime
    ) async {
        let pollSeconds = Double(livenessPollNanoseconds) / 1_000_000_000
        let attempts = max(1, Int((gracefulExitWindowSeconds / pollSeconds).rounded(.up)))
        for _ in 0..<attempts {
            if targets.allSatisfy({ !runtime.isProcessAlive($0.pid) }) {
                return
            }
            await runtime.sleep(livenessPollNanoseconds)
        }
    }

    static func isRunning(
        named name: String,
        expectedExecutableDirectory: String?,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        guard case .success(let inventory) = await runtime.loadProcessInventory() else {
            return false
        }
        return !terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            currentUID: runtime.userID,
            in: inventory
        ).isEmpty
    }

    static func waitUntilRunning(
        named name: String,
        timeoutSeconds: TimeInterval,
        expectedExecutableDirectory: String?,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        let timeout = max(0, timeoutSeconds)
        let deadline = runtime.systemUptime() + timeout
        let attempts = Int((timeout / 0.3).rounded(.up))
        // A monotonic deadline includes inventory time; the attempt cap also
        // bounds injected clocks or sleeps that do not advance normally.
        for _ in 0..<attempts {
            guard !Task.isCancelled else { return false }
            guard runtime.systemUptime() < deadline else { break }
            if await isRunning(
                named: name,
                expectedExecutableDirectory: expectedExecutableDirectory,
                runtime: runtime
            ) {
                return true
            }
            guard !Task.isCancelled else { return false }
            let remaining = deadline - runtime.systemUptime()
            guard remaining > 0 else { break }
            await runtime.sleep(UInt64(min(0.3, remaining) * 1_000_000_000))
        }
        guard !Task.isCancelled else { return false }
        return await isRunning(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            runtime: runtime
        )
    }

    static func matchingProcesses(named name: String, in inventory: [AppProcess]) -> [AppProcess] {
        inventory.filter { $0.name == name }
    }

    /// Detection helper. A nil directory matches by name alone, which is
    /// acceptable for *observing* a process but never for signalling one; the
    /// signalling path requires a directory.
    static func terminationTargets(
        named name: String,
        expectedExecutableDirectory: String?,
        excludingPID: Int32,
        currentUID: uid_t,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        inventory.filter { process in
            guard process.pid != excludingPID, process.uid == currentUID else { return false }
            guard let expectedExecutableDirectory else {
                return process.name == name
            }
            guard let executablePath = process.executablePath,
                  executablePath.hasPrefix(expectedExecutableDirectory) else {
                return false
            }

            // `ps comm` is presentation-oriented and may be truncated or otherwise
            // differ from the executable name. For scoped lifecycle actions the
            // separately kernel-resolved vnode path is the stronger identity.
            return process.name == name
                || URL(fileURLWithPath: executablePath).lastPathComponent == name
        }
    }

    private static func executablePathStillMatches(
        _ process: AppProcess,
        expectedExecutableDirectory: String,
        runtime: ProcessLifecycleRuntime
    ) -> Bool {
        guard let inventoryPath = process.executablePath,
              let path = runtime.executablePathForPID(process.pid),
              path.hasPrefix("/") else {
            return false
        }
        // macOS has no pid handle. The refreshed start-time identity and repeated
        // vnode-path comparison narrow the residual exit/reuse race before kill(2).
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let standardizedInventoryPath = URL(fileURLWithPath: inventoryPath)
            .standardizedFileURL.path
        return standardizedPath == standardizedInventoryPath
            && standardizedPath.hasPrefix(expectedExecutableDirectory)
    }
}
