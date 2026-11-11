/// What the menu-bar icon says while the popover is closed, derived from
/// values TaskScope already publishes. When several apply, the one that most
/// needs the user wins: a waiting Auto-Stop prompt, then a watched status that
/// could not be verified (no other watched state can be trusted then), then a
/// kept-off preset's service or agent that is running again, then a running
/// watched app.
enum MenuBarStatus: CaseIterable, Equatable, Sendable {
    case normal
    case watchedAppRunning
    case keepOffServiceRunning
    case statusUnknown
    case statusStale
    case autoStopPromptPending

    /// The mark drawn in the icon's corner. Unknown and stale share one.
    enum Badge: CaseIterable, Hashable, Sendable {
        case none
        case dot
        case warning
        case question
        case bell
    }

    var badge: Badge {
        switch self {
        case .normal: .none
        case .watchedAppRunning: .dot
        case .keepOffServiceRunning: .warning
        case .statusUnknown, .statusStale: .question
        case .autoStopPromptPending: .bell
        }
    }

    /// What VoiceOver reads for the status item; the plain state keeps the
    /// app's name alone.
    var accessibilityLabel: String {
        switch self {
        case .normal: "TaskScope"
        case .watchedAppRunning: "TaskScope, watched app running"
        case .keepOffServiceRunning: "TaskScope, Keep Off service running"
        case .statusUnknown: "TaskScope, watched status unknown"
        case .statusStale: "TaskScope, watched status stale"
        case .autoStopPromptPending: "TaskScope, Auto-Stop prompt waiting"
        }
    }

    /// `isKeptOff` is the preset's stored Keep Off intent. A kept-off preset's
    /// service or agent counts as back on the same terms as its card's
    /// "Service running": a protected service or the user agent is running.
    static func resolve(
        presets: [WatchedAppPreset],
        snapshots: [WatchedAppSnapshot],
        availability: WatchedStatusAvailability,
        isKeptOff: (WatchedAppPreset) -> Bool,
        pendingPromptCount: Int
    ) -> MenuBarStatus {
        if pendingPromptCount > 0 { return .autoStopPromptPending }
        switch availability.forPresets(presets, snapshots: snapshots) {
        case .unknown: return .statusUnknown
        case .stale: return .statusStale
        case .current: break
        }
        let watched = snapshots.filter { presets.contains($0.preset) }
        if watched.contains(where: { snapshot in
            isKeptOff(snapshot.preset)
                && (!snapshot.protectedRunning.isEmpty || snapshot.hasCurrentUserLaunchAgent)
        }) {
            return .keepOffServiceRunning
        }
        return watched.contains(where: \.isMainRunning) ? .watchedAppRunning : .normal
    }
}
