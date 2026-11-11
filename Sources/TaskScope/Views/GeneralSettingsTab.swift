import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var notificationService: NotificationService

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
