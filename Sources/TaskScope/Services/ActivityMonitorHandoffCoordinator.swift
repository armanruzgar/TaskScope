import AppKit
import Darwin
import Foundation

enum ActivityMonitorSelectionAttempt: Equatable, Sendable {
    case selected
    case notReady
    /// Activity Monitor stopped answering Accessibility requests during this
    /// attempt. The coordinator retries only while its time budget lasts.
    case unresponsive
    case accessibilityDenied(String)
    case failed(String)
}

enum ActivityMonitorHandoffOutcome: Equatable {
    case success
    case missingProcess
    case appLaunchFailed(String)
    case accessibilityDenied(String)
    case timedOut(lastError: String?)
    case cancelled

    func message(for pid: Int32) -> String {
        switch self {
        case .success:
            "Selected PID \(pid) in Activity Monitor."
        case .missingProcess:
            "PID \(pid) is no longer running or its identity could not be verified, so Activity Monitor could not select it."
        case .appLaunchFailed(let detail):
            "Could not open Activity Monitor: \(detail)"
        case .accessibilityDenied(let detail):
            "Activity Monitor opened, but Accessibility access is not granted. Allow TaskScope in System Settings > Privacy & Security > Accessibility, then try again. \(detail)"
        case .timedOut(let lastError):
            if let lastError, !lastError.isEmpty {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out: \(lastError)"
            } else {
                "Activity Monitor opened, but PID \(pid) could not be selected before the retry timed out."
            }
        case .cancelled:
            "Selecting PID \(pid) in Activity Monitor was cancelled."
        }
    }
}

@MainActor
protocol ActivityMonitorOpening {
    func open() async throws
}

/// Every handoff starts from a row, so the only check is the identity check:
/// a PID-only check would skip the start-time and executable-path binding.
@MainActor
protocol ActivityMonitorProcessChecking {
    func processMatches(identity: ProcessIdentity) -> Bool
}

@MainActor
protocol ActivityMonitorProcessSelecting {
    /// Async so the Accessibility traversal can run off the main actor.
    /// `timeout` bounds the Accessibility requests of this one attempt.
    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt
    /// Puts back any Activity Monitor state a handoff changed, without waiting
    /// for the scheduled restoration delay.
    func restorePreparedState()
}

extension ActivityMonitorProcessSelecting {
    func restorePreparedState() {}
}

@MainActor
protocol ActivityMonitorCoordinating {
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome
    func restoreActivityMonitorState()
}

extension ActivityMonitorCoordinating {
    func restoreActivityMonitorState() {}
}

@MainActor
final class ActivityMonitorCoordinator: ActivityMonitorCoordinating {
    static let notRespondingMessage = "Activity Monitor is not responding."

    private let opener: any ActivityMonitorOpening
    private let processChecker: any ActivityMonitorProcessChecking
    private let selector: any ActivityMonitorProcessSelecting
    private let maximumSelectionAttempts: Int
    private let retryDelayNanoseconds: UInt64
    private let selectionTimeBudget: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: @MainActor (UInt64) async -> Void
    /// Handoffs run one at a time. Overlapping handoffs share Activity
    /// Monitor's single search field and would keep replacing each other's
    /// search text until both timed out.
    private var isHandingOff = false
    private var waitingHandoffs: [CheckedContinuation<Void, Never>] = []

    convenience init() {
        self.init(
            opener: SystemActivityMonitorOpener(),
            processChecker: SystemActivityMonitorProcessChecker(),
            selector: SystemActivityMonitorProcessSelector()
        )
    }

    init(
        opener: any ActivityMonitorOpening,
        processChecker: any ActivityMonitorProcessChecking,
        selector: any ActivityMonitorProcessSelecting,
        maximumSelectionAttempts: Int = 8,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        selectionTimeBudget: TimeInterval = 5,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @MainActor (UInt64) async -> Void = { duration in
            try? await Task.sleep(nanoseconds: duration)
        }
    ) {
        self.opener = opener
        self.processChecker = processChecker
        self.selector = selector
        self.maximumSelectionAttempts = max(1, maximumSelectionAttempts)
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.selectionTimeBudget = max(0, selectionTimeBudget)
        self.now = now
        self.sleep = sleep
    }

    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        await waitForTurn()
        defer { finishTurn() }
        return await performHandoff(identity: identity)
    }

    private func waitForTurn() async {
        guard isHandingOff else {
            isHandingOff = true
            return
        }
        // The finishing handoff hands its turn over directly, so
        // `isHandingOff` stays true for this one.
        await withCheckedContinuation { waitingHandoffs.append($0) }
    }

    private func finishTurn() {
        if waitingHandoffs.isEmpty {
            isHandingOff = false
        } else {
            waitingHandoffs.removeFirst().resume()
        }
    }

    private func performHandoff(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        let pid = identity.pid
        func processMatches() -> Bool {
            processChecker.processMatches(identity: identity)
        }

        guard !Task.isCancelled else { return .cancelled }
        guard processMatches() else {
            return .missingProcess
        }

        do {
            try await opener.open()
        } catch {
            return .appLaunchFailed(error.localizedDescription)
        }

        // A wall-clock budget, not only an attempt count: an unresponsive
        // Activity Monitor makes every Accessibility request wait out its
        // timeout. It starts once Activity Monitor is open, so a cold launch
        // does not use it up.
        let deadline = now() + selectionTimeBudget
        var lastError: String?
        for attempt in 0..<maximumSelectionAttempts {
            guard !Task.isCancelled else { return .cancelled }
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            guard processMatches() else {
                return .missingProcess
            }

            switch await selector.select(pid: pid, timeout: remaining) {
            case .selected:
                // Selection suspends for Accessibility work; do not report success
                // if the selected process changed while that work was in flight.
                guard processMatches() else { return .missingProcess }
                return .success
            case .accessibilityDenied(let detail):
                return .accessibilityDenied(detail)
            case .failed(let detail):
                lastError = detail
            case .unresponsive:
                lastError = Self.notRespondingMessage
            case .notReady:
                break
            }

            if attempt < maximumSelectionAttempts - 1 {
                await sleep(retryDelayNanoseconds)
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        return .timedOut(lastError: lastError)
    }

    /// Called on app termination so a handoff whose restoration delay has not
    /// elapsed still leaves Activity Monitor as the user had it.
    func restoreActivityMonitorState() {
        selector.restorePreparedState()
    }
}

struct SystemActivityMonitorOpener: ActivityMonitorOpening {
    private static let applicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"
    )

    func open() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: Self.applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application == nil {
                    continuation.resume(throwing: ActivityMonitorOpenError.noApplicationReturned)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum ActivityMonitorOpenError: LocalizedError {
    case noApplicationReturned

    var errorDescription: String? {
        "macOS did not return a running Activity Monitor application."
    }
}

struct SystemActivityMonitorProcessChecker: ActivityMonitorProcessChecking {
    private let readStartTime: (Int32) -> (seconds: UInt64, microseconds: UInt64)?
    private let executablePathForPID: (Int32) -> String?

    init(
        readStartTime: ((Int32) -> (seconds: UInt64, microseconds: UInt64)?)? = nil,
        executablePathForPID: ((Int32) -> String?)? = nil
    ) {
        self.readStartTime = readStartTime ?? Self.startTime
        self.executablePathForPID = executablePathForPID ?? ProcessListReader.executablePath
    }

    func processMatches(identity: ProcessIdentity) -> Bool {
        guard identity.pid > 0,
              !identity.startTime.isEmpty,
              let expectedPath = identity.executablePath, !expectedPath.isEmpty,
              let start = readStartTime(identity.pid),
              let path = executablePathForPID(identity.pid),
              Self.samePath(kernelPath: path, inventoryPath: expectedPath),
              let verifiedStart = readStartTime(identity.pid), start == verifiedStart else { return false }

        // The inventory's `ps lstart` is normalized to C-locale UTC seconds.
        // Check the kernel start time on both sides of the kernel path read.
        return ProcessStartTime.psText(epochSeconds: Int(start.seconds)) == identity.startTime
    }

    /// The inventory stores standardized paths, which drop a leading /private
    /// (/private/tmp/x becomes /tmp/x), while proc_pidpath reports the
    /// /private form. Both name the same file, so compare like with like, as
    /// the termination controller does.
    static func samePath(kernelPath: String, inventoryPath: String) -> Bool {
        URL(fileURLWithPath: kernelPath).standardizedFileURL.path
            == URL(fileURLWithPath: inventoryPath).standardizedFileURL.path
    }

    private static func startTime(for pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
        // Unlike PROC_PIDTBSDINFO, KERN_PROC_PID exposes the same start-time
        // evidence as ps for visible processes owned by other users too.
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid, info.kp_proc.p_stat != UInt8(SZOMB) else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0 else { return nil }
        return (UInt64(start.tv_sec), UInt64(start.tv_usec))
    }
}
