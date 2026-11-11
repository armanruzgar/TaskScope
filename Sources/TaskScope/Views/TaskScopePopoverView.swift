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
    @StateObject private var listState: ProcessListInteractionState
    @StateObject private var reportState: ProcessReportPresentationState
    private var reportWindowState: ControlActiveState?
    private var mainWindowVisible: @MainActor () -> Bool
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var shownLifecycleReportID: LifecycleReport.ID?
    @State private var shownBatchActionReportID: ProcessBatchActionReport.ID?

    @State private var detailData: ProcessDetail?
    @State private var detailFailed: Bool = false
    @State private var detailFailure: ProcessDetailResult?
    @State private var detailRetry = 0
    @State private var saveSelectionName: String = ""
    @State private var showSaveSelectionSheet: Bool = false
    @State private var renameSelection: SavedSelectionsStore.SavedSelection?
    @State private var renameSelectionName = ""
    @State private var registeredExtendedMetrics = false
    @State private var isOnScreen = false
    @State private var registeredSortMetrics = false
    /// The list must own focus for `.onKeyPress` to receive arrow, Return, and
    /// Escape without Full Keyboard Access; tapping a row moves focus here.
    @FocusState private var processListFocused: Bool
    /// Edit > Find focuses the search field.
    @FocusState private var searchFocused: Bool

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
        listState: ProcessListInteractionState? = nil,
        reportState: ProcessReportPresentationState? = nil,
        reportWindowState: ControlActiveState? = nil,
        mainWindowVisible: @escaping @MainActor () -> Bool = {
            NSApplication.shared.windows.contains { $0.isVisible && $0.title == TaskScopeScene.main.title }
        },
        activityMonitor: (any ActivityMonitorCoordinating)? = nil,
        menuBarConfirmation: (any MenuBarConfirming)? = nil
    ) {
        self.reportWindowState = reportWindowState
        self.mainWindowVisible = mainWindowVisible
        _reportState = StateObject(wrappedValue: reportState ?? ProcessReportPresentationState())
        _listState = StateObject(wrappedValue: listState ?? ProcessListInteractionState())
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
        .focusedSceneValue(\.taskScopeCommands, viewCommands)
    }

    /// The menu-bar commands for this view; each goes through the same path as
    /// the matching control, so a stop from the menu still asks for confirmation.
    private var viewCommands: TaskScopeViewCommands {
        let keyboardProcess = keyboardFocusedProcess
        return TaskScopeViewCommands(
            refresh: { refreshVisibleSection() },
            find: {
                settings.selectedSectionRaw = TaskScopeSection.processes.rawValue
                searchFocused = true
            },
            isTreeMode: listState.treeMode,
            setTreeMode: { listState.treeMode = $0 },
            showSection: { settings.selectedSectionRaw = $0.rawValue },
            hasKeyboardProcess: keyboardProcess != nil,
            showDetail: { showKeyboardDetail() },
            canStop: !processManager.selectedPids.isEmpty
                || keyboardProcess.map { !processManager.isCurrentProcess($0) } == true,
            stop: { mode in
                if !processManager.selectedPids.isEmpty {
                    confirmationState.requestBatch(batchTargets, mode: mode, hiddenCount: hiddenSelectedCount)
                } else if let keyboardProcess, !processManager.isCurrentProcess(keyboardProcess) {
                    confirmationState.requestTermination(keyboardProcess, mode: mode)
                }
            }
        )
    }

    private var observedContent: some View {
        baseContent
        .task { await processManager.beginObservingStatus() }
        .onAppear {
            listState.filterMode = settings.filterMode
            listState.treeMode = settings.treeMode
            isOnScreen = true
            updateSortMetricsRegistration()
            guard isExpandedWindow, !registeredExtendedMetrics else { return }
            registeredExtendedMetrics = true
            history.beginSampling(cadence: settings.refreshIntervalSeconds)
            Task { await processManager.beginExtendedMetrics() }
        }
        .onDisappear {
            processManager.endObservingStatus()
            isOnScreen = false
            updateSortMetricsRegistration()
            guard registeredExtendedMetrics else { return }
            registeredExtendedMetrics = false
            history.endSampling()
            processManager.endExtendedMetrics()
        }
        .onChange(of: settings.sortKeyRaw) { _, _ in
            updateSortMetricsRegistration()
        }
        .onChange(of: processManager.inventoryGeneration) { _, _ in
            // Forget disclosure state for processes that no longer exist; a
            // recycled pid must not inherit an old expansion.
            let livePIDs = Set(processManager.inventorySnapshot.map(\.pid))
            listState.retainLiveFocus(in: processManager.inventorySnapshot)
            listState.expandedTreePids = listState.expandedTreePids.intersection(livePIDs)
            // A match that first appears on a later read must not stay hidden
            // under a collapsed ancestor.
            expandAncestorsOfNewMatches()
        }
        // Only the ancestors of newly displayed matches are expanded, so a node
        // the user collapsed stays collapsed until it gains a new match.
        .onChange(of: settings.searchText) { _, _ in
            expandAncestorsOfNewMatches()
        }
        .onChange(of: listState.filterMode) { _, mode in
            settings.filterModeRaw = mode.rawValue
            expandAncestorsOfNewMatches()
        }
        .onChange(of: listState.treeMode) { _, enabled in
            settings.treeMode = enabled
            if enabled {
                expandAncestorsOfNewMatches()
            }
        }
        // Filter and Tree View are saved, and shared with the window or the
        // menu-bar popover, like Sort.
        .onChange(of: settings.filterModeRaw) { _, _ in
            if listState.filterMode != settings.filterMode { listState.filterMode = settings.filterMode }
        }
        .onChange(of: settings.treeMode) { _, enabled in
            if listState.treeMode != enabled { listState.treeMode = enabled }
        }
        // A persisted search can be active before the first list loads; expand
        // its matches' ancestors once there is a tree to expand.
        .onChange(of: processManager.hasLoadedProcessList) { _, loaded in
            if loaded {
                expandAncestorsOfNewMatches()
            }
        }
        .onChange(of: listState.keyboardSelectedPid) { _, pid in
            let focused = pid.flatMap { pid in
                processManager.inventorySnapshot.first { $0.pid == pid }
            }
            listState.keyboardSelectedIdentity = focused?.identity
            if pid != nil {
                processListFocused = true
            }
            // The highlight is not VoiceOver's cursor; say where it moved.
            if let focused {
                AccessibilityNotification.Announcement("\(focused.name), PID \(String(focused.pid))").post()
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
        // Every captured target is listed, including selected rows that are not
        // on screen; see `BatchStopReviewSheet`.
        .sheet(item: batchReviewBinding) { pending in
            BatchStopReviewSheet(
                pending: pending,
                onConfirm: {
                    guard confirmationState.pendingBatchTermination == pending else { return }
                    confirmationState.clearBatch()
                    stopSelection(pending)
                },
                onCancel: {
                    confirmationState.clearBatch()
                }
            )
        }
    }

    private var presetConfirmationContent: some View {
        terminationConfirmationContent
        .confirmationDialog(
            confirmationState.pendingPresetAction?.title ?? "Confirm Preset Action",
            isPresented: presetConfirmationBinding,
            presenting: confirmationState.pendingPresetAction
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) {
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
                pending.menuBarRequest,
                isCurrent: { $0.pendingBatchTermination == pending },
                clear: { $0.clearBatch() },
                perform: { stopSelection(pending) }
            )
        }
        .onChange(of: confirmationState.pendingPresetAction) { _, pending in
            guard let pending else { return }
            confirmInMenuBar(
                MenuBarConfirmationRequest(title: pending.title, message: presetConfirmationMessage(for: pending), confirmTitle: pending.confirmTitle),
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
        state.run {
            // Leave the view update that queued the request before the alert
            // runs its modal loop.
            await Task.yield()
            guard isCurrent(state) else { return }
            let confirmed = await menuBarConfirmation.confirm(request)
            guard isCurrent(state) else { return }
            clear(state)
            if confirmed { perform() }
        }
    }

    private func stopProcess(_ pending: ProcessConfirmationState.PendingTermination) {
        let process = pending.process
        let forceKill = pending.mode == .force
        let manager = processManager
        confirmationState.run { await manager.terminate(process, forceKill: forceKill) }
    }

    private func stopSelection(_ pending: ProcessConfirmationState.PendingBatchTermination) {
        let targets = pending.targets
        let forceKill = pending.mode == .force
        let manager = processManager
        confirmationState.run { await manager.batchTerminate(targets, forceKill: forceKill) }
    }

    private func runPresetAction(_ pending: ProcessConfirmationState.PendingPresetAction) {
        let preset = pending.preset
        let action = pending.action
        let failureID = pending.disconnectFailureID
        let presentsResult = preset.isBuiltInGlobalProtect
            && (action == .quitAll || action == .keepOff || action == .stopServices)
        let showResult = openFullWindow
        let isExpandedWindow = isExpandedWindow
        let manager = processManager
        confirmationState.run {
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

    /// Saved-selection deletions and discards save at once and have no undo.
    /// The menu-bar window asks outside itself; see `MenuBarConfirming`.
    private var savedSelectionConfirmationContent: some View {
        presetConfirmationContent
        .confirmationDialog(
            Self.selectionDeletionTitle(confirmationState.pendingSelectionDeletion),
            isPresented: selectionDeletionBinding,
            presenting: confirmationState.pendingSelectionDeletion
        ) { selection in
            Button("Delete Selection", role: .destructive) {
                confirmationState.pendingSelectionDeletion = nil
                savedSelections.remove(selection)
            }
            Button("Cancel", role: .cancel) {
                confirmationState.pendingSelectionDeletion = nil
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            Self.selectionsDiscardTitle,
            isPresented: selectionsDiscardBinding
        ) {
            Button("Discard and Reset", role: .destructive) {
                confirmationState.pendingSelectionsDiscard = nil
                savedSelections.resetAfterCorruption()
            }
            Button("Cancel", role: .cancel) {
                confirmationState.pendingSelectionsDiscard = nil
            }
        } message: {
            Text(Self.selectionsDiscardMessage)
        }
        .onChange(of: confirmationState.pendingSelectionDeletion) { _, pending in
            guard let pending else { return }
            let selections = savedSelections
            confirmInMenuBar(
                MenuBarConfirmationRequest(
                    title: Self.selectionDeletionTitle(pending),
                    message: "This cannot be undone.",
                    confirmTitle: "Delete Selection"
                ),
                isCurrent: { $0.pendingSelectionDeletion == pending },
                clear: { $0.pendingSelectionDeletion = nil },
                perform: { _ = selections.remove(pending) }
            )
        }
        .onChange(of: confirmationState.pendingSelectionsDiscard) { _, pending in
            guard let pending else { return }
            let selections = savedSelections
            confirmInMenuBar(
                MenuBarConfirmationRequest(
                    title: Self.selectionsDiscardTitle,
                    message: Self.selectionsDiscardMessage,
                    confirmTitle: "Discard and Reset"
                ),
                isCurrent: { $0.pendingSelectionsDiscard == pending },
                clear: { $0.pendingSelectionsDiscard = nil },
                perform: { selections.resetAfterCorruption() }
            )
        }
    }

    static func selectionDeletionTitle(_ selection: SavedSelectionsStore.SavedSelection?) -> String {
        "Delete the saved selection “\(selection?.name ?? "")”?"
    }

    static let selectionsDiscardTitle = "Discard the unreadable saved selections?"

    static var selectionsDiscardMessage: String {
        RecoveryResetButton.discardWarning(domain: Bundle.main.bundleIdentifier ?? "com.local.TaskScope")
    }

    private var selectionDeletionBinding: Binding<Bool> {
        Binding(
            get: { menuBarConfirmation == nil && confirmationState.pendingSelectionDeletion != nil },
            set: { if !$0 { confirmationState.pendingSelectionDeletion = nil } }
        )
    }

    private var selectionsDiscardBinding: Binding<Bool> {
        Binding(
            get: { menuBarConfirmation == nil && confirmationState.pendingSelectionsDiscard != nil },
            set: { if !$0 { confirmationState.pendingSelectionsDiscard = nil } }
        )
    }

    private var processDetailContent: some View {
        savedSelectionConfirmationContent
        .sheet(item: $confirmationState.detailProcess) { process in
            ProcessDetailSheet(
                process: processManager.inventorySnapshot.first(where: { $0.identity == process.identity }) ?? process,
                detail: detailData,
                failed: detailFailed,
                failure: detailFailure,
                onRetry: { detailRetry += 1 },
                metricsAreLive: processManager.inventorySnapshot.contains(where: { $0.identity == process.identity }),
                onClose: {
                    confirmationState.detailProcess = nil
                    detailData = nil
                    detailFailed = false
                    detailFailure = nil
                }
            )
            .task(id: "\(process.pid)-\(detailRetry)") {
                detailData = nil
                detailFailed = false
                detailFailure = nil
                let result = await processManager.detailResult(for: process)
                // The sheet may have moved to another process, or closed,
                // while the read was in flight.
                guard !Task.isCancelled, confirmationState.detailProcess?.pid == process.pid else { return }
                detailData = result.detail
                detailFailed = result.detail == nil
                detailFailure = result.detail == nil ? result : nil
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
        .sheet(item: $confirmationState.pendingRecallSelection) { selection in
            if let result = confirmationState.pendingRecallResult {
                SavedSelectionRecallSheet(
                    selection: selection,
                    result: result,
                    onApply: {
                        processManager.select(result.matched)
                        confirmationState.pendingRecallSelection = nil
                        confirmationState.pendingRecallResult = nil
                    },
                    onCancel: {
                        confirmationState.pendingRecallSelection = nil
                        confirmationState.pendingRecallResult = nil
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
                onClose: {
                    if processManager.lifecycleReport?.id == report.id { processManager.dismissLifecycleReport() }
                    reportState.dismissLifecycle()
                }
            )
            .onAppear { shownLifecycleReportID = report.id }
        }
        .sheet(
            item: batchActionReportBinding
        ) { report in
            ProcessBatchActionReportSheet(
                report: report,
                onClose: {
                    if processManager.batchActionReport?.id == report.id { processManager.dismissBatchActionReport() }
                    reportState.dismissBatch()
                }
            )
            .onAppear { shownBatchActionReportID = report.id }
        }
    }

    private var quickActionSheetContent: some View {
        reportSheetContent
        .sheet(item: $confirmationState.quickAutoStopProcess, onDismiss: { autoStopRules.clearValidationError() }) { process in
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
                    confirmationState.quickAutoStopProcess = nil
                    autoStopRules.clearValidationError()
                }
            )
        }
        .sheet(item: $confirmationState.quickPresetDraft) { draft in
            QuickWatchedPresetSheet(
                draft: draft,
                onSave: { preset in
                    saveQuickWatchedPreset(preset)
                },
                onCancel: {
                    confirmationState.quickPresetDraft = nil
                }
            )
        }
    }

    private var autoStopAlertContent: some View {
        quickActionSheetContent
        .background {
            // Replace only the alert presenter when the queue head changes.
            // The list and its focus/selection keep their own identity.
            if !autoStopRules.hasAppPromptPresenter {
                if menuBarConfirmation == nil {
                    AutoStopPromptAlert(prompt: autoStopRules.currentPrompt, rules: autoStopRules)
                        .id(autoStopRules.currentPrompt?.id)
                }
            }
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
            historyWindow: history.windowDuration,
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
                    .accessibilityHidden(true)
                    .foregroundStyle(.secondary)

                TextField("Search processes", text: $settings.searchText)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search processes")

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
                .accessibilityElement(children: .contain)
            }

            // Same spacing as `ProcessRow`, so each title sits over its column.
            HStack(spacing: 10) {
                Text(processCountTitle)
                if let updated = processManager.lastSuccessfulInventoryAt,
                   !settings.autoRefreshProcessList {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .help("Time the displayed process snapshot was last refreshed")
                }
                if isExpandedWindow {
                    Spacer()
                    columnHeader("PID", sortKey: .pid)
                        .frame(width: ProcessListColumns.pid, alignment: .trailing)
                    columnHeader("PPID", sortKey: .parentPID)
                        .frame(width: ProcessListColumns.parentPID, alignment: .trailing)
                    columnHeader("USER", sortKey: .user, explanation: "The account that owns the process.")
                        .frame(width: ProcessListColumns.user, alignment: .leading)
                    columnHeader(
                        "NET KB/S", sortKey: .network, detail: "IN / OUT",
                        explanation: Self.networkColumnExplanation
                    )
                    .frame(width: ProcessListColumns.network, alignment: .trailing)
                    columnHeader(
                        "DISK MB/S", sortKey: .disk, detail: "READ / WRITE",
                        explanation: Self.diskColumnExplanation
                    )
                    .frame(width: ProcessListColumns.disk, alignment: .trailing)
                } else {
                    Spacer()
                }
                columnHeader("CPU", sortKey: .cpu)
                    .frame(width: ProcessListColumns.cpu, alignment: .trailing)
                columnHeader("MEM MB", sortKey: .memory)
                    .frame(width: ProcessListColumns.memory, alignment: .trailing)
                Text("")
                    .frame(width: ProcessListColumns.stopButton)
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
                            if listState.treeMode {
                                ForEach(treeRoots, id: \.id) { node in
                                    ProcessTreeRow(
                                        node: node,
                                        depth: 0,
                                        settings: settings,
                                        processManager: processManager,
                                        keyboardSelectedPid: $listState.keyboardSelectedPid,
                                        pendingTermination: pendingTerminationBinding,
                                        expandedPids: $listState.expandedTreePids,
                                        showsExpandedMetrics: isExpandedWindow,
                                        matchedPIDs: Set(filteredProcesses.map(\.pid)),
                                        commandLineMatchPIDs: commandLineMatchPIDs,
                                        requestListFocus: { processListFocused = true },
                                        contextMenuContent: { process in
                                            processContextMenu(for: process)
                                        },
                                        accessibilityActionsContent: { process in
                                            AnyView(processAccessibilityActions(for: process))
                                        }
                                    )
                                }
                            } else {
                                ForEach(filteredProcesses) { process in
                                    processRowView(for: process)
                                        .id(process.pid)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            listState.keyboardSelectedPid = process.pid
                                            processListFocused = true
                                        }
                                        .contextMenu {
                                            processContextMenu(for: process)
                                        }
                                        .accessibilityActions {
                                            processAccessibilityActions(for: process)
                                        }
                                }
                            }
                        }
                        // Flat and tree rows share their PID ids, so without a
                        // separate identity per mode the lazy stack kept the
                        // flat rows on screen after Tree View was turned on:
                        // no indent and no disclosure button.
                        .id(listState.treeMode)
                    }
                    // Edit > Select All (and its Command-A key equivalent) acts like
                    // the Command-A key handler below.
                    .onCommand(#selector(NSResponder.selectAll(_:))) {
                        selectAllVisibleMatches()
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
                    .onKeyPress(.space) {
                        toggleKeyboardSelection()
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        setKeyboardDisclosure(expanded: false)
                        return listState.treeMode ? .handled : .ignored
                    }
                    .onKeyPress(.rightArrow) {
                        setKeyboardDisclosure(expanded: true)
                        return listState.treeMode ? .handled : .ignored
                    }
                    .onKeyPress(.return) {
                        requestKeyboardTermination(pid: listState.keyboardSelectedPid)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        clearKeyboardFocus()
                        return .handled
                    }
                    .onKeyPress { keyPress in
                        // Shift may arrive applied to the character ("A"), and Caps
                        // Lock adds a modifier, so compare case-insensitively and
                        // ignore modifiers that do not change the shortcut.
                        let modifiers = keyPress.modifiers.subtracting([.capsLock, .numericPad])
                        if keyPress.characters.lowercased() == "i", modifiers == .command {
                            showKeyboardDetail()
                            return .handled
                        }
                        guard keyPress.characters.lowercased() == "a" else { return .ignored }
                        if modifiers == .command {
                            selectAllVisibleMatches()
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
        sortMenu

        Picker("Filter", selection: $listState.filterMode) {
            ForEach(ProcessFilterMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()

        Toggle(isOn: $listState.treeMode) {
            Label("Tree", systemImage: "list.bullet.indent")
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .help("Tree View")
        .accessibilityLabel("Tree view")
        .accessibilityValue(listState.treeMode ? "On" : "Off")
    }

    @ViewBuilder
    private var selectionControls: some View {
        Menu {
            if let recoveryMessage = savedSelections.recoveryMessage {
                Text(recoveryMessage)
                if savedSelections.isReadOnlyAfterCorruption {
                    // Saving stays disabled until this is pressed, so without
                    // it the user could never save a selection again. It
                    // promises a backup only when one exists.
                    if savedSelections.isRecoveryBackupPreserved {
                        Button("Reset Saved Selections After Backup") {
                            savedSelections.resetAfterCorruption()
                        }
                    } else {
                        Button("Discard Unreadable Saved Selections and Reset…") {
                            confirmationState.pendingSelectionsDiscard = .init()
                        }
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
                            confirmationState.run {
                                guard await processManager.loadProcessList(showMessage: false) else {
                                    confirmationState.pendingRecallResult = nil
                                    confirmationState.pendingRecallSelection = nil
                                    processManager.setMessage("Could not preview saved selection: \(UIMessage.sentence(processManager.processLoadError ?? "the process list could not be refreshed"))")
                                    return
                                }
                                confirmationState.pendingRecallResult = savedSelections.resolve(
                                    sel,
                                    in: processManager.inventorySnapshot
                                )
                                confirmationState.pendingRecallSelection = sel
                            }
                        }
                        Button("Rename…") {
                            savedSelections.clearValidationError()
                            renameSelectionName = sel.name
                            renameSelection = sel
                        }
                        .disabled(savedSelections.isReadOnlyAfterCorruption)
                        Divider()
                        Button("Delete…", role: .destructive) {
                            confirmationState.pendingSelectionDeletion = sel
                        }
                        .disabled(savedSelections.isReadOnlyAfterCorruption)
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
                .disabled(savedSelections.isReadOnlyAfterCorruption)
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
                        batchTargets,
                        mode: .normal,
                        hiddenCount: hiddenSelectedCount
                    )
                }
                Button("Force Stop Selected…", role: .destructive) {
                    confirmationState.requestBatch(
                        batchTargets,
                        mode: .force,
                        hiddenCount: hiddenSelectedCount
                    )
                }
            } label: {
                Label("\(processManager.selectedPids.count)", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .accessibilityLabel(
                "Actions for \(processManager.selectedPids.count) selected \(processManager.selectedPids.count == 1 ? "process" : "processes")"
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
                    .accessibilityHidden(true)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Process List Unavailable")
                .font(.headline)
            Text(UIMessage.sentence(error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await processManager.loadProcessList() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }

    private var noMatchingProcessesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                    .accessibilityHidden(true)
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
                listState.filterMode = .all
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
            // Progress is shown for actions and explicit refreshes, never for
            // the silent reads polling makes.
            isWorking: processManager.isWorking,
            message: processManager.message,
            workingMessage: settings.selectedSection == .presets ? processManager.message : nil,
            expandsMessage: settings.selectedSection == .presets,
            summary: footerSummary,
            quitDisabled: processManager.isMutationActive,
            quitAction: { NSApplication.shared.terminate(nil) }
        )
    }

    private var listQuery: ProcessListQuery {
        ProcessListQuery(
            searchText: settings.searchText,
            filterMode: listState.filterMode,
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

    /// Displayed rows that match the search only in their command line.
    private var commandLineMatchPIDs: Set<Int32> {
        processManager.displayList(for: listQuery).commandLineMatches
    }

    private var processCountTitle: String {
        if !processManager.hasLoadedProcessList {
            return "Not loaded"
        }

        let hasSearch = !settings.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let list = processManager.displayList(for: listQuery)
        let count = list.matchCount
        let shown = list.processes.count
        let noun = hasSearch ? (count == 1 ? "match" : "matches") : (count == 1 ? "process" : "processes")
        let title = shown < count ? "Showing \(shown) of \(count) \(noun)" : "\(shown) \(noun)"
        guard listState.treeMode else { return title }
        // Tree view hides collapsed children and adds context-only ancestors,
        // so also say how many rows are actually on screen.
        let visible = visibleTreeProcesses.count
        return "\(title), \(visible) \(visible == 1 ? "row" : "rows") visible"
    }

    /// The window reads network and disk counters whenever it is open; the
    /// menu-bar popover, which has no columns for them, reads them only while
    /// it is on screen and sorted by one of them.
    static func needsSortMetrics(isExpandedWindow: Bool, isOnScreen: Bool, sortKey: ProcessSortKey) -> Bool {
        !isExpandedWindow && isOnScreen && sortKey.needsExtendedStats
    }

    private func updateSortMetricsRegistration() {
        let needed = Self.needsSortMetrics(
            isExpandedWindow: isExpandedWindow, isOnScreen: isOnScreen, sortKey: settings.sortKey
        )
        guard needed != registeredSortMetrics else { return }
        registeredSortMetrics = needed
        if needed {
            Task { await processManager.beginExtendedMetrics() }
        } else {
            processManager.endExtendedMetrics()
        }
    }

    /// Sets the window's and the popover's shared sort.
    func setSortOrder(_ order: ProcessSortOrder) {
        settings.setSortOrder(order)
        processManager.sortOrder = order
    }

    /// Sorts by `key` in its default direction.
    func setSortKey(_ key: ProcessSortKey) {
        setSortOrder(ProcessSortOrder(key: key))
    }

    /// A click on a column title: the active column reverses its direction,
    /// and another column starts in its default direction.
    func selectSortColumn(_ key: ProcessSortKey) {
        setSortOrder(settings.sortOrder.selectingColumn(key))
    }

    /// Every key, then both directions, with the current ones checked.
    private var sortMenu: some View {
        let order = settings.sortOrder
        return Menu {
            Picker("Sort By", selection: Binding(
                get: { settings.sortKey },
                set: { key in
                    // Choosing the current key again keeps its direction.
                    guard key != settings.sortKey else { return }
                    setSortKey(key)
                }
            )) {
                ForEach(ProcessSortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(
                get: { settings.sortDirection },
                set: { setSortOrder(ProcessSortOrder(key: settings.sortKey, direction: $0)) }
            )) {
                ForEach(ProcessSortDirection.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: "\(order.key.label) \(order.direction == .descending ? "↓" : "↑")")
        }
        // A fixed frame shared with the visible label truncated the selected
        // key on macOS 26, so the menu sizes itself to its label.
        .fixedSize()
        .help("Sort By")
        .accessibilityLabel("Sort")
        .accessibilityValue("\(order.key.label), \(order.direction.label.lowercased())")
    }

    static let networkColumnExplanation = "Kilobytes per second received / sent, averaged since the previous refresh; "
        + "shown from the second refresh, and only for processes macOS reports network counters for."
    static let diskColumnExplanation = "Megabytes per second read / written, averaged since the previous refresh; "
        + "shown from the second refresh, and only for processes macOS reports disk counters for."

    /// A column title that sorts by its column. The active column shows a
    /// chevron for its direction, and VoiceOver reads the direction as its
    /// value. `detail` is a second line naming the parts of a pair.
    @ViewBuilder
    private func columnHeader(
        _ title: String,
        sortKey: ProcessSortKey,
        detail: String? = nil,
        explanation: String? = nil
    ) -> some View {
        let order = settings.sortOrder
        let isActive = order.key == sortKey
        Button {
            selectSortColumn(sortKey)
        } label: {
            HStack(spacing: 2) {
                if isActive {
                    Image(systemName: order.direction == .descending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .bold))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text(title)
                        .fontWeight(isActive ? .semibold : .regular)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 8))
                    }
                }
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(Self.columnHeaderHelp(for: sortKey, order: order, explanation: explanation))
        .accessibilityValue(isActive ? order.direction.accessibilityValue : "")
        .accessibilityHint(isActive ? "Reverses the sort order" : "Sorts the process list by this column")
    }

    static func columnHeaderHelp(for key: ProcessSortKey, order: ProcessSortOrder, explanation: String? = nil) -> String {
        let action = order.key == key
            ? "Sorted by \(key.label), \(order.direction.label.lowercased()); click to reverse."
            : "Click to sort by \(key.label)."
        return [explanation, action].compactMap { $0 }.joined(separator: " ")
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
        guard settings.selectedSection == .processes, processManager.hasLoadedProcessList, !filteredProcesses.isEmpty else { return nil }
        let totalCPU = filteredProcesses.reduce(0.0) { $0 + $1.cpu }
        let totalMem = filteredProcesses.reduce(0.0) { $0 + $1.memoryMB }
        return String(format: "Σ shown %.1f%% CPU · %.0f MB MEM", totalCPU, totalMem)
    }

    private var treeRoots: [ProcessTreeNode] {
        processManager.treeRoots(for: listQuery)
    }

    private var keyboardNavigationProcesses: [AppProcess] {
        guard listState.treeMode else { return filteredProcesses }
        return visibleTreeProcesses
    }

    /// Select All covers the rows that match the search and filter. Tree mode
    /// also renders ancestors purely for hierarchy context; selecting those
    /// would let a batch stop reach a parent app the user never matched.
    private var selectableProcesses: [AppProcess] {
        ProcessListInteractionState.selectable(matches: filteredProcesses, visible: listState.treeMode ? visibleTreeProcesses : nil)
    }

    private var batchTargets: [ProcessIdentity] {
        let captured = processManager.selectionSnapshot()
        let visible = keyboardNavigationProcesses.map(\.identity).filter { captured.contains($0) }
        return visible + captured.filter { !visible.contains($0) }
    }

    private var hiddenSelectedCount: Int {
        let visible = Set(keyboardNavigationProcesses.map(\.identity))
        return processManager.selectionSnapshot().filter { !visible.contains($0) }.count
    }

    private var visibleTreeProcesses: [AppProcess] {
        ProcessTreeBuilder.visibleProcesses(
            in: treeRoots,
            expandedPIDs: listState.expandedTreePids
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

    private var batchReviewBinding: Binding<ProcessConfirmationState.PendingBatchTermination?> {
        Binding(
            get: { menuBarConfirmation == nil ? confirmationState.pendingBatchTermination : nil },
            set: { value in
                if value == nil {
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
                guard ownsLifecycleReportPresentation else {
                    reportState.forgetUnpresented()
                    return nil
                }
                return reportState.retain(Self.presentedReport(
                    processManager.lifecycleReport,
                    alreadyShown: shownLifecycleReportID,
                    windowState: reportWindowState ?? controlActiveState
                ))
            },
            set: { value in
                guard value == nil, ownsLifecycleReportPresentation else { return }
                // Clear the manager's slot only when it still holds the report
                // that was on screen; a newer one is presented next.
                if reportState.lifecycle == nil || processManager.lifecycleReport?.id == reportState.lifecycle?.id {
                    processManager.dismissLifecycleReport()
                }
                reportState.dismissLifecycle()
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
        isExpandedWindow || !mainWindowVisible()
    }

    private var batchActionReportBinding: Binding<ProcessBatchActionReport?> {
        Binding(
            get: {
                guard ownsLifecycleReportPresentation else {
                    reportState.forgetUnpresented()
                    return nil
                }
                return reportState.retain(Self.presentedReport(
                    processManager.batchActionReport,
                    alreadyShown: shownBatchActionReportID,
                    windowState: reportWindowState ?? controlActiveState
                ))
            },
            set: { value in
                guard value == nil, ownsLifecycleReportPresentation else { return }
                if reportState.batch == nil || processManager.batchActionReport?.id == reportState.batch?.id {
                    processManager.dismissBatchActionReport()
                }
                reportState.dismissBatch()
            }
        )
    }

    private func expandAncestorsOfNewMatches() {
        guard listState.treeMode else { return }
        listState.updateTree(matches: filteredProcesses, roots: treeRoots)
    }

    @ViewBuilder
    private func processRowView(for process: AppProcess) -> some View {
        ProcessRow(
            process: process,
            isCurrentProcess: processManager.isCurrentProcess(process),
            isSelected: processManager.selectedPids.contains(process.pid),
            isKeyboardSelected: listState.keyboardSelectedPid == process.pid,
            isHighlightedCPU: process.cpu >= settings.cpuHighlightThreshold,
            isHighlightedMEM: process.memoryMB >= settings.memHighlightThresholdMB,
            showsExpandedMetrics: isExpandedWindow,
            matchedByCommandLine: commandLineMatchPIDs.contains(process.pid),
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
        return "\(lastUpdated) Refresh failed: \(UIMessage.sentence(error)) Actions will be revalidated before signaling."
    }

    /// The row with keyboard focus, but only while it is still the process
    /// that received focus: a recycled PID must not inherit it.
    private var keyboardFocusedProcess: AppProcess? {
        guard let pid = listState.keyboardSelectedPid,
              let process = keyboardNavigationProcesses.first(where: { $0.pid == pid }),
              listState.keyboardSelectedIdentity == nil || listState.keyboardSelectedIdentity == process.identity
        else { return nil }
        return process
    }

    func requestKeyboardTermination(pid: Int32?) {
        guard let pid,
              let process = keyboardNavigationProcesses.first(where: { $0.pid == pid }),
              !processManager.isCurrentProcess(process) else { return }
        guard listState.keyboardSelectedIdentity == nil || listState.keyboardSelectedIdentity == process.identity else { return }
        confirmationState.requestTermination(process)
    }

    /// Escape clears only the keyboard highlight. The selection is shared by
    /// the window and the popover and may hold rows a search has hidden.
    func clearKeyboardFocus() {
        listState.keyboardSelectedPid = nil
        listState.keyboardSelectedIdentity = nil
    }

    /// Cmd-A adds the displayed matching rows to the selection. Selections a
    /// search or filter has hidden stay selected, as the guide promises, and
    /// tree ancestors shown only for context are never added.
    func selectAllVisibleMatches() {
        processManager.select(processManager.selectedProcessesSnapshot() + selectableProcesses)
    }

    /// Space toggles the selection of the row with keyboard focus.
    func toggleKeyboardSelection() {
        guard let process = keyboardFocusedProcess,
              !processManager.isCurrentProcess(process) else { return }
        processManager.toggleSelection(process.pid)
    }

    func setKeyboardDisclosure(expanded: Bool) {
        guard listState.treeMode, let pid = listState.keyboardSelectedPid else { return }
        if expanded { listState.expandedTreePids.insert(pid) }
        else { listState.expandedTreePids.remove(pid) }
    }

    @ViewBuilder
    func processContextMenu(for process: AppProcess) -> some View {
        Button("Create Auto-Stop Rule…") {
            confirmationState.quickAutoStopProcess = process
        }
        .disabled(processManager.isCurrentProcess(process))
        // Only a current-user app process can become a preset; for anything
        // else the sheet could only end in a validation error.
        let watchUnavailable = processManager.isCurrentProcess(process)
            || QuickWatchedPresetDraft.unavailabilityReason(for: process) != nil
        Button("Watch This Process…") {
            confirmationState.quickPresetDraft = QuickWatchedPresetDraft(processes: [process])
        }
        .disabled(watchUnavailable)
        .help(watchUnavailable
              ? "Only your own apps running from an app bundle's Contents/MacOS folder can be watched."
              : "Watch this app as a preset")
        if !processManager.selectedPids.isEmpty {
            Button("Save Selection as Preset…") {
                confirmationState.quickPresetDraft = QuickWatchedPresetDraft(processes: selectedProcessesForPreset())
            }
        }
        Divider()
        Button("Stop…") { confirmationState.requestTermination(process) }
            .disabled(processManager.isCurrentProcess(process))
        Button("Force Stop…") {
            confirmationState.requestTermination(process, mode: .force)
        }
        .disabled(processManager.isCurrentProcess(process))
        Divider()
        Button("Show Detail") {
            showDetail(for: process)
        }
        Button("Copy Executable Path") {
            copyExecutablePath(of: process)
        }
        Button("Copy Command Line") {
            copyCommandLine(of: process)
        }
        Divider()
        Button("Open in Activity Monitor") {
            openInActivityMonitor(identity: process.identity)
        }
    }

    /// The row actions that otherwise live only in the context menu, for
    /// VoiceOver's Actions rotor. Unavailable actions are left out rather than
    /// offered disabled. Stop is the row's own button.
    @ViewBuilder
    func processAccessibilityActions(for process: AppProcess) -> some View {
        if !processManager.isCurrentProcess(process) {
            Button("Create Auto-Stop Rule…") {
                confirmationState.quickAutoStopProcess = process
            }
            if QuickWatchedPresetDraft.unavailabilityReason(for: process) == nil {
                Button("Watch This Process…") {
                    confirmationState.quickPresetDraft = QuickWatchedPresetDraft(processes: [process])
                }
            }
            Button("Force Stop…") {
                confirmationState.requestTermination(process, mode: .force)
            }
        }
        Button("Show Detail") {
            showDetail(for: process)
        }
        Button("Copy Executable Path") {
            copyExecutablePath(of: process)
        }
        Button("Copy Command Line") {
            copyCommandLine(of: process)
        }
        Button("Open in Activity Monitor") {
            openInActivityMonitor(identity: process.identity)
        }
    }

    func showDetail(for process: AppProcess) {
        detailData = nil
        detailFailed = false
        detailFailure = nil
        confirmationState.detailProcess = process
    }

    /// Cmd-I on the list: Show Detail for the row with keyboard focus.
    func showKeyboardDetail() {
        guard let process = keyboardFocusedProcess else { return }
        showDetail(for: process)
    }

    private func copyExecutablePath(of process: AppProcess) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            process.executablePath ?? process.command,
            forType: .string
        )
    }

    /// Reads the command line only now, on request, and copies it only if the
    /// PID still has the row's identity; otherwise the footer says why.
    func copyCommandLine(
        of process: AppProcess,
        write: @escaping @MainActor (String) -> Void = { ProcessCommandLineCopy.writeToClipboard($0) }
    ) {
        Task {
            let message = await ProcessCommandLineCopy.perform(
                for: process,
                read: { await processManager.commandLine(for: $0) },
                write: write
            )
            processManager.setMessage(message)
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
        let forceStopDisclosure = PresetStopScope.forceStopDisclosure
        let names: [String]
        switch pending.action {
        case .stopServices:
            return "GlobalProtect did not complete a normal disconnect. TaskScope will stop and disable its services anyway and keep them off until you choose Open. This can interrupt network access or leave VPN DNS settings behind. If internet access stops working, choose Open to restore the service. Administrator approval may be required. \(forceStopDisclosure)"
        case .keepOff:
            // Keep Off is offered only for the built-in GlobalProtect preset.
            return globalProtectStopMessage
        case .quitAll where preset.isBuiltInGlobalProtect:
            return globalProtectStopMessage
        case .quitApp:
            names = [preset.mainProcessName]
        case .quitHelpers:
            names = preset.helperProcessNames
        case .quitAll:
            names = preset.killableNames
        }
        let targets = names.isEmpty ? "no configured processes" : names.joined(separator: ", ")
        let agentLabels = PresetStopScope.closeAgentLabels(for: preset)
        let agentList = agentLabels.joined(separator: ", ")

        var sentences: [String] = []
        if !agentLabels.isEmpty {
            sentences.append(pending.action == .quitHelpers
                ? "TaskScope will unload the helper launch agents (\(agentList)); an agent that is running the main \(preset.mainProcessName) process is left loaded."
                : "TaskScope will unload the user launch agents (\(agentList)).")
        }
        sentences.append("\(agentLabels.isEmpty ? "TaskScope will stop" : "It will then stop") the currently running matches for: \(targets).")
        sentences.append(forceStopDisclosure)
        return sentences.joined(separator: " ")
    }

    /// Quit All and Keep Off of the built-in GlobalProtect preset.
    private static var globalProtectStopMessage: String {
        "TaskScope will disconnect the VPN, stop GlobalProtect and its services, and keep them off until you choose Open. Accessibility permission lets TaskScope press Disconnect for you; administrator approval is requested only when needed to stop the system service. \(PresetStopScope.forceStopDisclosure)"
    }

    private func moveKeyboard(by delta: Int, in processes: [AppProcess], proxy: ScrollViewProxy) {
        guard let target = ProcessListInteractionState.nextFocus(current: listState.keyboardSelectedPid, delta: delta, processes: processes) else { return }
        listState.keyboardSelectedPid = target.pid
        proxy.scrollTo(target.pid, anchor: .center)
    }

    func selectedProcessesForPreset() -> [AppProcess] {
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
            observedProcessName: confirmationState.quickAutoStopProcess?.name ?? "",
            observedExecutablePath: confirmationState.quickAutoStopProcess?.executablePath,
            runtimeMinutes: runtimeMinutes,
            action: action,
            existingRule: confirmationState.quickAutoStopProcess.flatMap { QuickAutoStopRuleSaver.existingRule(for: $0, in: autoStopRules) }
        )
        if let error = outcome.error {
            return error
        }
        if let status = outcome.statusMessage {
            processManager.setMessage(status)
        }
        confirmationState.quickAutoStopProcess = nil
        return nil
    }

    func saveQuickWatchedPreset(_ preset: WatchedAppPreset) -> String? {
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
        confirmationState.quickPresetDraft = nil
        return nil
    }
}

extension QuickWatchedPresetDraft {
    /// Why "Watch This Process…" cannot succeed for `process`, or nil when it
    /// can. Watching needs a current-user process with a trusted executable
    /// path inside an app bundle's Contents/MacOS; for anything else the sheet
    /// could only end in a validation error.
    static func unavailabilityReason(for process: AppProcess) -> String? {
        let path = QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: process.name)
        let preset = WatchedAppPreset(
            displayName: process.name,
            mainProcessName: process.name,
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: path
        )
        return QuickWatchedPresetDraft(processes: [process]).validationError(for: preset)
    }
}
