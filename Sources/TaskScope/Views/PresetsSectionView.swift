import SwiftUI

struct PresetsSectionView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var confirmationState: ProcessConfirmationState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = processManager.watchedStatusLoadError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(processManager.watchedStatusAvailability == .unknown
                             ? "Watched status is unavailable" : "Watched status is stale")
                            .font(.caption).fontWeight(.semibold)
                        Text(UIMessage.sentence(error))
                            .font(.caption).foregroundStyle(.secondary)
                        if let lastRead = processManager.lastSuccessfulWatchedReadAt {
                            Text("Last successful inventory: \(lastRead.formatted(date: Calendar.current.isDateInToday(lastRead) ? .omitted : .abbreviated, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Retry") {
                            confirmationState.run { await processManager.refreshWatchedStatus() }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if watchedApps.isReadOnlyAfterCorruption {
                    presetRecoveryNotice
                }

                ForEach(watchedApps.presets) { preset in
                    let snapshot = processManager.snapshots.first { $0.preset == preset }
                        ?? WatchedAppSnapshot(preset: preset, runningNames: [])
                    PresetCard(
                        snapshot: snapshot,
                        onOpen: {
                            openPreset(id: snapshot.preset.id)
                        },
                        onQuitApp: {
                            requestPresetAction(.quitApp, id: snapshot.preset.id)
                        },
                        onQuitHelpers: {
                            requestPresetAction(.quitHelpers, id: snapshot.preset.id)
                        },
                        onQuitAll: {
                            requestPresetAction(.quitAll, id: snapshot.preset.id)
                        },
                        isKeptOff: snapshot.preset.isBuiltInGlobalProtect
                            && settings.keepGlobalProtectOff,
                        isKeepOffControlEnabled: !settings.isReadOnlyAfterCorruption,
                        onKeepOffChanged: { keptOff in
                            if keptOff {
                                confirmationState.requestPresetAction(
                                    .keepOff,
                                    preset: snapshot.preset
                                )
                            } else {
                                // Turning the switch off means the VPN is usable
                                // again, including its service, not just enabled
                                // launchd overrides with no running service.
                                openPreset(id: snapshot.preset.id)
                            }
                        },
                        onStopWithoutDisconnect: stopRecoveryAction(for: snapshot.preset),
                        isMutationActive: processManager.isMutationActive
                    )
                    .environment(\.watchedStatusAvailability, processManager.watchedStatusAvailability.forPresets(
                        [preset], snapshots: processManager.snapshots
                    ))
                }

                if watchedApps.presets.isEmpty && !watchedApps.isReadOnlyAfterCorruption {
                    Text("No watched apps configured. Add presets in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { loginItemManager.isEnabled },
                        set: { loginItemManager.setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .padding(.top, 4)

                if let loginMessage = loginItemManager.message {
                    Text(loginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if loginItemManager.state == .requiresApproval || loginItemManager.state == .notFound {
                    Button(loginItemManager.state == .notFound ? "Remove Stale Login Item" : "Turn Off Launch at Login") {
                        loginItemManager.setEnabled(false)
                    }
                    .buttonStyle(.bordered)
                }
                if loginItemManager.state == .requiresApproval {
                    Button("Open Login Item Settings") {
                        loginItemManager.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
        }
    }

    /// Stored presets could not be read, or some were rejected: the list is
    /// read-only until reset, and a missing built-in preset also means Keep Off
    /// is no longer enforced. Say so instead of showing an ordinary list.
    private var presetRecoveryNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Watched apps need recovery")
                .font(.caption).fontWeight(.semibold)
            Text(watchedApps.persistenceIssue ?? "Stored presets could not be read.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.keepGlobalProtectOff
                && !watchedApps.presets.contains(where: { $0.isBuiltInGlobalProtect }) {
                Text("Keep GlobalProtect Off is not being enforced until presets are reset.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            OpenSettingsButton {
                Text("Review in Settings…")
            }
            .help("Settings → Watched Apps can export the recovered presets and reset them.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Opens the preset the card shows, addressed by identity: a display-name
    /// lookup also matches other presets' main process names. The call goes to
    /// the manager directly, like the card's other actions, so it queues on the
    /// operation gate in click order instead of waiting in the command bus
    /// behind actions confirmed after it.
    private func openPreset(id: UUID) {
        guard let preset = watchedApps.presets.first(where: { $0.id == id }) else { return }
        confirmationState.run { _ = await processManager.openApp(preset) }
    }

    private func requestPresetAction(_ action: ProcessConfirmationState.PresetAction, id: UUID) {
        guard let preset = watchedApps.presets.first(where: { $0.id == id }) else { return }
        confirmationState.requestPresetAction(action, preset: preset)
    }

    private func stopRecoveryAction(for preset: WatchedAppPreset) -> (() -> Void)? {
        guard preset.isBuiltInGlobalProtect,
              let failureID = processManager.globalProtectDisconnectFailureID else { return nil }
        return {
            confirmationState.requestPresetAction(.stopServices, preset: preset, disconnectFailureID: failureID)
        }
    }
}

private struct WatchedStatusAvailabilityKey: EnvironmentKey {
    static let defaultValue: WatchedStatusAvailability = .current
}

extension EnvironmentValues {
    var watchedStatusAvailability: WatchedStatusAvailability {
        get { self[WatchedStatusAvailabilityKey.self] }
        set { self[WatchedStatusAvailabilityKey.self] = newValue }
    }
}
