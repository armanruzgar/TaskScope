import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notificationService: NotificationService
    /// Shown where the tab can reach every store a backup covers.
    var backupSection: ConfigurationBackupSection? = nil

    var body: some View {
        Form {
            Section("Refresh") {
                HStack {
                    Text("Watched status interval")
                    Spacer()
                    Slider(value: $settings.refreshIntervalSeconds, in: 2...60, step: 1)
                        .accessibilityLabel("Watched status interval")
                        .accessibilityValue("\(Int(settings.refreshIntervalSeconds)) seconds")
                    Text("\(Int(settings.refreshIntervalSeconds))s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("Auto-refresh process list", isOn: $settings.autoRefreshProcessList)
                Toggle("Show all processes", isOn: $settings.showsAllProcesses)
                Stepper(value: $settings.processListLimit, in: SettingsStore.processListLimitRange, step: 10) {
                    HStack {
                        Text("Process list limit")
                        Spacer()
                        Text(settings.showsAllProcesses ? "All" : "\(settings.processListLimit)").monospacedDigit()
                    }
                }
                .disabled(settings.showsAllProcesses)
            }
            .disabled(settings.isReadOnlyAfterCorruption)

            Section("Highlight Thresholds") {
                HStack {
                    Text("CPU %")
                    Spacer()
                    Slider(value: $settings.cpuHighlightThreshold, in: 1...100, step: 1)
                        .accessibilityLabel("CPU highlight threshold")
                        .accessibilityValue("\(Int(settings.cpuHighlightThreshold)) percent")
                    Text(String(format: "%.0f%%", settings.cpuHighlightThreshold))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Memory (MB)")
                    Spacer()
                    Slider(
                        value: $settings.memHighlightThresholdMB,
                        in: SettingsStore.memoryThresholdRange,
                        step: SettingsStore.memoryThresholdStep
                    )
                    .accessibilityLabel("Memory highlight threshold")
                    .accessibilityValue("\(Int(settings.memHighlightThresholdMB)) megabytes")
                    Text(String(format: "%.0f", settings.memHighlightThresholdMB))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(settings.isReadOnlyAfterCorruption)

            Section("Menu Bar") {
                Toggle("Show status in the menu-bar icon", isOn: $settings.showsMenuBarStatus)
                Text("The icon marks a running watched app, a kept-off preset's service that is running again, a watched status TaskScope could not verify, and a waiting Auto-Stop prompt. TaskScope then reads watched status in the background at the watched status interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(settings.isReadOnlyAfterCorruption)

            if let backupSection {
                backupSection
            }

            Section("Notifications") {
                Toggle("Notify on watched process changes", isOn: $settings.enableNotifications)
                LabeledContent("System permission", value: notificationService.authorizationState.label)
                if notificationService.authorizationState == .denied {
                    Button("Open Notification Settings") {
                        notificationService.openSystemSettings()
                    }
                }
                Text("TaskScope shows foreground banners without sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(settings.isReadOnlyAfterCorruption)

            if let recoveryMessage = settings.recoveryMessage {
                Section("Recovered Settings") {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    RecoveryResetButton(subject: "Settings", isBackupPreserved: settings.isRecoveryBackupPreserved) {
                        settings.resetAfterCorruption()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Export Configuration… and Import Configuration…, with their outcome.
struct ConfigurationBackupSection: View {
    @ObservedObject var actions: ConfigurationBackupActions
    var exportConfiguration: () -> Void
    var importConfiguration: () -> Void

    var body: some View {
        Section("Configuration Backup") {
            Text("Save watched-app presets, Auto-Stop rules, saved selections, settings and the hotkey to a file, or import them from one. A backup never holds Keep Off, recovery data or event history. Imported Auto-Stop rules arrive turned off.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Export Configuration…", action: exportConfiguration)
                Button("Import Configuration…", action: importConfiguration)
            }
            if let note = actions.exportNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let error = actions.exportError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let summary = actions.importSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if let error = actions.importError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
