import SwiftUI
import UniformTypeIdentifiers

struct SupportDiagnosticsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    let processManager: ProcessManager

    var collector = SupportDiagnosticsCollector()
    var collectPermissions: @MainActor (Bool?) async -> SupportDiagnosticsReport.Permissions = {
        await SupportDiagnosticsCollector.permissions(notificationsEnabled: $0)
    }
    var makePreview: (SupportDiagnosticsReport) throws -> SupportDiagnosticsPreview = SupportDiagnosticsPreview.init

    @State var selectedPresetID: UUID?
    @State private var preview: SupportDiagnosticsPreview?
    @State private var collectionTask: Task<Void, Never>?
    @State private var isCollecting = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Support Diagnostics").font(.headline)
            Text("Review a report before copying it or saving a JSON file. Nothing is uploaded automatically.")
            Picker("Preset", selection: $selectedPresetID) {
                Text("No preset (app and permissions only)").tag(nil as UUID?)
                ForEach(watchedApps.presets) { preset in
                    Text(preset.displayName).tag(Optional(preset.id))
                }
            }
            .disabled(isCollecting)
            Text("Preset names appear only in this picker. The report uses ‘selected-preset’ and identifies the built-in preset or a custom preset.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Includes app and macOS versions, permission and login-item status, selected user launch-agent status, and recent lifecycle failure categories.")
            Text("Excludes usernames, commands, organization identifiers, process lists, process names and IDs, job labels, raw paths, logs, and raw error messages.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Keeps the latest 20 lifecycle failures across presets in memory for this app session. Only failures for the selected preset enter the report.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview Diagnostics", action: collect)
                    .buttonStyle(.borderedProminent)
                    .disabled(isCollecting)
                if isCollecting {
                    ProgressView().controlSize(.small)
                    Button("Cancel") {
                        collectionTask?.cancel()
                    }
                }
                Spacer()
                Button("Clear Failure History") {
                    processManager.clearLifecycleDiagnostics()
                    status = "Session failure history cleared. Existing saved files are unchanged."
                }
                .disabled(isCollecting)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .sheet(item: $preview) { snapshot in
            SupportDiagnosticsPreviewSheet(preview: snapshot, onClose: { preview = nil })
        }
        .onDisappear { collectionTask?.cancel() }
        .onChange(of: watchedApps.presets) { _, presets in
            if let id = selectedPresetID, !presets.contains(where: { $0.id == id }) {
                selectedPresetID = nil
                status = Self.removedPresetMessage
            }
        }
    }

    static let removedPresetMessage = "The selected preset was removed. Choose a preset again."

    private func collect() {
        let preset = watchedApps.presets.first { $0.id == selectedPresetID }
        guard selectedPresetID == nil || preset != nil else {
            status = Self.removedPresetMessage
            return
        }
        let keepOff: Bool? = settings.isReadOnlyAfterCorruption
            ? nil : preset?.isBuiltInGlobalProtect == true && settings.keepGlobalProtectOff
        let notificationsEnabled = settings.isReadOnlyAfterCorruption ? nil : settings.enableNotifications
        // Freeze history at the start so concurrent lifecycle activity does not
        // change what this collection includes.
        let failures = processManager.lifecycleDiagnostics.failures(for: preset?.id)
        isCollecting = true
        status = nil
        collectionTask = Task { @MainActor in
            defer { isCollecting = false }
            let permissions = await collectPermissions(notificationsEnabled)
            let inspected: SupportDiagnosticsReport.Preset?
            if let preset {
                inspected = await collector.inspectPreset(preset, keepOffRequested: keepOff)
            } else {
                inspected = nil
            }
            guard !Task.isCancelled else { return }
            let report = SupportDiagnosticsReport(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                macOS: ProcessInfo.processInfo.operatingSystemVersion,
                capturedAt: Date(), permissions: permissions, selectedPreset: inspected,
                recentLifecycleFailures: failures
            )
            do {
                preview = try makePreview(report)
            } catch {
                status = "Could not prepare diagnostics. Nothing was exported."
            }
        }
    }
}

struct SupportDiagnosticsPreviewSheet: View {
    let preview: SupportDiagnosticsPreview
    let onClose: () -> Void
    /// Clipboard and save-panel effects, injectable so the export actions can
    /// be tested without touching the real pasteboard or showing a panel.
    var copyText: @MainActor (String) -> Bool = { SupportDiagnosticsPreviewSheet.copyToGeneralPasteboard($0) }
    var chooseDestination: @MainActor () -> URL? = { SupportDiagnosticsPreviewSheet.chooseDestinationWithSavePanel() }
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics Preview").font(.title2.bold())
            Text("This is the complete JSON that Copy and Save export. Close and preview again to refresh it.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(preview.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .border(.quaternary)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy JSON") {
                    status = copyText(preview.text)
                        ? "Copied the preview to the clipboard."
                        : "Could not copy diagnostics."
                }
                Button("Save JSON…", action: save)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        // A read-only report: Escape closes it as Return does.
        .onExitCommand(perform: onClose)
    }

    private func save() {
        guard let url = chooseDestination() else { return }
        do {
            try preview.save(to: url)
            status = "Saved the preview."
        } catch {
            // Filesystem errors can contain usernames and destination paths.
            status = "Could not save diagnostics. Choose another destination and try again."
        }
    }

    static func copyToGeneralPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    static func chooseDestinationWithSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TaskScope-diagnostics.json"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
