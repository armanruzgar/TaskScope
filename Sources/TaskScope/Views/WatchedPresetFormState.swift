import Combine
import Foundation

@MainActor
final class WatchedPresetFormState: ObservableObject {
    @Published var displayName = ""
    @Published var mainProcess = ""
    @Published var helpers = ""
    @Published var protectedProcesses = ""
    @Published var appPath = "/Applications/"
    @Published var agentLabels = ""
    @Published var agentPlistPaths = ""
    @Published var editingPresetID: UUID?

    func prepareForNewPreset() {
        editingPresetID = nil
        displayName = ""
        mainProcess = ""
        helpers = ""
        protectedProcesses = ""
        appPath = "/Applications/"
        agentLabels = ""
        agentPlistPaths = ""
    }

    func prepareForEditing(_ preset: WatchedAppPreset) {
        editingPresetID = preset.id
        displayName = preset.displayName
        mainProcess = preset.mainProcessName
        helpers = preset.helperProcessNames.joined(separator: ", ")
        protectedProcesses = preset.protectedProcessNames.joined(separator: ", ")
        appPath = preset.appPath
        agentLabels = preset.userLaunchAgentJobs.map(\.label).joined(separator: ", ")
        agentPlistPaths = preset.userLaunchAgentJobs.map(\.plistPath).joined(separator: ", ")
    }

    func makePreset(existing: WatchedAppPreset?) -> Result<WatchedAppPreset, ValidationError> {
        let agents = PresetInputParser.parseUserLaunchAgentJobs(
            labels: agentLabels,
            paths: agentPlistPaths
        )
        guard agents.errors.isEmpty else {
            return .failure(ValidationError(message: agents.errors.joined(separator: " ")))
        }
        // The form edits only labels and paths. Carry each unchanged job's
        // optional/required flag through, so renaming a preset cannot turn an
        // optional agent into a required one.
        let existingJobs = existing?.userLaunchAgentJobs ?? []
        let jobs = agents.value.map { parsed -> UserLaunchAgentJob in
            guard let match = existingJobs.first(where: {
                $0.label == parsed.label && $0.plistPath == parsed.plistPath
            }) else {
                return parsed
            }
            return UserLaunchAgentJob(
                label: parsed.label,
                plistPath: parsed.plistPath,
                isRequired: match.isRequired
            )
        }

        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = WatchedAppPreset(
            id: existing?.id ?? UUID(),
            displayName: trimmedDisplayName.isEmpty ? mainProcess : trimmedDisplayName,
            mainProcessName: mainProcess,
            helperProcessNames: PresetInputParser.list(from: helpers),
            protectedProcessNames: PresetInputParser.list(from: protectedProcesses),
            appPath: appPath,
            userLaunchAgentJobs: jobs,
            systemLaunchDaemonJobs: existing?.systemLaunchDaemonJobs ?? [],
            notificationsEnabled: existing?.notificationsEnabled ?? true
        )
        if let error = PresetFieldValidation.error(in: preset) {
            return .failure(ValidationError(message: error))
        }
        return .success(preset)
    }

    struct ValidationError: Error, Equatable {
        var message: String
    }
}
