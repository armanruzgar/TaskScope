import Combine
import Foundation

/// The presets whose explicit Keep Off action is running right now. The
/// lifecycle code records each one while it runs; the preset deletion policy
/// reads them, so a preset is never deleted halfway through its Keep Off.
@MainActor
final class KeepOffActivity: ObservableObject {
    @Published private(set) var pendingPresetIDs: Set<UUID> = []
    private var counts: [UUID: Int] = [:]

    func begin(_ presetID: UUID) {
        counts[presetID, default: 0] += 1
        pendingPresetIDs.insert(presetID)
    }

    /// Ends one `begin`. Overlapping actions for one preset keep it pending
    /// until the last of them ends.
    func end(_ presetID: UUID) {
        let remaining = (counts[presetID] ?? 0) - 1
        if remaining > 0 {
            counts[presetID] = remaining
        } else {
            counts[presetID] = nil
            pendingPresetIDs.remove(presetID)
        }
    }

    func isPending(_ presetID: UUID) -> Bool {
        pendingPresetIDs.contains(presetID)
    }
}

/// Whether a preset may be deleted or edited now. `WatchedAppsStore` applies
/// it to every deletion and edit, so no path (Settings, a future intent or
/// reset) can change a preset whose Keep Off is on, pending or unknown: a
/// deletion would orphan the persistent launchd disable overrides only the
/// preset itself can clear, and an edit could leave one of them in place for
/// good (turning Keep Off off re-enables only the agents the preset lists then)
/// while background enforcement applied Keep Off to the edited preset without a
/// new confirmation.
@MainActor
struct PresetChangePolicy {
    enum Change: Sendable {
        case deletion, edit
    }

    /// Why the preset may not be deleted now, or nil when it may.
    let deletionRefusal: (WatchedAppPreset) -> String?
    /// Why the preset may not be edited now, or nil when it may. A change of
    /// the notifications setting alone is never refused: it does not change
    /// what Keep Off acts on.
    let editRefusal: (WatchedAppPreset) -> String?

    static let unrestricted = PresetChangePolicy(deletionRefusal: { _ in nil }, editRefusal: { _ in nil })

    /// The app's rule: Keep Off intent from `settings`, running Keep Off
    /// actions from `activity`.
    static func keepOff(settings: SettingsStore, activity: KeepOffActivity) -> PresetChangePolicy {
        func refusal(_ change: Change) -> (WatchedAppPreset) -> String? {
            { preset in
                keepOffRefusal(
                    for: preset,
                    isKeptOff: settings.isKeptOff(preset.id),
                    isSettingsReadOnly: settings.isReadOnlyAfterCorruption,
                    isKeepOffPending: activity.isPending(preset.id),
                    change: change
                )
            }
        }
        return PresetChangePolicy(deletionRefusal: refusal(.deletion), editRefusal: refusal(.edit))
    }

    /// The message names the way out.
    nonisolated static func keepOffRefusal(
        for preset: WatchedAppPreset,
        isKeptOff: Bool,
        isSettingsReadOnly: Bool,
        isKeepOffPending: Bool,
        change: Change = .deletion
    ) -> String? {
        guard preset.isBuiltInGlobalProtect else {
            let name = preset.displayName
            let verb = change == .deletion ? "deleting" : "editing"
            if isSettingsReadOnly {
                return "Settings are unreadable, so Keep Off may still be on for \(name). Recover settings and turn its Keep Off off before \(verb) it."
            }
            if isKeepOffPending {
                return "Wait for the pending Keep Off action for \(name) to finish before \(verb) it."
            }
            guard isKeptOff else { return nil }
            let hasAgents = !preset.lifecycleUserLaunchAgentJobs.isEmpty
            switch change {
            case .deletion:
                return hasAgents
                    ? "Turn off Keep \(name) Off before deleting it. Its user launch agents are disabled by a persistent launchd override that deleting the preset would not clear."
                    : "Turn off Keep \(name) Off before deleting it."
            case .edit:
                return hasAgents
                    ? "Turn off Keep \(name) Off before editing it: an edit could leave one of its launch agents disabled for good, and Keep Off would act on the edited preset without a new confirmation."
                    : "Turn off Keep \(name) Off before editing it: Keep Off would otherwise act on the edited preset without a new confirmation."
            }
        }
        // The built-in preset's definition cannot be edited at all (only its
        // notifications setting, which is never refused).
        guard change == .deletion else { return nil }
        if isSettingsReadOnly {
            return "Settings are unreadable, so Keep GlobalProtect Off may still be active. Recover settings and clear Keep Off before deleting the built-in preset."
        }
        if isKeepOffPending {
            return "Wait for the pending GlobalProtect Keep Off action to finish before deleting the built-in preset."
        }
        guard isKeptOff else { return nil }
        return "Turn off Keep GlobalProtect Off (or choose Open) before deleting the built-in preset. Its user launch agents are disabled by a persistent launchd override that deleting the preset would not clear."
    }
}
