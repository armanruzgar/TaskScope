import SwiftUI

struct TaskScopeHeaderView: View {
    var status: ProcessStatus
    var watchedStatusAvailability: WatchedStatusAvailability = .current
    var samples: [ProcessHistory.Sample]
    var samplingState: ProcessHistory.SamplingState
    /// The time the history charts cover (`ProcessHistory.windowDuration`).
    var historyWindow: TimeInterval = 600
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
                        label: "CPU SUM",
                        unit: "percent",
                        samplingState: samplingState,
                        window: historyWindow,
                        format: Self.percentText
                    )
                    .frame(width: 112)
                    .help(cpuHelp)
                    SparklineView(
                        samples: samples,
                        keyPath: \.observedProcessMemoryMB,
                        color: .blue,
                        label: "RSS SUM",
                        unit: "megabytes",
                        samplingState: samplingState,
                        window: historyWindow,
                        format: Self.memoryText
                    )
                    .frame(width: 112)
                    .help(memoryHelp)
                }
                .opacity(samplingState.isUnavailable ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("last \(SparklineView.spanText(historyWindow))")
                        .help("The charts cover the last \(SparklineView.spanText(historyWindow)), sampled at the watched status interval.")
                    // Live is the usual state; any other one is said, not only on hover.
                    if samplingState != .sampling {
                        Text("History \(samplingState.label.lowercased())")
                            .help(samplingState.detail)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    /// The process count of the latest sample, for the charts' help.
    private var coverage: String {
        guard let count = samples.last?.processCount else { return "the observed processes" }
        return count == 1 ? "1 observed process" : "\(count.formatted()) observed processes"
    }

    private var cpuHelp: String {
        "Sum of %CPU over \(coverage); 100% is one core. The line is scaled to its peak in the window. \(samplingState.label)."
    }

    private var memoryHelp: String {
        "Sum of the resident memory of \(coverage). Memory that processes share counts once per process, so the sum can exceed the Mac's memory. The line is scaled to its peak in the window. \(samplingState.label)."
    }

    /// "3.2%" below 10, "883%" above.
    static func percentText(_ value: Double) -> String {
        value < 10
            ? "\(value.formatted(.number.precision(.fractionLength(1))))%"
            : "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }

    /// "512 MB", or "62.3 GB" from 1024 MB.
    static func memoryText(_ megabytes: Double) -> String {
        megabytes < 1024
            ? "\(megabytes.formatted(.number.precision(.fractionLength(0)))) MB"
            : "\((megabytes / 1024).formatted(.number.precision(.fractionLength(1)))) GB"
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
