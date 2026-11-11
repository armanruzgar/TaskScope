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

/// Whether a preset may be deleted. `WatchedAppsStore` applies it to every
/// deletion, so no path (Settings, a future intent or reset) can delete a
/// preset whose Keep Off left persistent launchd disable overrides that only
/// the preset itself can clear.
@MainActor
struct PresetDeletionPolicy {
    /// Why the preset may not be deleted now, or nil when it may.
    let refusal: (WatchedAppPreset) -> String?

    static let unrestricted = PresetDeletionPolicy { _ in nil }

    /// The app's rule: Keep Off intent from `settings`, running Keep Off
    /// actions from `activity`.
    static func keepOff(settings: SettingsStore, activity: KeepOffActivity) -> PresetDeletionPolicy {
        PresetDeletionPolicy { preset in
            keepOffRefusal(
                for: preset,
                isKeptOff: settings.keepGlobalProtectOff,
                isSettingsReadOnly: settings.isReadOnlyAfterCorruption,
                isKeepOffPending: activity.isPending(preset.id)
            )
        }
    }

    /// Deleting the built-in GlobalProtect preset while Keep Off is on, pending
    /// or unknown would orphan its persistent launchd disable override: nothing
    /// left in the app could clear it. The message names the way out.
    nonisolated static func keepOffRefusal(
        for preset: WatchedAppPreset,
        isKeptOff: Bool,
        isSettingsReadOnly: Bool,
        isKeepOffPending: Bool
    ) -> String? {
        guard preset.isBuiltInGlobalProtect else { return nil }
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
