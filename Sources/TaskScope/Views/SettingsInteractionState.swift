import Foundation

/// Settings state that outlives one click: deletions waiting for confirmation
/// and the reasons for refused rule changes, kept with the control that caused
/// them rather than in a store's shared validation message.
@MainActor
final class SettingsInteractionState: ObservableObject {
    @Published var pendingPresetDeletions: [WatchedAppPreset] = []
    @Published var pendingRuleDeletions: [AutoStopRule] = []
    @Published var isConfirmingClearEvents = false
    @Published var ruleRowErrors: [UUID: String] = [:]
    @Published var addRuleError: String?
}
