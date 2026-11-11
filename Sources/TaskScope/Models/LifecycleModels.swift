import Foundation

enum LifecycleJobState: String, Equatable, Sendable {
    case missing
    case alreadyLoaded
    case alreadyUnloaded
    case changed
    case failed
    case verified

    var displayName: String {
        switch self {
        case .missing: "Missing"
        case .alreadyLoaded: "Already loaded"
        case .alreadyUnloaded: "Already unloaded"
        case .changed: "Changed"
        case .failed: "Failed"
        case .verified: "Verified"
        }
    }
}

enum ProcessTerminationOutcome: Equatable, Sendable {
    /// SIGTERM (and any escalation) was sent to every match.
    case signalled
    /// The inventory read succeeded and nothing matched the name.
    case noMatchingProcesses
    /// The process list could not be read, so nothing was signalled and nothing
    /// is known about whether the target is running.
    case inventoryUnavailable
    /// At least one SIGTERM or SIGKILL request was rejected by the kernel.
    case signalRejected
    /// A rejected signal was followed by a complete inventory proving that every
    /// captured target identity had exited before escalation.
    case targetsExited
    /// SIGTERM was requested, but the inventory needed to safely identify which
    /// original processes still required escalation could not be read.
    case escalationUnavailable
}

enum TerminationPolicy: Equatable, Sendable {
    case graceful
    case gracefulThenForce

    var allowsEscalation: Bool {
        self == .gracefulThenForce
    }
}

struct LifecycleJobResult: Equatable, Sendable {
    var label: String
    var state: LifecycleJobState
    var detail: String

    var succeeded: Bool {
        ![.missing, .failed].contains(state)
    }
}

struct LifecycleBatchResult: Equatable, Sendable {
    var jobs: [LifecycleJobResult]

    static let notNeeded = LifecycleBatchResult(jobs: [])

    var succeeded: Bool {
        jobs.allSatisfy(\.succeeded)
    }

    var didChangeState: Bool {
        jobs.contains { $0.state == .changed }
    }

    var failureSummary: String? {
        let failures = jobs.filter { !$0.succeeded }
        guard !failures.isEmpty else { return nil }
        // Every caller ends the summary with its own period, so a detail that
        // is a full sentence loses its own; otherwise messages end in "..".
        return failures.map { job in
            let detail = job.detail.hasSuffix(".") ? String(job.detail.dropLast()) : job.detail
            return "\(job.label): \(detail)"
        }.joined(separator: "; ")
    }
}

struct LifecycleReport: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var jobs: [LifecycleJobResult]
}
