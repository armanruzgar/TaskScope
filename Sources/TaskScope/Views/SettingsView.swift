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
    @State private var exportError: String?
    @State private var importError: String?
    @State private var presetValidationError: String?
    @State private var showImporter = false
    @State private var showPresetEditor = false
    @State private var showImportPreview = false
    @State private var importPreview: WatchedAppsStore.ImportPreview?
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
                importPresets(from: url)
            case .failure(let err):
                importError = err.localizedDescription
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
                    Label("Add", systemImage: "plus")
                }
                .disabled(watchedApps.isReadOnlyAfterCorruption)
                Button {
                    exportPresets()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(watchedApps.isReadOnlyAfterCorruption)
            }
            .padding(.horizontal)

            Text(Self.builtInDaemonGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if let issue = watchedApps.persistenceIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Reset Presets After Backup", role: .destructive) {
                        watchedApps.resetAfterCorruption()
                        exportError = nil
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
                            if preset.id == WatchedAppPreset.globalProtectID {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Dry Run") {
                                dryRunPreset = preset
                            }
                            .buttonStyle(.borderless)
                            if preset.id != WatchedAppPreset.globalProtectID {
                                Button("Edit") {
                                    prepareToEdit(preset)
                                }
                                .buttonStyle(.borderless)
                            }
                            Button("Delete", role: .destructive) {
                                deletePreset(preset)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete preset \(preset.displayName)")
                            Toggle("", isOn: Binding(
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
                            .labelsHidden()
                            .help("Notifications for this preset")
                            .accessibilityLabel("Notifications for \(preset.displayName)")
                        }
                        Text("Main: \(preset.mainProcessName)").font(.caption).foregroundStyle(.secondary)
                        Text("Helpers: \(preset.helperProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        Text("Protected: \(preset.protectedProcessNames.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        Text("App path: \(preset.appPath)").font(.caption).foregroundStyle(.tertiary)
                        if preset.id == WatchedAppPreset.globalProtectID {
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
                    .contextMenu {
                        Button("Delete Preset", role: .destructive) {
                            deletePreset(preset)
                        }
                    }
                }
                .onMove { from, to in
                    watchedApps.move(from: from, to: to)
                }
                .onDelete { offsets in
                    for preset in offsets.compactMap({ watchedApps.presets.indices.contains($0) ? watchedApps.presets[$0] : nil }) {
                        deletePreset(preset)
                    }
                }
            }
            .disabled(watchedApps.isReadOnlyAfterCorruption)

            if let err = importError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            if let err = exportError {
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
                    Text(editingSystemLaunchDaemonJobs.isEmpty
                         ? "System Launch Daemons"
                         : "Built-in System Launch Daemons")
                        .font(.headline)
                    ForEach(editingSystemLaunchDaemonJobs.indices, id: \.self) { index in
                        let job = editingSystemLaunchDaemonJobs[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.label).fontWeight(.medium)
                            Text("\(job.processName) · \(job.plistPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(Self.builtInDaemonGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Only this editor's own errors: the store's shared error may belong
            // to an earlier import or deletion and would greet a blank form.
            if let error = presetValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showPresetEditor = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
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
    private var importPreviewSheet: some View {
        if let preview = importPreview {
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
                    Button("Cancel") {
                        showImportPreview = false
                        importPreview = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import \(preview.importableCount) Preset\(preview.importableCount == 1 ? "" : "s")") {
                        let result = watchedApps.importPresets(preview.items.map(\.preset))
                        importError = result.rejectedCount == 0
                            ? nil
                            : "\(result.rejectedCount) preset\(result.rejectedCount == 1 ? " was" : "s were") rejected by validation."
                        showImportPreview = false
                        importPreview = nil
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

    private func lifecycleDryRunSheet(for preset: WatchedAppPreset) -> some View {
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
                Button("Close") { dryRunPreset = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.dryRunSheetSize.width, height: Self.dryRunSheetSize.height)
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
        let agentPreset = preset.hasSupportedGlobalProtectIdentity ? preset.globalProtectInterfaceOnly : preset
        let agentLabels = agentPreset.lifecycleUserLaunchAgentJobs.map(\.label)
        if !agentLabels.isEmpty {
            operations.append(
                "Quit App, Quit Helpers, or Close All: unload and verify the user launch agents (\(agentLabels.joined(separator: ", "))) before signaling processes; Quit Helpers preserves an agent running the main process."
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
            "Close All: run the Quit App and Quit Helpers targets above; protected names are excluded."
        )
        if !preset.protectedProcessNames.isEmpty {
            operations.append(
                "Never signal protected processes through ordinary close: \(preset.protectedProcessNames.joined(separator: ", "))."
            )
        }
        if preset.id == WatchedAppPreset.globalProtectID {
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
                Button("Reset Auto-Stop Rules After Backup", role: .destructive) {
                    autoStopRules.resetRulesAfterCorruption()
                }
                .padding(.horizontal)
            }
            if autoStopRules.isEventsReadOnlyAfterRecovery {
                Button("Reset Auto-Stop Events After Backup", role: .destructive) {
                    autoStopRules.resetEventsAfterCorruption()
                }
                .padding(.horizontal)
            }
            List {
                Section("Rules") {
                    ForEach(autoStopRules.rules) { rule in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { autoStopRules.setEnabled($0, for: rule) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel("Enable rule \(rule.processName)")

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.processName).fontWeight(.medium)
                                if rule.hasUnknownFields {
                                    Text("Requires a newer build — disabled and read-only")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("After \(rule.runtimeMinutes) min — \(rule.action.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let path = rule.executablePath {
                                    Text(path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Edit") {
                                editingRule = rule
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Edit") { editingRule = rule }
                            Button("Duplicate") { autoStopRules.duplicate(rule) }
                            Divider()
                            Button("Delete", role: .destructive) { autoStopRules.remove(rule) }
                        }
                        .disabled(rule.hasUnknownFields)
                    }
                    .onDelete { autoStopRules.remove(at: $0) }
                }
                .disabled(autoStopRules.isRulesReadOnlyAfterRecovery)

                Section {
                    if autoStopRules.events.isEmpty {
                        Text("No auto-stop events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(autoStopRules.events.prefix(50)) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(event.processName).fontWeight(.medium)
                                    Spacer()
                                    Text(event.outcome.label)
                                        .foregroundStyle(event.outcome == .failed ? .red : .secondary)
                                }
                                Text("\(event.timestamp.formatted(date: .abbreviated, time: .standard)) · PID \(event.pid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Events")
                        Spacer()
                        if !autoStopRules.events.isEmpty {
                            Button("Clear") { autoStopRules.clearEvents() }
                                .buttonStyle(.borderless)
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
                Stepper(
                    value: $newRuleMinutes,
                    in: 1...AutoStopRulesStore.maximumRuntimeMinutes,
                    step: 1
                ) {
                    HStack {
                        Text("Runtime minutes")
                        Spacer()
                        Text("\(newRuleMinutes)").monospacedDigit()
                    }
                }
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
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let error = autoStopRules.validationError {
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
        guard preset.id == WatchedAppPreset.globalProtectID else { return nil }
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
        } else {
            presetDeletionError = watchedApps.validationError
        }
    }

    private func prepareNewPreset() {
        presetForm.prepareForNewPreset()
        presetValidationError = nil
        showPresetEditor = true
    }

    private func prepareToEdit(_ preset: WatchedAppPreset) {
        presetForm.prepareForEditing(preset)
        presetValidationError = nil
        showPresetEditor = true
    }

    private var editingSystemLaunchDaemonJobs: [SystemLaunchDaemonJob] {
        guard presetForm.editingPresetID == WatchedAppPreset.globalProtectID else { return [] }
        return watchedApps.presets
            .first(where: { $0.id == WatchedAppPreset.globalProtectID })?
            .systemLaunchDaemonJobs ?? []
    }

    private func savePresetEditor() {
        let existing = presetForm.editingPresetID.flatMap { id in
            watchedApps.presets.first(where: { $0.id == id })
        }
        let preset: WatchedAppPreset
        switch presetForm.makePreset(existing: existing) {
        case .success(let value):
            preset = value
        case .failure(let error):
            presetValidationError = error.message
            return
        }
        let saved = existing == nil ? watchedApps.add(preset) : watchedApps.update(preset)
        guard saved else {
            presetValidationError = watchedApps.validationError
            return
        }
        presetValidationError = nil
        showPresetEditor = false
    }

    private func exportPresets() {
        // In corrupt mode the in-memory list is the empty array we fell back to, not
        // the user's presets. Exporting it would write a valid-looking but empty
        // backup — precisely when the banner is telling them to back up first.
        guard watchedApps.canExportPresets else {
            exportError = "Preset data is unreadable, so there is nothing to export. "
                + "Recover the backup noted above before resetting."
            return
        }
        guard let data = try? watchedApps.encodedPresetArchive() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TaskScope-presets.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                exportError = nil
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func importPresets(from url: URL) {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (resourceValues.fileSize ?? 0) <= WatchedAppsStore.maximumPresetArchiveBytes else {
                importError = "Preset archives must be 1 MB or smaller."
                return
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let decoded = try WatchedAppsStore.decodePresetArchive(data)
            importPreview = watchedApps.previewImport(decoded)
            importError = nil
            showImportPreview = true
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? "Could not read presets from file."
            return
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
