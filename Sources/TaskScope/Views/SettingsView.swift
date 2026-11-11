import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Tab: Int, CaseIterable { case general, watchedApps, autoStop, hotkey, health, support }
    static let builtInDaemonGuidance = "Privileged system launch daemons are managed only by TaskScope’s built-in GlobalProtect preset; custom presets cannot configure them."

    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    let processManager: ProcessManager
    @ObservedObject private var notificationService = NotificationService.shared
    @State var selectedTab: Tab = .general

    @StateObject private var presetForm = WatchedPresetFormState()
    @State private var newRuleName = ""
    @State private var newRuleExecutablePath = ""
    @State private var newRuleMinutes = 5
    @State private var newRuleAction: AutoStopRule.Action = .prompt
    @State private var editingRule: AutoStopRule?
    @State private var editingRuleError: String?
    @State private var presetDeletionError: String?
    @State private var refusedPresetDeletion: WatchedAppPreset?
    @State private var isGlobalProtectKeepOffPending = false
    /// Import, export and preset-editor feedback. Injectable so tests can drive
    /// the handlers without a file panel.
    @StateObject var presetActions = PresetSettingsActions()
    /// Pending confirmations and per-row errors. Injectable for the same reason.
    @StateObject var interactions = SettingsInteractionState()
    @State private var showImporter = false
    @State private var showPresetEditor = false
    @State private var showImportPreview = false
    @State private var dryRunPreset: WatchedAppPreset?

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gear") }.tag(Tab.general)
            watchedAppsTab.tabItem { Label("Watched Apps", systemImage: "shield.lefthalf.filled") }.tag(Tab.watchedApps)
            autoStopTab.tabItem { Label("Auto-Stop", systemImage: "timer") }.tag(Tab.autoStop)
            hotkeyTab.tabItem { Label("Hotkey", systemImage: "keyboard") }.tag(Tab.hotkey)
            InstallationHealthView(settings: settings, watchedApps: watchedApps) { selectedTab = .watchedApps }
                .tabItem { Label("Health", systemImage: "checkmark.shield") }.tag(Tab.health)
            SupportDiagnosticsView(settings: settings, watchedApps: watchedApps, processManager: processManager)
                .tabItem { Label("Support", systemImage: "doc.text.magnifyingglass") }.tag(Tab.support)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                presetActions.loadImport(from: url, into: watchedApps)
                showImportPreview = presetActions.preview != nil
            case .failure(let err):
                presetActions.importError = err.localizedDescription
            }
        }
        .sheet(item: $editingRule, onDismiss: {
            editingRuleError = nil
            autoStopRules.clearValidationError()
        }) { rule in
            AutoStopRuleEditorSheet(
                rule: rule,
                validationError: editingRuleError,
                onSave: { updated in
                    if autoStopRules.update(updated) {
                        interactions.ruleRowErrors[updated.id] = nil
                        editingRule = nil
                        editingRuleError = nil
                    } else {
                        editingRuleError = autoStopRules.validationError
                            ?? "The auto-stop rule could not be saved."
                    }
                },
                onCancel: {
                    editingRule = nil
                    editingRuleError = nil
                    autoStopRules.clearValidationError()
                }
            )
        }
        .sheet(isPresented: $showPresetEditor) {
            presetEditorSheet
        }
        .sheet(isPresented: $showImportPreview) {
            importPreviewSheet
        }
        .sheet(item: $dryRunPreset) { preset in
            lifecycleDryRunSheet(for: preset)
        }
        // Deletions save at once and have no undo, so each one is confirmed.
        .confirmationDialog(
            presetDeletionTitle,
            isPresented: isPresenting($interactions.pendingPresetDeletions)
        ) {
            Button(interactions.pendingPresetDeletions.count > 1 ? "Delete Presets" : "Delete Preset", role: .destructive) {
                let presets = interactions.pendingPresetDeletions
                interactions.pendingPresetDeletions = []
                presets.forEach(deletePreset)
            }
            Button("Cancel", role: .cancel) { interactions.pendingPresetDeletions = [] }
        } message: {
            Text(presetDeletionMessage)
        }
        .confirmationDialog(
            ruleDeletionTitle,
            isPresented: isPresenting($interactions.pendingRuleDeletions)
        ) {
            Button(interactions.pendingRuleDeletions.count > 1 ? "Delete Rules" : "Delete Rule", role: .destructive) {
                let rules = interactions.pendingRuleDeletions
                interactions.pendingRuleDeletions = []
                rules.forEach(deleteRule)
            }
            Button("Cancel", role: .cancel) { interactions.pendingRuleDeletions = [] }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Clear all \(autoStopRules.events.count) auto-stop event\(autoStopRules.events.count == 1 ? "" : "s")?",
            isPresented: $interactions.isConfirmingClearEvents
        ) {
            Button("Clear Events", role: .destructive) {
                autoStopRules.clearEvents()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The event log cannot be restored after it is cleared.")
        }
        .onReceive(processManager.$isGlobalProtectKeepOffPending) { pending in
            isGlobalProtectKeepOffPending = pending
        }
    }

    /// Every sheet is sized to fit inside this window.
    static let windowSize = CGSize(width: 640, height: 600)
    static let presetEditorSheetSize = CGSize(width: 600, height: 540)
    static let importPreviewSheetSize = CGSize(width: 600, height: 540)
    static let dryRunSheetSize = CGSize(width: 560, height: 440)

    private var generalTab: some View {
        GeneralSettingsTab(
            settings: settings,
            notificationService: notificationService
        )
    }

    private var watchedAppsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Watched Apps").font(.headline)
                Spacer()
                Button {
                    prepareNewPreset()
                } label: {
                    Label("Add…", systemImage: "plus")
                }
                .disabled(watchedApps.isReadOnlyAfterCorruption)
                Button {
                    presetActions.export(from: watchedApps)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button {
                    // A new attempt replaces the last import's outcome.
                    presetActions.beginImport()
                    showImporter = true
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .disabled(watchedApps.isReadOnlyAfterCorruption)
            }
            .padding(.horizontal)

            Text(Self.builtInDaemonGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if !watchedApps.isReadOnlyAfterCorruption,
               !watchedApps.presets.contains(where: { $0.isBuiltInGlobalProtect }) {
                Button("Restore Built-in GlobalProtect Preset") {
                    refusedPresetDeletion = nil
                    if watchedApps.restoreBuiltInPreset() {
                        presetDeletionError = nil
                        presetActions.clearImportFeedback()
                    } else {
                        presetDeletionError = watchedApps.validationError
                            ?? "The built-in GlobalProtect preset could not be restored."
                    }
                }
                .help("Adds back the built-in preset with its Keep GlobalProtect Off and Disconnect controls.")
                .padding(.horizontal)
            }

            if let issue = watchedApps.persistenceIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    RecoveryResetButton(
                        subject: "Presets",
                        isBackupPreserved: watchedApps.isRecoveryBackupPreserved
                    ) {
                        watchedApps.resetAfterCorruption()
                        presetActions.exportError = nil
                    }
                }
                .padding(.horizontal)
            }
            if let message = presetDeletionRefusalMessage ?? presetDeletionError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            List {
                ForEach(watchedApps.presets) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(preset.displayName).fontWeight(.semibold)
                            Spacer()
                            if preset.isBuiltInGlobalProtect {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            // Read-only: stays available in recovery mode,
                            // where it is the way to review a recovered preset.
                            Button("Dry Run") {
                                dryRunPreset = preset
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dry run \(preset.displayName)")
                            if !preset.isBuiltInGlobalProtect {
                                Button("Edit…") {
                                    prepareToEdit(preset)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit preset \(preset.displayName)")
                                .disabled(watchedApps.isReadOnlyAfterCorruption)
                            }
                            Button("Delete…", role: .destructive) {
                                requestPresetDeletion([preset])
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete preset \(preset.displayName)")
                            .disabled(watchedApps.isReadOnlyAfterCorruption)
                            Toggle("Notify", isOn: Binding(
                                get: { preset.notificationsEnabled },
                                set: { newValue in
                                    var updated = preset
                                    updated.notificationsEnabled = newValue
                                    refusedPresetDeletion = nil
                                    if watchedApps.update(updated) {
                                        presetDeletionError = nil
                                    } else {
                                        presetDeletionError = watchedApps.validationError
                                            ?? "Could not update notifications for this preset."
                                    }
                                }
                            ))
                            .help("Notifications for this preset")
                            .accessibilityLabel("Notifications for \(preset.displayName)")
                            .disabled(watchedApps.isReadOnlyAfterCorruption)
                        }
                        if preset.hasUnknownFields {
                            Text("Requires a newer build — read-only, and its actions are unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Main: \(preset.mainProcessName)").font(.caption).foregroundStyle(.secondary)
                        if !preset.helperProcessNames.isEmpty {
                            Text("Helpers: \(preset.helperProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                        if !preset.protectedProcessNames.isEmpty {
                            Text("Protected: \(preset.protectedProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("App path: \(preset.appPath)").font(.caption).foregroundStyle(.secondary)
                        if preset.isBuiltInGlobalProtect {
                            GlobalProtectCompatibilityButton(
                                keepOffRequested: settings.isReadOnlyAfterCorruption
                                    ? nil : settings.keepGlobalProtectOff
                            )
                            .buttonStyle(.borderless)
                            Text("Built-in lifecycle: \(preset.systemLaunchDaemonJobs.count) protected system daemon\(preset.systemLaunchDaemonJobs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .moveDisabled(watchedApps.isReadOnlyAfterCorruption)
                    .deleteDisabled(watchedApps.isReadOnlyAfterCorruption)
                    .contextMenu {
                        Button("Delete Preset…", role: .destructive) {
                            requestPresetDeletion([preset])
                        }
                        .disabled(watchedApps.isReadOnlyAfterCorruption)
                    }
                    .disabled(preset.hasUnknownFields)
                }
                .onMove { from, to in
                    watchedApps.move(from: from, to: to)
                }
                .onDelete { offsets in
                    requestPresetDeletion(offsets.compactMap {
                        watchedApps.presets.indices.contains($0) ? watchedApps.presets[$0] : nil
                    })
                }
            }
            // Recovery mode disables only the mutating controls above, so the
            // read-only Dry Run and Compatibility Self-Check keep working.

            if let summary = presetActions.importSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let err = presetActions.importError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            if let err = presetActions.exportError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private var presetEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presetForm.editingPresetID == nil ? "Add Watched App" : "Edit Watched App")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextFieldRow(label: "Display name", text: $presetForm.displayName)
                    TextFieldRow(label: "Main process name", text: $presetForm.mainProcess)
                    TextFieldRow(label: "Helpers (comma-separated)", text: $presetForm.helpers)
                    TextFieldRow(label: "Protected (comma-separated)", text: $presetForm.protectedProcesses)
                    TextFieldRow(label: "App bundle path", text: $presetForm.appPath)

                    Divider().padding(.vertical, 4)
                    Text("Launch Agents (optional)").font(.headline)
                    TextFieldRow(label: "Labels", text: $presetForm.agentLabels)
                    TextFieldRow(label: "Plist paths", text: $presetForm.agentPlistPaths)

                    Divider().padding(.vertical, 4)
                    Text("System Launch Daemons").font(.headline)
                    Text(Self.builtInDaemonGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Only this editor's own errors: the store's shared error may belong
            // to an earlier import or deletion and would greet a blank form.
            if let error = presetActions.editorError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { showPresetEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button(presetForm.editingPresetID == nil ? "Add Preset" : "Save Changes") {
                    savePresetEditor()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(presetForm.mainProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: Self.presetEditorSheetSize.width, height: Self.presetEditorSheetSize.height)
    }

    @ViewBuilder
    var importPreviewSheet: some View {
        if let preview = presetActions.preview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preset Import Preview")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Preview only — no app, process, launch agent, or privileged operation runs during import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List(preview.items) { item in
                    let displayedPreset = item.normalizedPreset ?? item.preset
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayedPreset.displayName)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(item.isAccepted ? "Ready" : "Rejected")
                                .font(.caption)
                                .foregroundStyle(item.isAccepted ? Color.green : Color.red)
                        }
                        Text("Main process: \(displayedPreset.mainProcessName)")
                        Text("App path: \(displayedPreset.appPath)")
                        if !displayedPreset.helperProcessNames.isEmpty {
                            Text("Helpers: \(displayedPreset.helperProcessNames.joined(separator: ", "))")
                        }
                        if !displayedPreset.protectedProcessNames.isEmpty {
                            Text("Protected: \(displayedPreset.protectedProcessNames.joined(separator: ", "))")
                        }
                        ForEach(Array(displayedPreset.userLaunchAgentJobs.enumerated()), id: \.offset) { _, job in
                            Text(
                                "Launch agent: \(job.label) — \(job.plistPath)"
                                    + (job.isRequired ? "" : " (optional)")
                            )
                        }
                        ForEach(Array(displayedPreset.systemLaunchDaemonJobs.enumerated()), id: \.offset) { _, job in
                            Text("Fixed daemon: \(job.label) — \(job.plistPath)")
                        }
                        if let reason = item.rejectionReason {
                            Text(reason)
                                .foregroundStyle(.red)
                        } else {
                            Text("Import writes configuration only. Potential later operations:")
                                .foregroundStyle(.secondary)
                            ForEach(Self.lifecycleDryRunOperations(for: displayedPreset), id: \.self) { operation in
                                Text("• \(operation)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }

                Text("\(preview.importableCount) ready, \(preview.rejectedCount) rejected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        showImportPreview = false
                        presetActions.preview = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import \(preview.importableCount) Preset\(preview.importableCount == 1 ? "" : "s")") {
                        presetActions.commitImport(into: watchedApps)
                        showImportPreview = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.importableCount == 0)
                }
            }
            .padding(20)
            .frame(width: Self.importPreviewSheetSize.width, height: Self.importPreviewSheetSize.height)
        } else {
            Text("No import preview is available.")
                .padding()
        }
    }

    func lifecycleDryRunSheet(for preset: WatchedAppPreset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lifecycle Dry Run")
                .font(.title2)
                .fontWeight(.semibold)
            Text(preset.displayName)
                .font(.headline)
            Text("No process is signaled, app is opened, launch job is changed, or authorization is requested by this report.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(Self.lifecycleDryRunOperations(for: preset), id: \.self) { operation in
                Text(operation)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dryRunPreset = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.dryRunSheetSize.width, height: Self.dryRunSheetSize.height)
        // A read-only report: Escape closes it as Return does.
        .onExitCommand { dryRunPreset = nil }
    }

    static func lifecycleDryRunOperations(for preset: WatchedAppPreset) -> [String] {
        var operations = [
            "Open and ordinary quit actions first require a fresh process inventory; an unavailable inventory stops those actions."
        ]
        operations.append(contentsOf: preset.systemLaunchDaemonJobs.map { job in
            "Open: when the installed login-session VPN agent is available, preserve the separate system daemon disable override; otherwise re-enable fixed daemon \(job.label) at \(job.plistPath) with administrator approval when disabled; if absent, request approval to bootstrap it and verify \(job.processName)."
        })
        operations.append(contentsOf: preset.userLaunchAgentJobs.map { job in
            let availability = job.isRequired ? "" : " when it is installed"
            return "Open: inspect user launch agent \(job.label) at \(job.plistPath); load, enable, start, and verify it\(availability) only when not already loaded."
        })
        operations.append(
            "Open: open \(preset.appPath) only when \(preset.mainProcessName) is not already running, then verify it."
        )
        let agentPreset = preset.isBuiltInGlobalProtect ? preset.globalProtectInterfaceOnly : preset
        let agentLabels = agentPreset.lifecycleUserLaunchAgentJobs.map(\.label)
        // A custom preset's card names its full stop Quit App and Helpers. The
        // built-in GlobalProtect card has the stronger Quit All instead, so its
        // user-scope full stop is reachable only as the Shortcuts Stop action.
        let fullStop = preset.isBuiltInGlobalProtect ? "Shortcuts Stop" : "Quit App and Helpers"
        if !agentLabels.isEmpty {
            operations.append(
                "Quit App, Quit Helpers, or \(fullStop): unload and verify the user launch agents (\(agentLabels.joined(separator: ", "))) before signaling processes; Quit Helpers preserves an agent running the main process."
            )
        }
        operations.append(
            "Quit App: signal \(preset.mainProcessName) gracefully, escalating only if it remains running."
        )
        if !preset.helperProcessNames.isEmpty {
            operations.append(
                "Quit Helpers: signal only these app-scoped helpers: \(preset.helperProcessNames.joined(separator: ", "))."
            )
        }
        operations.append(
            "\(fullStop): run the Quit App and Quit Helpers targets above; protected names are excluded."
        )
        if !preset.protectedProcessNames.isEmpty {
            operations.append(
                "Never signal protected processes through these ordinary quits: \(preset.protectedProcessNames.joined(separator: ", "))."
            )
        }
        if preset.isBuiltInGlobalProtect {
            operations.append(
                "Quit All and Keep Off: use Accessibility to disconnect GlobalProtect, verify a stable disconnected state, then disable and unload its known services and stop its processes. An unverified disconnect stops the action before new Keep Off intent is saved. An explicit action requests administrator approval only if needed for the fixed system VPN service. Background enforcement never requests privileges. Open and turning Keep Off off restore the required VPN service and app. A window started without its service is closed and restored; an already running UI is not duplicated. For session-agent installations, the unused system daemon remains disabled."
            )
        }
        return operations
    }

    private var autoStopTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(autoStopRules.recoveryMessages, id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            if autoStopRules.isRulesReadOnlyAfterRecovery {
                RecoveryResetButton(
                    subject: "Auto-Stop Rules",
                    isBackupPreserved: autoStopRules.isRulesRecoveryBackupPreserved
                ) {
                    autoStopRules.resetRulesAfterCorruption()
                }
                .padding(.horizontal)
            }
            if autoStopRules.isEventsReadOnlyAfterRecovery {
                RecoveryResetButton(
                    subject: "Auto-Stop Events",
                    isBackupPreserved: autoStopRules.isEventsRecoveryBackupPreserved
                ) {
                    autoStopRules.resetEventsAfterCorruption()
                }
                .padding(.horizontal)
            }
            List {
                Section("Rules") {
                    if autoStopRules.rules.isEmpty {
                        Text(Self.noRulesMessage)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(autoStopRules.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { setRule(rule, enabled: $0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel("Enable rule \(rule.processName)")

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.processName).fontWeight(.medium)
                                if let warning = AutoStopRuleValidation.pathWarning(rule.executablePath) {
                                    Text(warning).font(.caption).foregroundStyle(.orange)
                                }
                                if rule.hasUnknownFields {
                                    Text("Requires a newer build — disabled and read-only")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("After \(rule.runtimeMinutes) min — \(rule.action.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let path = rule.executablePath {
                                    Text(path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                // A refused change is reported on its own row,
                                // not under the Add Rule form.
                                if let error = interactions.ruleRowErrors[rule.id] {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            Spacer()
                            Button("Edit…") {
                                editingRule = rule
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Edit rule \(rule.processName)")
                            Button("Duplicate") {
                                duplicateRule(rule)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Duplicate rule \(rule.processName)")
                            Button("Delete…", role: .destructive) {
                                interactions.pendingRuleDeletions = [rule]
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete rule \(rule.processName)")
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Edit…") { editingRule = rule }
                            Button("Duplicate") { duplicateRule(rule) }
                            Divider()
                            Button("Delete…", role: .destructive) { interactions.pendingRuleDeletions = [rule] }
                        }
                        .disabled(rule.hasUnknownFields)
                    }
                    .onDelete { offsets in
                        interactions.pendingRuleDeletions = offsets.compactMap {
                            autoStopRules.rules.indices.contains($0) ? autoStopRules.rules[$0] : nil
                        }
                    }
                }
                .disabled(autoStopRules.isRulesReadOnlyAfterRecovery)

                Section {
                    if autoStopRules.events.isEmpty {
                        Text("No auto-stop events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Every retained event (at most 200); the list is lazy.
                        ForEach(autoStopRules.events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.processName).fontWeight(.medium)
                                    Spacer()
                                    Text(event.outcome.label)
                                        .foregroundStyle(event.outcome == .failed ? .red : .secondary)
                                }
                                Text(Self.eventTimeAndPID(event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Events")
                        Spacer()
                        if !autoStopRules.events.isEmpty {
                            Button("Clear…") { interactions.isConfirmingClearEvents = true }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Clear all auto-stop events")
                                .disabled(autoStopRules.isEventsReadOnlyAfterRecovery)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Rule").font(.headline)
                TextFieldRow(label: "Process name", text: $newRuleName)
                TextFieldRow(label: "Executable path", text: $newRuleExecutablePath)
                Text("Required for Auto Stop; optional for Prompt and Log Only.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let warning = AutoStopRuleValidation.pathWarning(newRuleExecutablePath) {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                RuntimeMinutesControl(minutes: $newRuleMinutes)
                Picker("Action", selection: $newRuleAction) {
                    ForEach(AutoStopRule.Action.allCases) { Text($0.label).tag($0) }
                }
                Button("Add Rule") {
                    if autoStopRules.add(AutoStopRule(
                        processName: newRuleName,
                        executablePath: newRuleExecutablePath,
                        runtimeMinutes: newRuleMinutes,
                        action: newRuleAction
                    )) {
                        newRuleName = ""
                        newRuleExecutablePath = ""
                        newRuleMinutes = 5
                        interactions.addRuleError = nil
                    } else {
                        interactions.addRuleError = autoStopRules.validationError
                            ?? "The auto-stop rule could not be added."
                    }
                    autoStopRules.clearValidationError()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Only this form's own error: the store's shared message may
                // belong to another window's rule sheet.
                if let error = interactions.addRuleError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let error = autoStopRules.engineError {
                    Text("Auto-stop observation unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal)
            .disabled(autoStopRules.isRulesReadOnlyAfterRecovery)
        }
        .padding(.vertical)
    }

    private var hotkeyTab: some View {
        HotkeySettingsView()
    }

    /// Deleting the built-in GlobalProtect preset while Keep Off is on would
    /// orphan its persistent launchd disable override: nothing left in the app
    /// could clear it. The message names the way out.
    static func presetDeletionRefusal(
        for preset: WatchedAppPreset,
        keepGlobalProtectOff: Bool,
        isSettingsReadOnlyAfterCorruption: Bool = false,
        isGlobalProtectKeepOffPending: Bool = false
    ) -> String? {
        guard preset.isBuiltInGlobalProtect else { return nil }
        if isSettingsReadOnlyAfterCorruption {
            return "Settings are unreadable, so Keep GlobalProtect Off may still be active. Recover settings and clear Keep Off before deleting the built-in preset."
        }
        if isGlobalProtectKeepOffPending {
            return "Wait for the pending GlobalProtect Keep Off action to finish before deleting the built-in preset."
        }
        guard keepGlobalProtectOff else { return nil }
        return "Turn off Keep GlobalProtect Off (or choose Open) before deleting the built-in preset. Its user launch agents are disabled by a persistent launchd override that deleting the preset would not clear."
    }

    /// Re-derived on every draw so the refusal disappears once its cause
    /// (Keep Off, a pending Keep Off action, unreadable settings) is gone.
    private var presetDeletionRefusalMessage: String? {
        refusedPresetDeletion.flatMap {
            Self.presetDeletionRefusal(
                for: $0,
                keepGlobalProtectOff: settings.keepGlobalProtectOff,
                isSettingsReadOnlyAfterCorruption: settings.isReadOnlyAfterCorruption,
                isGlobalProtectKeepOffPending: isGlobalProtectKeepOffPending
            )
        }
    }

    /// A plain string: interpolating the PID into a Text literal would format
    /// it as a grouped number ("PID 48,165").
    static func eventTimeAndPID(_ event: AutoStopEvent) -> String {
        "\(event.timestamp.formatted(date: .abbreviated, time: .standard)) · PID \(String(event.pid))"
    }

    static let noRulesMessage = "No rules yet. Add one below, or right-click a process and choose Create Auto-Stop Rule…"

    /// Shows a refusal at once; otherwise asks for confirmation before deleting.
    private func requestPresetDeletion(_ presets: [WatchedAppPreset]) {
        guard !presets.isEmpty else { return }
        if let refused = presets.first(where: {
            Self.presetDeletionRefusal(
                for: $0,
                keepGlobalProtectOff: settings.keepGlobalProtectOff,
                isSettingsReadOnlyAfterCorruption: settings.isReadOnlyAfterCorruption,
                isGlobalProtectKeepOffPending: processManager.isGlobalProtectKeepOffPending
            ) != nil
        }) {
            refusedPresetDeletion = refused
            presetDeletionError = nil
            return
        }
        refusedPresetDeletion = nil
        interactions.pendingPresetDeletions = presets
    }

    private var presetDeletionTitle: String {
        let presets = interactions.pendingPresetDeletions
        if presets.count > 1 { return "Delete \(presets.count) presets?" }
        return "Delete “\(presets.first?.displayName ?? "")”?"
    }

    private var presetDeletionMessage: String {
        if interactions.pendingPresetDeletions.contains(where: { $0.isBuiltInGlobalProtect }) {
            return "Deleting the built-in GlobalProtect preset also removes its Keep GlobalProtect Off and Disconnect controls. Restore Built-in GlobalProtect Preset adds it back."
        }
        return "This cannot be undone."
    }

    private var ruleDeletionTitle: String {
        let rules = interactions.pendingRuleDeletions
        if rules.count > 1 { return "Delete \(rules.count) auto-stop rules?" }
        return "Delete the auto-stop rule for “\(rules.first?.processName ?? "")”?"
    }

    private func isPresenting<Item>(_ pending: Binding<[Item]>) -> Binding<Bool> {
        Binding(
            get: { !pending.wrappedValue.isEmpty },
            set: { if !$0 { pending.wrappedValue = [] } }
        )
    }

    private func setRule(_ rule: AutoStopRule, enabled: Bool) {
        reportRuleResult(
            autoStopRules.setEnabled(enabled, for: rule),
            for: rule,
            fallback: "The rule could not be updated."
        )
    }

    private func duplicateRule(_ rule: AutoStopRule) {
        reportRuleResult(
            autoStopRules.duplicate(rule),
            for: rule,
            fallback: "The rule could not be duplicated."
        )
    }

    private func deleteRule(_ rule: AutoStopRule) {
        reportRuleResult(
            autoStopRules.remove(rule),
            for: rule,
            fallback: "The rule could not be deleted."
        )
    }

    /// Moves the store's shared reason for a refused row action onto that row.
    private func reportRuleResult(_ succeeded: Bool, for rule: AutoStopRule, fallback: String) {
        interactions.ruleRowErrors[rule.id] = succeeded ? nil : (autoStopRules.validationError ?? fallback)
        autoStopRules.clearValidationError()
    }

    private func deletePreset(_ preset: WatchedAppPreset) {
        if Self.presetDeletionRefusal(
            for: preset,
            keepGlobalProtectOff: settings.keepGlobalProtectOff,
            isSettingsReadOnlyAfterCorruption: settings.isReadOnlyAfterCorruption,
            isGlobalProtectKeepOffPending: processManager.isGlobalProtectKeepOffPending
        ) != nil {
            refusedPresetDeletion = preset
            presetDeletionError = nil
            return
        }
        refusedPresetDeletion = nil
        if watchedApps.remove(preset) {
            presetDeletionError = nil
            presetActions.clearImportFeedback()
        } else {
            presetDeletionError = watchedApps.validationError
        }
    }

    private func prepareNewPreset() {
        presetForm.prepareForNewPreset()
        presetActions.editorError = nil
        showPresetEditor = true
    }

    private func prepareToEdit(_ preset: WatchedAppPreset) {
        presetForm.prepareForEditing(preset)
        presetActions.editorError = nil
        showPresetEditor = true
    }

    private func savePresetEditor() {
        if presetActions.saveEditor(presetForm, into: watchedApps) {
            showPresetEditor = false
        }
    }
}

private struct TextFieldRow: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label).frame(width: 180, alignment: .leading)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}
