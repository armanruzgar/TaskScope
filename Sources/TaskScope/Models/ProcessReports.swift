import Foundation

enum ProcessTargetActionState: Equatable {
    case stopped
    case requestedStillRunning
    case stale
    case identityChanged
    case signalRejected
    /// The requested identity is TaskScope itself. It is deliberately never
    /// signalled; the app's Quit action is the safe path.
    case selfProcess
    /// The process list could not be read, so this target was never checked and
    /// never signalled. Distinct from `.stale`, which asserts the target is gone.
    case unverified

    var label: String {
        switch self {
        case .stopped:
            "Stopped"
        case .requestedStillRunning:
            "Still running"
        case .stale:
            "No longer running"
        case .identityChanged:
            "Identity changed"
        case .signalRejected:
            "Signal rejected"
        case .selfProcess:
            "Use Quit for TaskScope"
        case .unverified:
            "Could not verify"
        }
    }
}

struct ProcessTargetActionResult: Identifiable, Equatable {
    var identity: ProcessIdentity
    var name: String
    var state: ProcessTargetActionState
    var detail: String? = nil

    var id: ProcessIdentity {
        identity
    }
}

struct ProcessBatchActionReport: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var targets: [ProcessTargetActionResult]
}
