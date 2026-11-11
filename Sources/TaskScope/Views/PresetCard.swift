import SwiftUI

struct PresetCard: View {
    var snapshot: WatchedAppSnapshot
    @Environment(\.watchedStatusAvailability) private var watchedStatusAvailability
    var onOpen: () -> Void
    var onQuitApp: () -> Void
    var onQuitHelpers: () -> Void
    var onQuitAll: () -> Void
    var isKeptOff: Bool
    var isKeepOffControlEnabled: Bool
    var onKeepOffChanged: @MainActor @Sendable (Bool) -> Void
    var onStopWithoutDisconnect: (() -> Void)? = nil
    /// Quit App and Helpers, then Open. Nil for the built-in GlobalProtect
    /// preset, whose full stop is Quit All.
    var onRestart: (() -> Void)? = nil
    /// True while an action holds the operation gate. A second action would
    /// only wait silently behind it, so the card's actions are unavailable.
    var isMutationActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // The shield belongs to the built-in VPN preset only; it suggests
                // network protection and Keep Off, which other presets lack.
                Label(snapshot.preset.displayName, systemImage: snapshot.preset.isBuiltInGlobalProtect ? "network.badge.shield.half.filled" : "app")
                    .font(.headline)

                Spacer()

                statusBadge
            }

            Text(watchedStatusAvailability.detail ?? snapshot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(spacing: 8) {
                PresetActionButton(title: "Open", systemImage: "arrow.up.forward.app", role: nil, action: onOpen)
                PresetActionButton(title: "Quit App…", systemImage: "power", role: .destructive, action: onQuitApp)
                PresetActionButton(title: "Quit Helpers…", systemImage: "wrench.and.screwdriver", role: .destructive, action: onQuitHelpers)
                    .disabled(!hasHelperScope)
                    .help(hasHelperScope ? "Quit Helpers" : "This preset has no helper processes or user launch agents to stop.")
                PresetActionButton(title: snapshot.preset.isBuiltInGlobalProtect ? "Quit All…" : "Quit App and Helpers…", systemImage: "stop.circle", role: .destructive, action: onQuitAll)
                    .disabled(snapshot.preset.isBuiltInGlobalProtect && !isKeepOffControlEnabled)
                if let onRestart, !snapshot.preset.isBuiltInGlobalProtect {
                    // Restart opens the app, and Open turns Keep Off off.
                    PresetActionButton(
                        title: "Restart…", systemImage: "arrow.clockwise", role: .destructive, action: onRestart,
                        help: isKeptOff
                            ? "Not available while Keep Off is on: restarting opens the app, which turns Keep Off off."
                            : "Quit the app and its helpers, then open it again"
                    )
                    .disabled(isKeptOff)
                }
            }
            .disabled(isMutationActive)

            if isMutationActive {
                Text("Waiting for the current action to finish…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasKeepOffScope {
                Divider()
                if isKeepOffControlEnabled {
                    Toggle(
                        isOn: Binding(
                            get: { isKeptOff },
                            set: onKeepOffChanged
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(keepOffTitle)
                                .fontWeight(.medium)
                            Text(keepOffCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isMutationActive)
                    .accessibilityHint(keepOffHint)
                } else {
                    // The saved intent is inside the unreadable payload, so it is
                    // unknown here (not Off), and background enforcement is paused.
                    Text("\(keepOffTitle): Unknown")
                        .fontWeight(.medium)
                    Text("Settings are unreadable. Reset settings in Settings → General before changing Keep Off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Keep Off is not enforced in the background until then. After the reset, Keep Off is off until you turn it on again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isKeptOff {
                    Button("Apply Keep Off…", role: .destructive) { onKeepOffChanged(true) }
                        .disabled(!isKeepOffControlEnabled || isMutationActive)
                        .help(snapshot.preset.isBuiltInGlobalProtect
                            ? "Retry the confirmed disconnect and service stop. A system daemon preserved on a session installation remains running."
                            : "Disable its user launch agents again and stop its running processes now.")
                }
                if let onStopWithoutDisconnect {
                    Text(isKeepOffControlEnabled
                         ? "Automatic disconnect failed. You can still stop the services."
                         : "Automatic disconnect failed. Reset settings before choosing Stop Services Anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop Services Anyway…", role: .destructive, action: onStopWithoutDisconnect)
                        .disabled(!isKeepOffControlEnabled || isMutationActive)
                }
                if snapshot.preset.isBuiltInGlobalProtect {
                    GlobalProtectCompatibilityButton(
                        keepOffRequested: isKeepOffControlEnabled ? isKeptOff : nil
                    )
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Keep Off acts on the main process, helpers and user launch agents; a
    /// preset with any of them can be kept off.
    private var hasKeepOffScope: Bool {
        let preset = snapshot.preset
        return !preset.mainProcessName.isEmpty || !preset.helperProcessNames.isEmpty
            || !preset.lifecycleUserLaunchAgentJobs.isEmpty
    }

    private var keepOffTitle: String {
        "Keep \(snapshot.preset.displayName) Off"
    }

    private var keepOffCaption: String {
        if snapshot.preset.isBuiltInGlobalProtect {
            return "Quit All disconnects and stops GlobalProtect. Open or turning this switch off restores it."
        }
        return snapshot.preset.lifecycleUserLaunchAgentJobs.isEmpty
            ? "Stops it whenever it is running. Turning this switch off allows it to run again."
            : "Disables its launch agents and stops it whenever it is running. Turning this switch off allows it to run again."
    }

    private var keepOffHint: String {
        if snapshot.preset.isBuiltInGlobalProtect {
            return "Automatically disconnects and stops GlobalProtect. Turning this off restores its VPN service and opens the app."
        }
        return "Keeps \(snapshot.preset.displayName) from running: TaskScope stops its processes whenever they appear. Turning this off allows it to run again without opening it."
    }

    /// Quit Helpers acts on helper processes and, with launch agents
    /// configured, unloads those agents; with neither it has nothing to do.
    private var hasHelperScope: Bool {
        !snapshot.preset.helperProcessNames.isEmpty || !snapshot.preset.lifecycleUserLaunchAgentJobs.isEmpty
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        if watchedStatusAvailability == .unknown { .secondary }
        else if watchedStatusAvailability == .stale { .orange }
        else if isKeptOff && snapshot.hasAny { .orange }
        else if isKeptOff { .green }
        else if snapshot.isMainRunning { .red }
        else if snapshot.hasHelpers { .yellow }
        else if !snapshot.protectedRunning.isEmpty || !snapshot.unprivilegedProtectedRunning.isEmpty { .orange }
        else { .green }
    }

    private var label: String {
        if let title = watchedStatusAvailability.title { title }
        else if isKeptOff && (!snapshot.protectedRunning.isEmpty || snapshot.hasCurrentUserLaunchAgent) { "Service running" }
        else if isKeptOff && snapshot.hasKeepOffTargets { "Enforcing" }
        else if isKeptOff && snapshot.hasAny { "Still running" }
        else if isKeptOff { "Off requested" }
        else if snapshot.isMainRunning { "Active" }
        else if snapshot.hasHelpers { "Helpers" }
        else if !snapshot.protectedRunning.isEmpty || !snapshot.unprivilegedProtectedRunning.isEmpty { "Services" }
        else { "Quiet" }
    }
}

private struct PresetActionButton: View {
    var title: String
    var systemImage: String
    var role: ButtonRole?
    var action: () -> Void
    /// Set on the Button itself, so it can say why the button is unavailable.
    var help: String? = nil

    var body: some View {
        if let help {
            button.help(help)
        } else {
            button
        }
    }

    private var button: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
