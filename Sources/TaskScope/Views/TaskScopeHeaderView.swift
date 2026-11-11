import SwiftUI

struct TaskScopeHeaderView: View {
    var status: ProcessStatus
    var watchedStatusAvailability: WatchedStatusAvailability = .current
    var samples: [ProcessHistory.Sample]
    var samplingState: ProcessHistory.SamplingState
    var showsMetrics: Bool
    var showsOpenWindowButton: Bool
    var openFullWindow: (() -> Void)?
    var refreshAction: () -> Void
    /// Replaceable so tests can check what the Settings button does without
    /// changing the test process's own activation state.
    var settingsActivation: @MainActor () -> Void = SettingsWindowActivation.bringForward
    var openSettingsOverride: (@MainActor () -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(headerGradient)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("TaskScope")
                    .font(.headline)

                Text(watchedStatusAvailability.detail ?? status.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsMetrics {
                HStack(spacing: 12) {
                    SparklineView(
                        samples: samples,
                        keyPath: \.observedProcessCPU,
                        color: .orange,
                        label: "PROC CPU %",
                        unit: "percent",
                        samplingState: samplingState
                    )
                        .frame(width: 70)
                    SparklineView(
                        samples: samples,
                        keyPath: \.observedProcessMemoryMB,
                        color: .blue,
                        label: "PROC RSS",
                        unit: "megabytes",
                        samplingState: samplingState
                    )
                        .frame(width: 70)
                }
                .opacity(samplingState.isUnavailable ? 0.5 : 1)
                .help(samplingState.detail)
                if samplingState.isUnavailable {
                    Text("History unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(samplingState.detail)
                }
            }

            Spacer()

            statusPill

            if showsOpenWindowButton, let openFullWindow {
                Button {
                    openFullWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .buttonStyle(.borderless)
                .help("Open TaskScope Window")
                .accessibilityLabel("Open TaskScope Window")
            }

            OpenSettingsButton(activateApp: settingsActivation, openSettings: openSettingsOverride) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Open TaskScope Settings")

            Button {
                refreshAction()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh TaskScope")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(watchedStatusAvailability.title ?? status.title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(watchedStatusAvailability.title ?? status.title)")
    }

    private var statusColor: Color {
        if watchedStatusAvailability == .unknown { return .secondary }
        if watchedStatusAvailability == .stale { return .orange }
        switch status {
        case .idle:
            return .green
        case .helpersOnly:
            return .yellow
        case .protectedOnly:
            return .orange
        case .watchedRunning:
            return .red
        }
    }

    private var headerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.15, blue: 0.18),
                Color(red: 0.18, green: 0.34, blue: 0.40)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension ProcessHistory.SamplingState {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
    var detail: String {
        if case .unavailable(let error) = self { return "History unavailable: \(error)" }
        return "Full observed process inventory · \(label)"
    }
}

/// After a login-item or other background launch TaskScope is an accessory
/// app, and a window it opens can appear behind the frontmost app without
/// focus. Settings is brought forward the way the main window is.
enum SettingsWindowActivation {
    @MainActor
    static func bringForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens TaskScope's Settings window in front of other apps' windows.
struct OpenSettingsButton<Label: View>: View {
    var activateApp: @MainActor () -> Void = SettingsWindowActivation.bringForward
    var openSettings: (@MainActor () -> Void)? = nil
    @ViewBuilder var label: () -> Label
    @Environment(\.openSettings) private var environmentOpenSettings

    var body: some View {
        Button {
            activateApp()
            if let openSettings {
                openSettings()
            } else {
                environmentOpenSettings()
            }
        } label: {
            label()
        }
    }
}
