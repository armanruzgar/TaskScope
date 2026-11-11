enum ProcessStatus: Equatable, Sendable {
    case idle
    case helpersOnly
    case protectedOnly
    case watchedRunning

    var title: String {
        switch self {
        case .idle:
            "Quiet"
        case .helpersOnly:
            "Helpers"
        case .protectedOnly:
            "Services"
        case .watchedRunning:
            "Active"
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            "No watched apps running"
        case .helpersOnly:
            "Background helpers running"
        case .protectedOnly:
            "Protected services running"
        case .watchedRunning:
            "Watched app running"
        }
    }
}

enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory
    case name
    case pid
    case parentPID = "ppid"
    case user
    case network
    case disk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .name: "Name"
        case .pid: "PID"
        case .parentPID: "Parent PID"
        case .user: "User"
        case .network: "Network"
        case .disk: "Disk"
        }
    }

    /// The usage columns start busiest first: the display limit applies after
    /// sorting, so an ascending default would list the idlest processes. The
    /// others start in alphabetical or lowest-first order.
    var defaultDirection: ProcessSortDirection {
        switch self {
        case .cpu, .memory, .network, .disk: .descending
        case .name, .pid, .parentPID, .user: .ascending
        }
    }

    /// Network and disk counters are read only while something shows or
    /// sorts by them.
    var needsExtendedStats: Bool {
        self == .network || self == .disk
    }
}

/// Whether the last displayed watched snapshots can describe current state.
enum WatchedStatusAvailability: Equatable, Sendable {
    case unknown
    case current
    case stale

    var title: String? {
        switch self {
        case .unknown: "Unknown"
        case .current: nil
        case .stale: "Stale"
        }
    }

    var detail: String? {
        switch self {
        case .unknown: "Watched status has not been verified"
        case .current: nil
        case .stale: "Last observed status; refresh failed"
        }
    }

    func forPresets(_ presets: [WatchedAppPreset], snapshots: [WatchedAppSnapshot]) -> Self {
        guard presets.allSatisfy({ preset in snapshots.contains { $0.preset == preset } }) else {
            return .unknown
        }
        return self
    }
}
