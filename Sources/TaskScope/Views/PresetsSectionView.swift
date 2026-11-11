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
                        Text(error)
                            .font(.caption).foregroundStyle(.secondary)
                        if let lastRead = processManager.lastSuccessfulWatchedReadAt {
                            Text("Last successful inventory: \(lastRead.formatted(date: Calendar.current.isDateInToday(lastRead) ? .omitted : .abbreviated, time: .standard))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Retry") {
                            Task { await processManager.refreshWatchedStatus() }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(watchedApps.presets) { preset in
                    let snapshot = processManager.snapshots.first { $0.preset == preset }
                        ?? WatchedAppSnapshot(preset: preset, runningNames: [])
                    PresetCard(
                        snapshot: snapshot,
                        onOpen: {
                            // Address the preset by identity, exactly as the quit
                            // buttons do. A display-name lookup also matches other
                            // presets' main process names, so a name collision could
                            // open a different preset than the card the user clicked.
                            let target = WatchedPresetCommandTarget(
                                id: snapshot.preset.id,
                                displayName: snapshot.preset.displayName
                            )
                            Task {
                                _ = await AppCommandBus.shared.submit(.openPresetEntity(target))
                            }
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
                        isKeptOff: snapshot.preset.id == WatchedAppPreset.globalProtectID
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
                                let target = WatchedPresetCommandTarget(
                                    id: snapshot.preset.id,
                                    displayName: snapshot.preset.displayName
                                )
                                Task { _ = await AppCommandBus.shared.submit(.openPresetEntity(target)) }
                            }
                        },
                        onStopWithoutDisconnect: stopRecoveryAction(for: snapshot.preset)
                    )
                    .environment(\.watchedStatusAvailability, processManager.watchedStatusAvailability.forPresets(
                        [preset], snapshots: processManager.snapshots
                    ))
                }

                if watchedApps.presets.isEmpty {
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
                    Button("Turn Off Launch at Login") {
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

    private func requestPresetAction(_ action: ProcessConfirmationState.PresetAction, id: UUID) {
        guard let preset = watchedApps.presets.first(where: { $0.id == id }) else { return }
        confirmationState.requestPresetAction(action, preset: preset)
    }

    private func stopRecoveryAction(for preset: WatchedAppPreset) -> (() -> Void)? {
        guard preset.hasCanonicalGlobalProtectIdentity,
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
