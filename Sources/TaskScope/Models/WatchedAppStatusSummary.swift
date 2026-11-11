/// One watched app's state as automation reports it, read from the watched
/// snapshot TaskScope last verified. It never claims more than that snapshot
/// shows: while the status is unknown, the running fields are nil.
struct WatchedAppStatusSummary: Equatable, Sendable {
    var presetName: String
    /// Current after a successful read, stale when the last refresh failed
    /// after an earlier success, and unknown when no read has covered the preset.
    var availability: WatchedStatusAvailability
    var isMainAppRunning: Bool?
    var runningHelperCount: Int?
    /// The preset's stored Keep Off intent, whatever its processes are doing.
    var isKeptOff: Bool

    init(
        presetName: String,
        availability: WatchedStatusAvailability,
        isMainAppRunning: Bool?,
        runningHelperCount: Int?,
        isKeptOff: Bool
    ) {
        self.presetName = presetName
        self.availability = availability
        self.isMainAppRunning = isMainAppRunning
        self.runningHelperCount = runningHelperCount
        self.isKeptOff = isKeptOff
    }

    init(
        preset: WatchedAppPreset,
        snapshots: [WatchedAppSnapshot],
        availability: WatchedStatusAvailability,
        isKeptOff: Bool
    ) {
        let availability = availability.forPresets([preset], snapshots: snapshots)
        let snapshot = availability == .unknown ? nil : snapshots.first { $0.preset == preset }
        self.init(
            presetName: preset.displayName,
            availability: snapshot == nil ? .unknown : availability,
            isMainAppRunning: snapshot?.isMainRunning,
            runningHelperCount: snapshot?.helpersRunning.count,
            isKeptOff: isKeptOff
        )
    }

    /// The sentence Shortcuts, Siri and Spotlight show.
    var sentence: String {
        let keepOff = isKeptOff ? " Keep Off is on." : ""
        guard let isMainAppRunning, let runningHelperCount, availability != .unknown else {
            return "TaskScope could not verify the status of \(presetName)." + keepOff
        }
        let main = isMainAppRunning ? "main app running" : "main app not running"
        let helpers = switch runningHelperCount {
        case 0: "no helpers running"
        case 1: "1 helper running"
        default: "\(runningHelperCount) helpers running"
        }
        let lead = availability == .stale
            ? "\(presetName), as last observed before a failed refresh"
            : presetName
        return "\(lead): \(main), \(helpers)." + keepOff
    }
}
