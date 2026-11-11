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
    /// True while an action holds the operation gate. A second action would
    /// only wait silently behind it, so the card's actions are unavailable.
    var isMutationActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // The shield belongs to the built-in VPN preset only; it suggests
                // network protection and Keep Off, which other presets lack.
                Label(snapshot.preset.displayName, systemImage: snapshot.preset.hasCanonicalGlobalProtectIdentity ? "network.badge.shield.half.filled" : "app")
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
                PresetActionButton(title: snapshot.preset.hasCanonicalGlobalProtectIdentity ? "Quit All…" : "Quit App and Helpers…", systemImage: "stop.circle", role: .destructive, action: onQuitAll)
                    .disabled(snapshot.preset.hasCanonicalGlobalProtectIdentity && !isKeepOffControlEnabled)
            }
            .disabled(isMutationActive)

            if isMutationActive {
                Text("Waiting for the current action to finish…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.preset.id == WatchedAppPreset.globalProtectID {
                Divider()
                if isKeepOffControlEnabled {
                    Toggle(
                        isOn: Binding(
                            get: { isKeptOff },
                            set: onKeepOffChanged
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep GlobalProtect Off")
                                .fontWeight(.medium)
                            Text("Quit All disconnects and stops GlobalProtect. Open or turning this switch off restores it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(isMutationActive)
                    .accessibilityHint(
                        "Automatically disconnects and stops GlobalProtect. Turning this off restores its VPN service and opens the app."
                    )
                } else {
                    // The saved intent is inside the unreadable payload, so it is
                    // unknown here (not Off), and background enforcement is paused.
                    Text("Keep GlobalProtect Off: Unknown")
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
                        .help("Retry the confirmed disconnect and service stop. A system daemon preserved on a session installation remains running.")
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
                GlobalProtectCompatibilityButton(
                    keepOffRequested: isKeepOffControlEnabled ? isKeptOff : nil
                )
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
