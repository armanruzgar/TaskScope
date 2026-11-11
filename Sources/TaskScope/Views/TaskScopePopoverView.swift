import AppKit
import SwiftUI

struct TaskScopePopoverView: View {
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var loginItemManager: LoginItemManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var watchedApps: WatchedAppsStore
    @ObservedObject var savedSelections: SavedSelectionsStore
    @ObservedObject var autoStopRules: AutoStopRulesStore
    @ObservedObject var history: ProcessHistory
    var presentationStyle: TaskScopePresentationStyle = .menuBarCompact
    var openFullWindow: (() -> Void)?
    private let activityMonitor: any ActivityMonitorCoordinating
    private let menuBarConfirmation: (any MenuBarConfirming)?
    @StateObject private var confirmationState: ProcessConfirmationState
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var shownLifecycleReportID: LifecycleReport.ID?
    @State private var shownBatchActionReportID: ProcessBatchActionReport.ID?

    @State private var detailProcess: AppProcess?
    @State private var detailData: ProcessDetail?
    @State private var detailFailed: Bool = false
    @State private var keyboardSelectedPid: Int32?
    /// The identity of the focused row, so a recycled PID cannot inherit focus
    /// and turn Return into a stop request for a different process.
    @State private var keyboardSelectedIdentity: ProcessIdentity?
    @State private var filterMode: ProcessFilterMode = .all
    @State private var treeMode: Bool = false
    @State private var expandedTreePids: Set<Int32> = []
    @State private var saveSelectionName: String = ""
    @State private var showSaveSelectionSheet: Bool = false
    @State private var pendingRecallSelection: SavedSelectionsStore.SavedSelection?
    @State private var pendingRecallResult: SavedSelectionsStore.RecallResult?
    @State private var renameSelection: SavedSelectionsStore.SavedSelection?
    @State private var renameSelectionName = ""
    @State private var quickAutoStopProcess: AppProcess?
    @State private var quickPresetDraft: QuickWatchedPresetDraft?
    @State private var registeredExtendedMetrics = false
    /// The list must own focus for `.onKeyPress` to receive arrow, Return, and
    /// Escape without Full Keyboard Access; tapping a row moves focus here.
    @FocusState private var processListFocused: Bool

    @MainActor
    init(
        processManager: ProcessManager,
        loginItemManager: LoginItemManager,
        settings: SettingsStore,
        watchedApps: WatchedAppsStore,
        savedSelections: SavedSelectionsStore,
        autoStopRules: AutoStopRulesStore,
        history: ProcessHistory,
        presentationStyle: TaskScopePresentationStyle = .menuBarCompact,
        openFullWindow: (() -> Void)? = nil,
        confirmationState: ProcessConfirmationState? = nil,
        activityMonitor: (any ActivityMonitorCoordinating)? = nil,
        menuBarConfirmation: (any MenuBarConfirming)? = nil
    ) {
        self.processManager = processManager
        self.loginItemManager = loginItemManager
        self.settings = settings
        self.watchedApps = watchedApps
        self.savedSelections = savedSelections
        self.autoStopRules = autoStopRules
        self.history = history
        self.presentationStyle = presentationStyle
        self.openFullWindow = openFullWindow
        self.activityMonitor = activityMonitor ?? ActivityMonitorCoordinator()
        self.menuBarConfirmation = menuBarConfirmation
        _confirmationState = StateObject(
            wrappedValue: confirmationState ?? ProcessConfirmationState()
        )
    }

    private var isExpandedWindow: Bool {
        presentationStyle == .expandedWindow
    }

    var body: some View {
        autoStopAlertContent
    }

    private var baseContent: some View {
        VStack(spacing: 0) {
            header
            sectionPicker

            Divider()

            Group {
                switch settings.selectedSection {
                case .processes:
                    processList
                case .presets:
                    presetsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .background(.regularMaterial)
    }

    private var observedContent: some View {
        baseContent
        .task { await processManager.beginObservingStatus() }
        .onAppear {
            guard isExpandedWindow, !registeredExtendedMetrics else { return }
            registeredExtendedMetrics = true
            history.beginSampling(cadence: settings.refreshIntervalSeconds)
            Task { await processManager.beginExtendedMetrics() }
        }
        .onDisappear {
            processManager.endObservingStatus()
            guard registeredExtendedMetrics else { return }
            registeredExtendedMetrics = false
            history.endSampling()
            processManager.endExtendedMetrics()
        }
        .onChange(of: processManager.inventoryGeneration) { _, _ in
            // Forget disclosure state for processes that no longer exist; a
            // recycled pid must not inherit an old expansion.
            let livePIDs = Set(processManager.inventorySnapshot.map(\.pid))
            // Search can show processes below the unfiltered display limit.
            // Preserve their keyboard focus for as long as they are live.
            if let pid = keyboardSelectedPid {
                let live = processManager.inventorySnapshot.first { $0.pid == pid }
                if live == nil || (keyboardSelectedIdentity.map { $0 != live?.identity } ?? false) {
                    keyboardSelectedPid = nil
                }
            }
            expandedTreePids = expandedTreePids.intersection(livePIDs)
        }
        // Ancestors are expanded once per *filter* change, never on every poll,
        // so a node collapsed while searching stays collapsed.
        .onChange(of: settings.searchText) { _, _ in
            expandFilteredTreeAncestors()
        }
        .onChange(of: filterMode) { _, _ in
            expandFilteredTreeAncestors()
        }
        .onChange(of: treeMode) { _, enabled in
            if enabled {
                expandFilteredTreeAncestors()
            }
        }
        // A persisted search can be active before the first list loads; expand
        // its matches' ancestors once there is a tree to expand.
        .onChange(of: processManager.hasLoadedProcessList) { _, loaded in
            if loaded {
                expandFilteredTreeAncestors()
            }
        }
        .onChange(of: keyboardSelectedPid) { _, pid in
            keyboardSelectedIdentity = pid.flatMap { pid in
                processManager.inventorySnapshot.first { $0.pid == pid }?.identity
            }
            if pid != nil {
                processListFocused = true
            }
        }
        // Selection is deliberately *not* pruned to the rows currently rendered:
        // typing a search, toggling tree mode, or collapsing a node changes what
        // is visible, not what the user chose. ProcessManager prunes on
        // inventory liveness only, and batch actions act on the full selection,
        // which the dialog lists.
    }

    private var terminationConfirmationContent: some View {
        observedContent
        .confirmationDialog(
            confirmationState.pendingTermination?.mode.title ?? "Stop Process?",
            isPresented: terminationConfirmationBinding,
            presenting: confirmationState.pendingTermination
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) {
                stopProcess(pending)
                confirmationState.clearTermination()
            }

            Button("Cancel", role: .cancel) {
                confirmationState.clearTermination()
            }
        } message: { pending in
            Text(pending.message)
        }
        .confirmationDialog(
            confirmationState.pendingBatchTermination?.title ?? "Stop Selected Processes?",
            isPresented: batchConfirmationBinding,
            presenting: confirmationState.pendingBatchTermination
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) {
                stopSelection(pending)
                confirmationState.clearBatch()
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearBatch()
            }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var presetConfirmationContent: some View {
        terminationConfirmationContent
        .confirmationDialog(
            confirmationState.pendingPresetAction?.title ?? "Confirm Preset Action",
            isPresented: presetConfirmationBinding,
            presenting: confirmationState.pendingPresetAction
        ) { pending in
            Button(pending.title, role: .destructive) {
                confirmationState.clearPresetAction()
                runPresetAction(pending)
            }
            Button("Cancel", role: .cancel) {
                confirmationState.clearPresetAction()
            }
        } message: { pending in
            Text(presetConfirmationMessage(for: pending))
        }
        // A preset removed or edited while its confirmation is pending must not
        // stay confirmable: confirming would act on the stale copy.
        .onChange(of: watchedApps.presets) { _, presets in
            if let pending = confirmationState.pendingPresetAction,
               presets.first(where: { $0.id == pending.preset.id }) != pending.preset {
                confirmationState.clearPresetAction()
            }
        }
        // The menu-bar window asks outside itself; see `MenuBarConfirming`.
        .onChange(of: confirmationState.pendingTermination) { _, pending in
            guard let pending else { return }
            confirmInMenuBar(
                MenuBarConfirmationRequest(title: pending.mode.title, message: pending.message, confirmTitle: pending.confirmTitle),
                isCurrent: { $0.pendingTermination == pending },
                clear: { $0.clearTermination() },
                perform: { stopProcess(pending) }
            )
        }
        .onChange(of: confirmationState.pendingBatchTermination) { _, pending in
            guard let pending else { return }
            confirmInMenuBar(
                MenuBarConfirmationRequest(title: pending.title, message: pending.message, confirmTitle: pending.confirmTitle),
                isCurrent: { $0.pendingBatchTermination == pending },
                clear: { $0.clearBatch() },
                perform: { stopSelection(pending) }
            )
        }
        .onChange(of: confirmationState.pendingPresetAction) { _, pending in
            guard let pending else { return }
            confirmInMenuBar(
                MenuBarConfirmationRequest(title: pending.title, message: presetConfirmationMessage(for: pending), confirmTitle: pending.title),
                isCurrent: { $0.pendingPresetAction == pending },
                clear: { $0.clearPresetAction() },
                perform: { runPresetAction(pending) }
            )
        }
    }

    private func confirmInMenuBar(
        _ request: MenuBarConfirmationRequest,
        isCurrent: @escaping @MainActor (ProcessConfirmationState) -> Bool,
        clear: @escaping @MainActor (ProcessConfirmationState) -> Void,
        perform: @escaping @MainActor () -> Void
    ) {
        guard let menuBarConfirmation else { return }
        // The menu window may close while the alert is up; keep the state it
        // asked about rather than reading this view's storage afterwards.
        let state = confirmationState
        Task {
            // Leave the view update that queued the request before the alert
            // runs its modal loop.
            await Task.yield()
            guard isCurrent(state) else { return }
            let confirmed = await menuBarConfirmation.confirm(request)
            clear(state)
            if confirmed { perform() }
        }
    }

    private func stopProcess(_ pending: ProcessConfirmationState.PendingTermination) {
        let process = pending.process
        let forceKill = pending.mode == .force
        let manager = processManager
        Task { await manager.terminate(process, forceKill: forceKill) }
    }

    private func stopSelection(_ pending: ProcessConfirmationState.PendingBatchTermination) {
        let targets = pending.targets
        let forceKill = pending.mode == .force
        let manager = processManager
        Task { await manager.batchTerminate(targets, forceKill: forceKill) }
    }

    private func runPresetAction(_ pending: ProcessConfirmationState.PendingPresetAction) {
        let preset = pending.preset
        let action = pending.action
        let failureID = pending.disconnectFailureID
        let presentsResult = preset.hasCanonicalGlobalProtectIdentity
            && (action == .quitAll || action == .keepOff || action == .stopServices)
        let showResult = openFullWindow
        let isExpandedWindow = isExpandedWindow
        let manager = processManager
        Task {
            // GlobalProtect opens its own menu to disconnect, which
            // dismisses MenuBarExtra. Keep this user-requested action
            // and its result visible in the regular window instead.
            if !isExpandedWindow, presentsResult {
                await Task.yield()
                showResult?()
            }
            switch action {
            case .quitApp:
                _ = await manager.quitMainApp(preset)
            case .quitHelpers:
                _ = await manager.quitHelpers(preset)
            case .quitAll:
                _ = await manager.quitAll(preset)
            case .keepOff:
                _ = await manager.keepOff(preset)
            case .stopServices:
                if let failureID {
                    _ = await manager.stopGlobalProtectAfterFailedDisconnect(failureID: failureID)
                }
            }
            // The vendor UI or authorization dialog may have taken
            // focus. Bring the completed result back to the user.
            if presentsResult { showResult?() }
        }
    }

    private var processDetailContent: some View {
        presetConfirmationContent
        .sheet(item: $detailProcess) { process in
            ProcessDetailSheet(
                process: process,
                detail: detailData,
                failed: detailFailed,
                onClose: {
                    detailProcess = nil
                    detailData = nil
                    detailFailed = false
                }
            )
            .task(id: process.pid) {
                detailData = nil
                detailFailed = false
                let result = await processManager.detail(for: process)
                // The sheet may have moved to another process, or closed,
                // while the read was in flight.
                guard !Task.isCancelled, detailProcess?.pid == process.pid else { return }
                if let result {
                    detailData = result
                } else {
                    detailFailed = true
                }
            }
        }
    }

    private var savedSelectionSheetContent: some View {
        processDetailContent
        .sheet(isPresented: $showSaveSelectionSheet) {
            SaveSelectionSheet(
                name: $saveSelectionName,
                    count: processManager.selectedPids.count,
                validationError: savedSelections.validationError,
                onSave: {
                    if savedSelections.save(
                        name: saveSelectionName,
                        processes: processManager.selectedProcessesSnapshot()
                    ) {
                        showSaveSelectionSheet = false
                    }
                },
                onCancel: {
                    showSaveSelectionSheet = false
                }
            )
        }
        .sheet(item: $pendingRecallSelection) { selection in
            if let result = pendingRecallResult {
                SavedSelectionRecallSheet(
                    selection: selection,
                    result: result,
                    onApply: {
                        processManager.select(result.matched)
                        pendingRecallSelection = nil
                        pendingRecallResult = nil
                    },
                    onCancel: {
                        pendingRecallSelection = nil
                        pendingRecallResult = nil
                    }
                )
            }
        }
        .sheet(item: $renameSelection) { selection in
            RenameSavedSelectionSheet(
                originalName: selection.name,
                name: $renameSelectionName,
                validationError: savedSelections.validationError,
                onSave: {
                    if savedSelections.rename(selection, to: renameSelectionName) {
                        renameSelection = nil
                    }
                },
                onCancel: { renameSelection = nil }
            )
        }
    }

    private var reportSheetContent: some View {
        savedSelectionSheetContent
        .sheet(
            item: lifecycleReportBinding
        ) { report in
            LifecycleReportSheet(
                report: report,
                onClose: { processManager.dismissLifecycleReport() }
            )
            .onAppear { shownLifecycleReportID = report.id }
        }
        .sheet(
            item: batchActionReportBinding
        ) { report in
            ProcessBatchActionReportSheet(
                report: report,
                onClose: { processManager.dismissBatchActionReport() }
            )
            .onAppear { shownBatchActionReportID = report.id }
        }
    }

    private var quickActionSheetContent: some View {
        reportSheetContent
        .sheet(item: $quickAutoStopProcess) { process in
            QuickAutoStopRuleSheet(
                process: process,
                existingRule: QuickAutoStopRuleSaver.existingRule(for: process, in: autoStopRules),
                onSave: { processName, runtimeMinutes, action in
                    saveQuickAutoStopRule(
                        processName: processName,
                        runtimeMinutes: runtimeMinutes,
                        action: action
                    )
                },
                onCancel: {
                    quickAutoStopProcess = nil
                }
            )
        }
        .sheet(item: $quickPresetDraft) { draft in
            QuickWatchedPresetSheet(
                draft: draft,
                onSave: { preset in
                    saveQuickWatchedPreset(preset)
                },
                onCancel: {
                    quickPresetDraft = nil
                }
            )
        }
    }

    private var autoStopAlertContent: some View {
        quickActionSheetContent
        .background {
            // Replace only the alert presenter when the queue head changes.
            // The list and its focus/selection keep their own identity.
            AutoStopPromptAlert(prompt: autoStopRules.currentPrompt, rules: autoStopRules)
                .id(autoStopRules.currentPrompt?.id)
        }
    }

    private var header: some View {
        TaskScopeHeaderView(
            status: processManager.snapshots.filter { watchedApps.presets.contains($0.preset) }.aggregateStatus,
            watchedStatusAvailability: processManager.watchedStatusAvailability.forPresets(
                watchedApps.presets, snapshots: processManager.snapshots
            ),
            samples: history.samples,
            samplingState: history.state,
            showsMetrics: isExpandedWindow,
            showsOpenWindowButton: presentationStyle == .menuBarCompact && openFullWindow != nil,
            openFullWindow: openFullWindow,
            refreshAction: refreshVisibleSection
        )
    }

    private var sectionPicker: some View {
        Picker("Section", selection: Binding(
            get: { settings.selectedSection },
            set: { settings.selectedSectionRaw = $0.rawValue }
        )) {
            ForEach(TaskScopeSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var processList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search processes", text: $settings.searchText)
                    .textFieldStyle(.plain)

                if !settings.searchText.isEmpty {
                    Button {
                        settings.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear Search")
                    .accessibilityLabel("Clear process search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // The compact popover cannot fit every control on one row once a
            // selection adds its actions, so the selection controls wrap below.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    processListDisplayControls
                    selectionControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        processListDisplayControls
                    }
                    HStack(spacing: 8) {
                        selectionControls
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if processManager.hasLoadedProcessList,
               let processLoadError = processManager.processListLoadError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Process list is stale")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(staleProcessListDetail(error: processLoadError))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Retry") {
                        Task { await processManager.loadProcessList() }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)
            }

            HStack {
                Text(processCountTitle)
                if let updated = processManager.lastSuccessfulInventoryAt,
                   !settings.autoRefreshProcessList {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .help("Time the displayed process snapshot was last refreshed")
                }
                if isExpandedWindow {
                    Spacer()
                    Text("PID")
                        .frame(width: 70, alignment: .trailing)
                    Text("PPID")
                        .frame(width: 70, alignment: .trailing)
                    Text("NET KB TOTAL")
                        .frame(width: 96, alignment: .trailing)
                    Text("DISK MB TOTAL")
                        .frame(width: 96, alignment: .trailing)
                } else {
                    Spacer()
                }
                Text("CPU")
                    .frame(width: 54, alignment: .trailing)
                Text("MEM MB")
                    .frame(width: 64, alignment: .trailing)
                Text("")
                    .frame(width: 28)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

            if !processManager.hasLoadedProcessList, processManager.hasAttemptedProcessListLoad,
               let error = processManager.processListLoadError {
                firstLoadFailedState(error: error)
            } else if processManager.hasLoadedProcessList, filteredProcesses.isEmpty {
                // Rows exist but the filter matched none of them; the stale-list
                // banner above already reports a failed refresh, so this state is
                // only about the filter.
                noMatchingProcessesState
            } else if processManager.hasLoadedProcessList {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if treeMode {
                                ForEach(treeRoots, id: \.id) { node in
                                    ProcessTreeRow(
                                        node: node,
                                        depth: 0,
                                        settings: settings,
                                        processManager: processManager,
                                        keyboardSelectedPid: $keyboardSelectedPid,
                                        pendingTermination: pendingTerminationBinding,
                                        expandedPids: $expandedTreePids,
                                        showsExpandedMetrics: isExpandedWindow,
                                        requestListFocus: { processListFocused = true },
                                        contextMenuContent: { process in
                                            processContextMenu(for: process)
                                        }
                                    )
                                }
                            } else {
                                ForEach(filteredProcesses) { process in
                                    processRowView(for: process)
                                        .id(process.pid)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            keyboardSelectedPid = process.pid
                                            processListFocused = true
                                        }
                                        .contextMenu {
                                            processContextMenu(for: process)
                                        }
                                }
                            }
                        }
                    }
                    .focusable()
                    .focused($processListFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) {
                        moveKeyboard(by: -1, in: keyboardNavigationProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboard(by: 1, in: keyboardNavigationProcesses, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        requestKeyboardTermination(pid: keyboardSelectedPid)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        processManager.clearSelection()
                        keyboardSelectedPid = nil
                        return .handled
                    }
                    .onKeyPress { keyPress in
                        // Shift may arrive applied to the character ("A"), and Caps
                        // Lock adds a modifier, so compare case-insensitively and
                        // ignore modifiers that do not change the shortcut.
                        guard keyPress.characters.lowercased() == "a" else { return .ignored }
                        let modifiers = keyPress.modifiers.subtracting([.capsLock, .numericPad])
                        if modifiers == .command {
                            processManager.select(selectableProcesses)
                            return .handled
                        }
                        if modifiers == [.command, .shift] {
                            processManager.clearSelection()
                            return .handled
                        }
                        return .ignored
                    }
                }
            } else {
                LightweightEmptyState {
                    Task {
                        await processManager.loadProcessList()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var processListDisplayControls: some View {
        Picker("Sort", selection: Binding(
            get: { settings.sortKey },
            set: { newValue in
                settings.sortKeyRaw = newValue.rawValue
                processManager.sortKey = newValue
            }
        )) {
            ForEach(ProcessSortKey.allCases) { key in
                Text(key.label).tag(key)
            }
        }
        .pickerStyle(.menu)
        // A fixed frame shared with the visible label truncated the selected
        // key on macOS 26, so the popup sizes itself to its widest key.
        .labelsHidden()
        .fixedSize()
        .help("Sort By")
        .accessibilityLabel("Sort")

        Picker("Filter", selection: $filterMode) {
            ForEach(ProcessFilterMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        Toggle(isOn: $treeMode) {
            Label("Tree", systemImage: "list.bullet.indent")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help("Tree View")
        .accessibilityLabel("Tree view")
        .accessibilityValue(treeMode ? "On" : "Off")
    }

    @ViewBuilder
    private var selectionControls: some View {
        Menu {
            if let recoveryMessage = savedSelections.recoveryMessage {
                Text(recoveryMessage)
                if savedSelections.isReadOnlyAfterCorruption {
                    // Saving stays disabled until this is pressed, so without
                    // it the user could never save a selection again.
                    Button("Reset Saved Selections After Backup") {
                        savedSelections.resetAfterCorruption()
                    }
                }
                Divider()
            }
            if savedSelections.selections.isEmpty {
                Text("No saved selections")
            } else {
                ForEach(savedSelections.selections) { sel in
                    Menu(sel.name) {
                        Button("Preview & Recall…") {
                            // Resolve against a fresh inventory: the list may
                            // never have been loaded, or may be a poll old.
                            Task {
                                guard await processManager.loadProcessList(showMessage: false) else {
                                    pendingRecallResult = nil
                                    pendingRecallSelection = nil
                                    processManager.setMessage("Could not preview saved selection: \(processManager.processLoadError ?? "the process list could not be refreshed").")
                                    return
                                }
                                pendingRecallResult = savedSelections.resolve(
                                    sel,
                                    in: processManager.inventorySnapshot
                                )
                                pendingRecallSelection = sel
                            }
                        }
                        Button("Rename…") {
                            savedSelections.clearValidationError()
                            renameSelectionName = sel.name
                            renameSelection = sel
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            savedSelections.remove(sel)
                        }
                    }
                }
                Divider()
            }
            if !processManager.selectedPids.isEmpty {
                Button("Save Current Selection…") {
                    savedSelections.clearValidationError()
                    saveSelectionName = ""
                    showSaveSelectionSheet = true
                }
            }
        } label: {
            Label("Saved", systemImage: "bookmark")
                .labelStyle(.iconOnly)
        }
        .help("Saved Selections")
        .accessibilityLabel("Saved selections")

        if !processManager.selectedPids.isEmpty {
            Menu {
                Button("Stop Selected…", role: .destructive) {
                    confirmationState.requestBatch(
                        processManager.selectionSnapshot(),
                        mode: .normal
                    )
                }
                Button("Force Stop Selected…", role: .destructive) {
                    confirmationState.requestBatch(
                        processManager.selectionSnapshot(),
                        mode: .force
                    )
                }
            } label: {
                Label("\(processManager.selectedPids.count)", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .accessibilityLabel(
                "Actions for \(processManager.selectedPids.count) selected processes"
            )

            Button {
                processManager.clearSelection()
            } label: {
                Text("Clear")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func firstLoadFailedState(error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Process List Unavailable")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await processManager.loadProcessList() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var noMatchingProcessesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No Matching Processes")
                .font(.headline)
            Text("Adjust the search or filter to show processes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Search & Filter") {
                settings.searchText = ""
                filterMode = .all
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var presetsView: some View {
        PresetsSectionView(
            processManager: processManager,
            loginItemManager: loginItemManager,
            settings: settings,
            watchedApps: watchedApps,
            confirmationState: confirmationState
        )
    }

    private var footer: some View {
        TaskScopeFooterView(
            isWorking: processManager.isWorking,
            message: processManager.message,
            workingMessage: settings.selectedSection == .presets ? processManager.message : nil,
            expandsMessage: settings.selectedSection == .presets,
            summary: footerSummary,
            quitAction: { NSApplication.shared.terminate(nil) }
        )
    }

    private var listQuery: ProcessListQuery {
        ProcessListQuery(
            searchText: settings.searchText,
            filterMode: filterMode,
            watchedScopes: watchedApps.presets.map { WatchedProcessScope(preset: $0) },
            cpuHighlightThreshold: settings.cpuHighlightThreshold,
            memoryHighlightThresholdMB: settings.memHighlightThresholdMB
        )
    }

    /// Memoized by the manager per inventory generation, so the several reads
    /// SwiftUI makes during one body pass compute the list once.
    private var filteredProcesses: [AppProcess] {
        processManager.displayProcesses(for: listQuery)
    }

    private var processCountTitle: String {
        if !processManager.hasLoadedProcessList {
            return "Not loaded"
        }

        let hasSearch = !settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let list = processManager.displayList(for: listQuery)
        let count = list.matchCount
        let shown = list.processes.count
        let noun = hasSearch ? "matches" : "processes"
        return shown < count ? "Showing \(shown) of \(count) \(noun)" : "\(shown) \(noun)"
    }

    private func refreshVisibleSection() {
        Task {
            switch settings.selectedSection {
            case .processes:
                await processManager.loadProcessList()
            case .presets:
                _ = await AppCommandBus.shared.submit(.refresh)
            }
        }
    }

    private func openInActivityMonitor(identity: ProcessIdentity) {
        Task {
            let outcome = await activityMonitor.openAndSelect(identity: identity)
            processManager.setMessage(outcome.message(for: identity.pid))
        }
    }

    private var footerSummary: String? {
        guard processManager.hasLoadedProcessList, !filteredProcesses.isEmpty else { return nil }
        let totalCPU = filteredProcesses.reduce(0.0) { $0 + $1.cpu }
        let totalMem = filteredProcesses.reduce(0.0) { $0 + $1.memoryMB }
        return String(format: "Σ %.1f%% CPU · %.0f MB MEM", totalCPU, totalMem)
    }

    private var treeRoots: [ProcessTreeNode] {
        processManager.treeRoots(for: listQuery)
    }

    private var keyboardNavigationProcesses: [AppProcess] {
        guard treeMode else { return filteredProcesses }
        return visibleTreeProcesses
    }

    /// Select All covers the rows that match the search and filter. Tree mode
    /// also renders ancestors purely for hierarchy context; selecting those
    /// would let a batch stop reach a parent app the user never matched.
    private var selectableProcesses: [AppProcess] {
        guard treeMode else { return filteredProcesses }
        let matchedPIDs = Set(filteredProcesses.map(\.pid))
        return visibleTreeProcesses.filter { matchedPIDs.contains($0.pid) }
    }

    private var visibleTreeProcesses: [AppProcess] {
        ProcessTreeBuilder.visibleProcesses(
            in: treeRoots,
            expandedPIDs: expandedTreePids
        )
    }

    private var terminationConfirmationBinding: Binding<Bool> {
        Binding(
            get: { menuBarConfirmation == nil && confirmationState.pendingTermination != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearTermination()
                }
            }
        )
    }

    private var pendingTerminationBinding: Binding<AppProcess?> {
        Binding(
            get: { confirmationState.pendingTermination?.process },
            set: { process in
                if let process {
                    confirmationState.requestTermination(process)
                } else {
                    confirmationState.clearTermination()
                }
            }
        )
    }

    private var batchConfirmationBinding: Binding<Bool> {
        Binding(
            get: { menuBarConfirmation == nil && confirmationState.pendingBatchTermination != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearBatch()
                }
            }
        )
    }

    private var presetConfirmationBinding: Binding<Bool> {
        Binding(
            get: { menuBarConfirmation == nil && confirmationState.pendingPresetAction != nil },
            set: { isPresented in
                if !isPresented {
                    confirmationState.clearPresetAction()
                }
            }
        )
    }

    private var lifecycleReportBinding: Binding<LifecycleReport?> {
        Binding(
            get: {
                Self.presentedReport(
                    ownsLifecycleReportPresentation ? processManager.lifecycleReport : nil,
                    alreadyShown: shownLifecycleReportID,
                    windowState: controlActiveState
                )
            },
            set: { value in
                if value == nil && ownsLifecycleReportPresentation {
                    processManager.dismissLifecycleReport()
                }
            }
        )
    }

    /// A sheet presented while its window is in the background makes the Dock
    /// icon bounce until the user switches to TaskScope, and GlobalProtect or
    /// the administrator prompt takes focus during every on/off. A new report
    /// waits until its window is in front; one already shown stays up while
    /// the user switches apps.
    static func presentedReport<Report: Identifiable>(
        _ report: Report?,
        alreadyShown shownID: Report.ID?,
        windowState: ControlActiveState
    ) -> Report? {
        guard let report, report.id == shownID || windowState != .inactive else { return nil }
        return report
    }

    private var ownsLifecycleReportPresentation: Bool {
        // Both views share the manager. Once the regular window is visible it
        // owns the report; the menu must not create or dismiss a second sheet.
        isExpandedWindow || !NSApplication.shared.windows.contains {
            $0.isVisible && ($0.title == "TaskScope" || $0.title == "TaskScope Processes")
        }
    }

    private var batchActionReportBinding: Binding<ProcessBatchActionReport?> {
        Binding(
            get: {
                Self.presentedReport(
                    ownsLifecycleReportPresentation ? processManager.batchActionReport : nil,
                    alreadyShown: shownBatchActionReportID,
                    windowState: controlActiveState
                )
            },
            set: { value in
                if value == nil && ownsLifecycleReportPresentation {
                    processManager.dismissBatchActionReport()
                }
            }
        )
    }

    private func expandFilteredTreeAncestors() {
        let isFiltering = !settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filterMode != .all
        guard treeMode, isFiltering else { return }

        func collectParents(_ nodes: [ProcessTreeNode]) {
            for node in nodes {
                if !node.children.isEmpty {
                    expandedTreePids.insert(node.process.pid)
                    collectParents(node.children)
                }
            }
        }
        collectParents(treeRoots)
    }

    @ViewBuilder
    private func processRowView(for process: AppProcess) -> some View {
        ProcessRow(
            process: process,
            isCurrentProcess: processManager.isCurrentProcess(process),
            isSelected: processManager.selectedPids.contains(process.pid),
            isKeyboardSelected: keyboardSelectedPid == process.pid,
            isHighlightedCPU: process.cpu >= settings.cpuHighlightThreshold,
            isHighlightedMEM: process.memoryMB >= settings.memHighlightThresholdMB,
            showsExpandedMetrics: isExpandedWindow,
            stopAction: { confirmationState.requestTermination(process) },
            toggleSelection: { processManager.toggleSelection(process.pid) }
        )
    }

    private func staleProcessListDetail(error: String) -> String {
        let lastUpdated: String
        if let date = processManager.lastSuccessfulInventoryAt {
            lastUpdated = "Last updated \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .standard))."
        } else {
            lastUpdated = "The last successful update time is unavailable."
        }
        return "\(lastUpdated) Refresh failed: \(error) Actions will be revalidated before signaling."
    }

    func requestKeyboardTermination(pid: Int32?) {
        guard let pid,
              let process = keyboardNavigationProcesses.first(where: { $0.pid == pid }),
              !processManager.isCurrentProcess(process) else { return }
        confirmationState.requestTermination(process)
    }

    @ViewBuilder
    func processContextMenu(for process: AppProcess) -> some View {
        Button("Create Auto-Stop Rule...") {
            quickAutoStopProcess = process
        }
        .disabled(processManager.isCurrentProcess(process))
        Button("Watch This Process...") {
            quickPresetDraft = QuickWatchedPresetDraft(processes: [process])
        }
        .disabled(processManager.isCurrentProcess(process))
        if !processManager.selectedPids.isEmpty {
            Button("Save Selection as Preset...") {
                quickPresetDraft = QuickWatchedPresetDraft(processes: selectedProcessesForPreset())
            }
        }
        Divider()
        Button("Stop") { confirmationState.requestTermination(process) }
            .disabled(processManager.isCurrentProcess(process))
        Button("Force Stop") {
            confirmationState.requestTermination(process, mode: .force)
        }
        .disabled(processManager.isCurrentProcess(process))
        Divider()
        Button("Show Detail") {
            detailData = nil
            detailFailed = false
            detailProcess = process
        }
        Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                process.executablePath ?? process.command,
                forType: .string
            )
        }
        Divider()
        Button("Open in Activity Monitor") {
            openInActivityMonitor(identity: process.identity)
        }
    }

    private func presetConfirmationMessage(
        for pending: ProcessConfirmationState.PendingPresetAction
    ) -> String {
        Self.presetConfirmationMessage(for: pending)
    }

    /// Spells out every side effect of a preset action: which launch agents are
    /// unloaded and which processes are signalled. Quit Helpers keeps an agent
    /// loaded when it is the one running the main process.
    static func presetConfirmationMessage(
        for pending: ProcessConfirmationState.PendingPresetAction
    ) -> String {
        let preset = pending.preset
        let names: [String]
        switch pending.action {
        case .quitApp:
            names = [preset.mainProcessName]
        case .quitHelpers:
            names = preset.helperProcessNames
        case .quitAll:
            names = preset.killableNames
        case .keepOff, .stopServices:
            names = preset.killableNames
        }
        let targets = names.isEmpty ? "no configured processes" : names.joined(separator: ", ")
        let agentPreset = preset.hasSupportedGlobalProtectIdentity ? preset.globalProtectInterfaceOnly : preset
        let agentLabels = agentPreset.lifecycleUserLaunchAgentJobs.map(\.label)
        let agentList = agentLabels.joined(separator: ", ")
        let window = Int(ProcessTerminationController.gracefulExitWindowSeconds)
        let forceStopDisclosure = "A process still running \(window) seconds after the stop request is force stopped."

        if pending.action == .stopServices {
            return "GlobalProtect did not complete a normal disconnect. TaskScope will stop and disable its services anyway and keep them off until you choose Open. This can interrupt network access or leave VPN DNS settings behind. If internet access stops working, choose Open to restore the service. Administrator approval may be required. \(forceStopDisclosure)"
        }

        if preset.hasCanonicalGlobalProtectIdentity && (pending.action == .quitAll || pending.action == .keepOff) {
            return "TaskScope will disconnect the VPN, stop GlobalProtect and its services, and keep them off until you choose Open. Accessibility permission lets TaskScope press Disconnect for you; administrator approval is requested only when needed to stop the system service. \(forceStopDisclosure)"
        }

        var sentences: [String] = []
        switch pending.action {
        case .keepOff, .stopServices:
            sentences.append(
                "TaskScope will persistently disable GlobalProtect's per-user launch agents (\(agentList)) and stop current user-facing matches: \(targets)."
            )
            sentences.append("Open restores the required services without reinstalling.")
        case .quitHelpers:
            if !agentLabels.isEmpty {
                sentences.append(
                    "TaskScope will unload the helper launch agents (\(agentList)); an agent that is running the main \(preset.mainProcessName) process is left loaded."
                )
            }
            sentences.append("It will then stop the currently running matches for: \(targets).")
        case .quitApp, .quitAll:
            if !agentLabels.isEmpty {
                sentences.append("TaskScope will unload the user launch agents (\(agentList)).")
            }
            sentences.append("It will then stop the currently running matches for: \(targets).")
        }
        sentences.append(forceStopDisclosure)
        return sentences.joined(separator: " ")
    }

    private func moveKeyboard(by delta: Int, in processes: [AppProcess], proxy: ScrollViewProxy) {
        guard !processes.isEmpty else { return }
        let current = keyboardSelectedPid
        var index = processes.firstIndex(where: { $0.pid == current }) ?? -1
        index = max(0, min(processes.count - 1, index + delta))
        let target = processes[index]
        keyboardSelectedPid = target.pid
        proxy.scrollTo(target.pid, anchor: .center)
    }

    private func selectedProcessesForPreset() -> [AppProcess] {
        // Must come from the full inventory, not the display slice: a row surfaced
        // by the search filter can rank below the display limit, so filtering
        // `processManager.processes` would silently drop it from the draft.
        processManager.selectedProcessesSnapshot()
    }

    private func saveQuickAutoStopRule(
        processName: String,
        runtimeMinutes: Int,
        action: AutoStopRule.Action
    ) -> String? {
        // The sheet was opened in Create or Update mode for the right-clicked
        // process; the save must honour that mode, not re-resolve by the typed
        // name, which could overwrite another process's rule.
        let outcome = QuickAutoStopRuleSaver.save(
            into: autoStopRules,
            processName: processName,
            observedProcessName: quickAutoStopProcess?.name ?? "",
            observedExecutablePath: quickAutoStopProcess?.executablePath,
            runtimeMinutes: runtimeMinutes,
            action: action,
            existingRule: quickAutoStopProcess.flatMap { QuickAutoStopRuleSaver.existingRule(for: $0, in: autoStopRules) }
        )
        if let error = outcome.error {
            return error
        }
        if let status = outcome.statusMessage {
            processManager.setMessage(status)
        }
        quickAutoStopProcess = nil
        return nil
    }

    private func saveQuickWatchedPreset(_ preset: WatchedAppPreset) -> String? {
        guard watchedApps.add(preset) else {
            return watchedApps.validationError
                ?? watchedApps.persistenceIssue
                ?? "TaskScope could not save this watched preset."
        }

        processManager.setMessage("Watching \(preset.displayName).")
        // No refresh here: the app's `.onChange(of: watchedApps.presets)` handler
        // is the single owner of preset-change refreshes. A second one raced it
        // and was either coalesced away or ran first and diffed the new preset's
        // already-running process against a baseline that never contained it.
        quickPresetDraft = nil
        return nil
    }
}
