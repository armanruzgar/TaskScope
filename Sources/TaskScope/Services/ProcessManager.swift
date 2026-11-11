import Darwin
import Foundation
import Combine

@MainActor
final class ProcessManager: ObservableObject {
    @Published private(set) var snapshots: [WatchedAppSnapshot] = []
    @Published private(set) var watchedStatusAvailability: WatchedStatusAvailability = .unknown
    @Published private(set) var hasLoadedProcessList = false
    @Published private(set) var hasAttemptedProcessListLoad = false
    @Published private(set) var message: String = "Idle."

    func setMessage(_ text: String) {
        message = text
    }
    var isWorking: Bool {
        operationGate.isWorking
    }

    /// True while a stop, Open, Keep Off or other mutation holds the gate.
    /// Controls that would only queue a second action behind it use this.
    var isMutationActive: Bool { operationGate.isMutationActive }

    /// Test observation of queue admission; UI progress uses `isWorking`.
    var operationState: ProcessOperationState {
        operationGate.state
    }

    @Published var sortKey: ProcessSortKey = .cpu {
        didSet { resortProcesses() }
    }

    @Published private(set) var selectedPids: Set<Int32> = []
    /// Increments whenever the full inventory changes. Views key derived,
    /// memoized lists on it.
    @Published private(set) var inventoryGeneration: UInt64 = 0
    /// Failure of the last read that would have replaced the watched snapshots.
    /// Verification and per-preset reads neither set nor clear it, so the
    /// Presets banner and the Stale/Current labels describe the same read.
    @Published private(set) var watchedStatusLoadError: String?
    @Published private(set) var processLoadError: String?
    /// Failure of the last attempt to replace the displayed process list. Unlike
    /// `processLoadError`, watched-status and per-preset reads never clear it:
    /// only replacing the list does, so the stale-list banner tracks the rows.
    @Published private(set) var processListLoadError: String?
    /// Time the inventory backing the displayed rows was last replaced.
    @Published private(set) var lastSuccessfulInventoryAt: Date?
    /// Time the watched snapshots on screen were last replaced after a read.
    @Published private(set) var lastSuccessfulWatchedReadAt: Date?
    @Published private(set) var lifecycleReport: LifecycleReport?
    /// One explicit failed disconnect may be followed by a separately confirmed
    /// service stop. Never persisted or exposed to URLs. Polling reads it only
    /// to leave GlobalProtect's UI open for the user during the grace period.
    @Published private(set) var globalProtectDisconnectFailureID: UUID?
    @Published private(set) var isGlobalProtectKeepOffPending = false
    /// How long background enforcement leaves GlobalProtect's UI alone after an
    /// explicit disconnect failed and told the user to complete its request.
    static let disconnectFailureGraceSeconds: TimeInterval = 180
    private var globalProtectDisconnectGraceUntil: Date?
    private var pendingGlobalProtectKeepOffCount = 0
    private struct BackgroundKeepOffFailure: Equatable {
        var message: String
        var jobs: [LifecycleJobResult]
    }
    private var backgroundKeepOffFailures: [UUID: BackgroundKeepOffFailure] = [:]
    @Published private(set) var batchActionReport: ProcessBatchActionReport?
    private(set) var lifecycleDiagnostics = LifecycleDiagnosticsHistory()

    func clearLifecycleDiagnostics() {
        lifecycleDiagnostics.clear()
    }

    func dismissLifecycleReport() {
        lifecycleReport = nil
    }

    func dismissBatchActionReport() {
        batchActionReport = nil
    }

    var enableNotifications: Bool = true

    private var pollInterval: TimeInterval = 10
    private var pollProcessList = false
    private var isPollingConfigured = false
    private var backgroundPollingNeeded = true
    private var visibleConsumers = 0

    private let currentPID: Int32
    private let processInventory: any ProcessInventoryProviding
    private let verificationInventory: any ProcessInventoryProviding
    private let processSignaler: any ProcessSignaling
    private let batchTerminator: ProcessBatchTerminator
    private let lifecycle: any ProcessLifecycleServicing
    private let detailReader: any ProcessDetailReading
    private let settleAfterProcessChange: () async -> Void
    private let pollingController: ProcessPollingController
    private weak var processHistory: ProcessHistory?
    private let snapshotBuilder: WatchedSnapshotBuilder
    private let operationGate = ProcessOperationGate()
    private var operationGateCancellable: AnyCancellable?
    private var listProjection = ProcessListProjection()
    private var fullProcessInventory: [AppProcess] {
        get { listProjection.inventory }
        set {
            listProjection = ProcessListProjection(inventory: newValue)
            inventoryGeneration &+= 1
            lastSuccessfulInventoryAt = now()
            processListLoadError = nil
        }
    }
    private var selectedIdentities: [Int32: ProcessIdentity] = [:]
    private var appliedWatchedStatusReads = 0
    private var appliedProcessListReads = 0
    private var appliedExtendedProcessListReads = 0
    private var extendedMetricsConsumers = 0
    private let now: () -> Date
    private var lastInventoryFailure: String?
    private(set) var lastInventoryReadWasCancelled = false

    init(
        processInventory: any ProcessInventoryProviding = SystemProcessInventory(),
        verificationInventory: (any ProcessInventoryProviding)? = nil,
        processSignaler: any ProcessSignaling = DarwinProcessSignaler(),
        lifecycle: any ProcessLifecycleServicing = SystemProcessLifecycleService(),
        settleAfterProcessChange: @escaping () async -> Void = {
            await ProcessLifecycleController.settleAfterProcessChange()
        },
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        pollingController: ProcessPollingController? = nil,
        processHistory: ProcessHistory? = nil,
        detailReader: any ProcessDetailReading = SystemProcessDetailReader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.currentPID = currentPID
        self.processInventory = processInventory
        self.verificationInventory = verificationInventory ?? processInventory
        self.processSignaler = processSignaler
        batchTerminator = ProcessBatchTerminator(
            inventory: verificationInventory ?? processInventory,
            signaler: processSignaler,
            settleAfterProcessChange: settleAfterProcessChange,
            currentPID: currentPID
        )
        self.lifecycle = lifecycle
        self.detailReader = detailReader
        self.settleAfterProcessChange = settleAfterProcessChange
        self.pollingController = pollingController ?? ProcessPollingController()
        self.processHistory = processHistory
        self.now = now
        snapshotBuilder = WatchedSnapshotBuilder(excludedPID: currentPID)
        operationGateCancellable = operationGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Configures the poll. `backgroundActivity` says whether anything needs
    /// the poll while no window or popover shows status: notifications diff its
    /// reads and Keep Off enforcement runs on its ticks. Without it, polling
    /// runs only between `beginObservingStatus` and `endObservingStatus`.
    func setPolling(interval: TimeInterval, includeProcessList: Bool, backgroundActivity: Bool = true) {
        isPollingConfigured = true
        pollInterval = max(2, interval)
        pollProcessList = includeProcessList
        backgroundPollingNeeded = backgroundActivity
        restartPolling()
    }

    private var pollingIsNeeded: Bool {
        isPollingConfigured && (visibleConsumers > 0 || backgroundPollingNeeded)
    }

    /// A window or popover that shows status appeared. Starts polling if
    /// nothing else needed it, and brings status up to date at once, since the
    /// poll may have been off. Pair every call with `endObservingStatus`; like
    /// the extended-metrics count, an early release is allowed to go negative.
    func beginObservingStatus() async {
        let wasNeeded = pollingIsNeeded
        visibleConsumers += 1
        // Until the app configures polling (it never does for startup
        // verification or a rejected duplicate launch), showing status starts
        // no automatic work.
        guard isPollingConfigured else { return }
        if !wasNeeded, pollingIsNeeded { restartPolling() }
        if pollProcessList {
            await loadProcessList(showMessage: false)
        } else {
            await refreshWatchedStatus(showMessage: false)
        }
    }

    func endObservingStatus() {
        let wasNeeded = pollingIsNeeded
        visibleConsumers -= 1
        if wasNeeded, !pollingIsNeeded { restartPolling() }
    }

    /// Stops the poll until `setPolling` configures it again. Quitting stops it
    /// first, so a background Keep Off tick cannot start a new action while an
    /// in-flight one is given time to finish.
    func stopPolling() {
        isPollingConfigured = false
        restartPolling()
    }

    func restartPolling() {
        guard pollingIsNeeded else {
            pollingController.stop()
            // The history runs its own sampler for a visible chart again.
            processHistory?.setPollingActive(false)
            return
        }
        processHistory?.setPollingActive(true)
        pollingController.restart(interval: pollInterval) { [weak self] in
            guard let self else { return }
            // macOS sends no event when the user allows notifications in
            // System Settings. While delivery is impossible, each tick re-reads
            // the authorization before its read, so later transitions are not
            // absorbed until TaskScope is next activated.
            if self.enableNotifications { await self.refreshNotificationAuthorization() }
            // With Auto-refresh on, the list read is the tick's only read: it
            // also applies the watched snapshots, and it performs the first
            // load as well. A watched-only read is the fallback. Each tick's
            // read also feeds the history while a window shows it, so the
            // history runs no read loop of its own while polling.
            var refreshed = false
            if self.pollProcessList {
                refreshed = await self.loadProcessList(showMessage: false, sampleHistory: true)
            }
            if !refreshed {
                refreshed = await self.refreshWatchedStatus(showMessage: false, sampleHistory: true)
            }
            await self.enforceKeptOffPresets(usingFreshSnapshots: refreshed)
        }
    }

    func toggleSelection(_ pid: Int32) {
        guard pid != currentPID,
              let process = fullProcessInventory.first(where: { $0.pid == pid }) else {
            return
        }

        if selectedPids.contains(pid) {
            selectedPids.remove(pid)
            selectedIdentities.removeValue(forKey: pid)
        } else {
            selectedPids.insert(pid)
            selectedIdentities[pid] = process.identity
        }
    }

    func clearSelection() {
        selectedPids.removeAll()
        selectedIdentities.removeAll()
    }

    func select(_ visibleProcesses: [AppProcess]) {
        // Only identities present in the current inventory can be selected; a
        // recalled or stale row whose process exited (or whose PID was reused)
        // must not inflate the selection or mark an unrelated row.
        let liveIdentities = Set(fullProcessInventory.map(\.identity))
        let selectable = visibleProcesses.filter {
            $0.pid != currentPID && liveIdentities.contains($0.identity)
        }
        selectedPids = Set(selectable.map(\.pid))
        selectedIdentities = Dictionary(
            selectable.map { ($0.pid, $0.identity) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func selectionSnapshot() -> [ProcessIdentity] {
        fullProcessInventory.compactMap { selectedIdentities[$0.pid] }
    }

    var inventorySnapshot: [AppProcess] {
        fullProcessInventory
    }

    func displayProcesses(
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        listProjection.displayProcesses(
            sortKey: sortKey,
            limit: processListLimitProvider?() ?? 80,
            matching: predicate
        )
    }

    /// The sorted, filtered, limited list for `query`, memoized per inventory,
    /// sort key, and limit by the projection.
    func displayProcesses(for query: ProcessListQuery) -> [AppProcess] {
        listProjection.displayProcesses(
            for: query, sortKey: sortKey, limit: processListLimitProvider?() ?? 80
        )
    }

    func displayList(for query: ProcessListQuery) -> ProcessListProjection.DisplayList {
        listProjection.displayList(
            for: query, sortKey: sortKey, limit: processListLimitProvider?() ?? 80
        )
    }

    /// Tree roots give every displayed match its ancestor context from the full
    /// inventory, including ancestors outside the display limit.
    func treeRoots(for query: ProcessListQuery) -> [ProcessTreeNode] {
        listProjection.treeRoots(
            for: query, sortKey: sortKey, limit: processListLimitProvider?() ?? 80
        )
    }

    func selectedProcessesSnapshot() -> [AppProcess] {
        fullProcessInventory.filter { selectedIdentities[$0.pid] == $0.identity }
    }

    func batchTerminate(_ requestedIdentities: [ProcessIdentity], forceKill: Bool = false) async {
        guard !requestedIdentities.isEmpty else {
            message = "Nothing selected."
            return
        }

        await runAction(kind: .mutation) {
            let outcome = await batchTerminator.terminate(
                requestedIdentities,
                forceKill: forceKill
            )
            guard !outcome.wasCancelled else { return }
            processLoadError = outcome.inventoryError
            if hasLoadedProcessList, let inventoryError = outcome.inventoryError {
                processListLoadError = inventoryError
            }
            message = outcome.message
            batchActionReport = outcome.report
            if outcome.shouldClearSelection {
                let requested = Set(requestedIdentities)
                selectedIdentities = selectedIdentities.filter { !requested.contains($0.value) }
                selectedPids = Set(selectedIdentities.keys)
            }
            if outcome.shouldRefresh {
                await refreshAfterMutation()
            }
        }
    }

    /// Callers do not need to say whether this refresh should re-baseline
    /// notifications; `apply` detects changed preset detection scopes on its own.
    /// Returns whether a fresh inventory was applied by this call (or by the
    /// equivalent read it joined).
    @discardableResult
    func refreshWatchedStatus(showMessage: Bool = true, sampleHistory: Bool = false) async -> Bool {
        // Counts only watched-status reads that applied snapshots. The general
        // read counter also moves for reads made inside a queued mutation, which
        // would report a refresh that this call never delivered.
        let appliedBefore = appliedWatchedStatusReads
        await runAction(kind: .read(.watchedStatus), reportsProgress: showMessage) {
            switch await currentSnapshots(sampleHistory: sampleHistory) {
            case .success(let watched):
                apply(watched)
                appliedWatchedStatusReads &+= 1
            case .failure(let error):
                recordInventoryFailure(error)
                recordWatchedStatusFailure(error)
            }
        }
        guard !Task.isCancelled, !lastInventoryReadWasCancelled else { return false }
        let refreshed = appliedWatchedStatusReads != appliedBefore
        // An equivalent refresh may have been coalesced with a silent polling
        // refresh. Publish the explicit caller's message after the joined read has
        // completed so automation never returns a stale status string.
        if showMessage {
            if refreshed {
                message = snapshots.aggregateDetail
            } else {
                message = "Could not refresh watched status: \(UIMessage.sentence(lastInventoryFailure ?? "the process list could not be read"))"
            }
        }
        return refreshed
    }

    /// Returns whether a fresh list was applied by this call or the equivalent
    /// read it joined. With `sampleHistory`, a successful read also feeds the
    /// history; a poll tick whose list read fails falls back to a watched read,
    /// which reports to the history instead.
    @discardableResult
    func loadProcessList(showMessage: Bool = true, sampleHistory: Bool = false) async -> Bool {
        let appliedBefore = appliedProcessListReads
        await runAction(kind: .read(.processList), reportsProgress: showMessage) {
            hasAttemptedProcessListLoad = true
            let includesExtendedStats = fetchExtendedStats
            let result = await processInventory.load(fetchExtendedStats: includesExtendedStats)
            if sampleHistory, case .success = result {
                processHistory?.receivePolledInventory(result)
            }
            switch result {
            case .success(let inventory):
                recordInventorySuccess()
                fullProcessInventory = inventory
                apply(snapshots(from: inventory))
                publishDisplayProcesses()
                hasLoadedProcessList = true
                appliedProcessListReads &+= 1
                if includesExtendedStats { appliedExtendedProcessListReads &+= 1 }
            case .failure(let error):
                let failure = Task.isCancelled ? ProcessInventoryError.cancelled : error
                recordInventoryFailure(failure)
                recordProcessListFailure(failure)
                recordWatchedStatusFailure(failure)
            }
        }
        guard !Task.isCancelled, !lastInventoryReadWasCancelled else { return false }
        let refreshed = appliedProcessListReads != appliedBefore
        // An explicit refresh can join a silent active or queued read. Publish
        // its result after the gate returns, even when its closure did not run.
        if showMessage {
            message = refreshed
                ? "Loaded \(displayProcesses().count) of \(fullProcessInventory.count) processes."
                : "Could not load processes: \(UIMessage.sentence(lastInventoryFailure ?? "the process list could not be read"))"
        }
        return refreshed
    }

    /// A preset stored with fields from a newer build may carry a restriction
    /// this build cannot honour, so none of its lifecycle actions run here. The
    /// store's copy is checked too, in case the caller holds a copy without them.
    private func refusalForPresetFromNewerBuild(_ preset: WatchedAppPreset) -> TaskScopeCommandResult? {
        guard preset.hasUnknownFields
            || watchedAppsProvider?().contains(where: { $0.id == preset.id && $0.hasUnknownFields }) == true else {
            return nil
        }
        return TaskScopeCommandResult(status: .rejected, message: WatchedAppsStore.newerBuildMessage)
    }

    @discardableResult
    func openApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if let refusal = refusalForPresetFromNewerBuild(preset) { return refusal }
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Open did not complete."
        )
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            let previousMessage = message
            var cancelledRead = false
            var mayHaveChangedState = false
            if preset.hasCanonicalGlobalProtectIdentity { globalProtectDisconnectFailureID = nil }
            var diagnosticReason: LifecycleDiagnosticFailure.Reason = .incomplete
            var diagnosticJobs: [LifecycleJobResult] = []
            defer {
                if Task.isCancelled || cancelledRead {
                    commandResult = TaskScopeCommandResult(
                        status: .rejected,
                        message: mayHaveChangedState
                            ? "Open for \(preset.displayName) was cancelled; services or the app may already have changed."
                            : "Open for \(preset.displayName) was cancelled."
                    )
                    message = mayHaveChangedState ? commandResult.message : previousMessage
                }
                if commandResult.status == .failed {
                    lifecycleDiagnostics.record(
                        presetID: preset.id, action: .open,
                        backgroundEnforcement: false, reason: diagnosticReason,
                        jobs: diagnosticJobs, at: now()
                    )
                }
            }
            guard lifecycle.appBundleExists(at: preset.appPath) else {
                // Turning Keep Off off (or Open) must still remove the launchd
                // overrides when the app is gone, for example mid-reinstall or
                // before uninstalling, or a reinstalled client cannot start.
                let wasKeptOff = isPresetKeptOffProvider?(preset) ?? false
                if wasKeptOff || preset.hasCanonicalGlobalProtectIdentity {
                    mayHaveChangedState = true
                    let allowed = await clearKeepOffOverrides(preset)
                    diagnosticJobs += allowed.jobs
                    if allowed.result.succeeded {
                        let state = wasKeptOff ? "is no longer kept off" : "is allowed to run"
                        message = "\(preset.displayName) \(state), but its app bundle is missing at \(preset.appPath); nothing was opened."
                        if !LifecycleBatchResult(jobs: allowed.jobs).didChangeState {
                            lifecycleReport = nil
                        }
                    } else {
                        let failure = LifecycleBatchResult(jobs: allowed.jobs).failureSummary ?? "service could not be enabled"
                        message = "Could not allow \(preset.displayName) to run: \(failure). Its app bundle is missing at \(preset.appPath); nothing was opened."
                    }
                } else {
                    message = "Could not open \(preset.displayName): app bundle is missing at \(preset.appPath)."
                }
                diagnosticReason = .appBundleMissing
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let initial = await currentSnapshot(for: preset)
            if case .failure(.cancelled) = initial { cancelledRead = true; return }
            guard !Task.isCancelled else { return }
            guard case .success(let beforeServices) = initial else {
                message = "Could not verify whether \(preset.displayName) is already running; nothing was opened."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            mayHaveChangedState = true
            // Whether the app was running before Open changed anything.
            var mainWasRunning = beforeServices.isMainRunning
            // A UI started directly while PanGPS was stopped can remain stuck
            // retrieving configuration even after the service returns. Restart
            // that orphaned UI before restoration; never unload the VPN job.
            if preset.hasCanonicalGlobalProtectIdentity,
               beforeServices.isMainRunning,
               beforeServices.protectedRunning.isEmpty,
               beforeServices.unprivilegedProtectedRunning.isEmpty {
                let unloadedUI = await lifecycle.unloadUserLaunchAgents(for: preset.globalProtectInterfaceOnly)
                diagnosticJobs += unloadedUI.jobs
                guard unloadedUI.succeeded else {
                    lifecycleReport = LifecycleReport(title: "GlobalProtect UI Recovery", jobs: unloadedUI.jobs)
                    message = "Could not close GlobalProtect's stalled interface. Its VPN service was not stopped."
                    diagnosticReason = .userLaunchAgentFailed
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
                let stoppedUI = await lifecycle.terminateMainProcess(for: preset)
                await lifecycle.settleAfterProcessChange()
                guard [.signalled, .noMatchingProcesses, .targetsExited].contains(stoppedUI),
                      case .success(let afterUIStop) = await currentSnapshot(for: preset),
                      !afterUIStop.isMainRunning else {
                    message = "Could not verify that GlobalProtect's stalled interface closed; no second instance was started."
                    diagnosticReason = .verificationUnavailable
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
                mainWasRunning = false
            }

            let ensuredDaemon = await lifecycle.ensureSystemLaunchDaemons(for: preset)
            diagnosticJobs += ensuredDaemon.jobs
            guard ensuredDaemon.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: ensuredDaemon.jobs
                )
                message = "Could not open \(preset.displayName): \(ensuredDaemon.failureSummary ?? "required service failed")."
                diagnosticReason = .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            // Bootstrap clears the override in the same administrator request.
            // Only a daemon that was already loaded can still need enabling.
            let systemEnable = preset.hasCanonicalGlobalProtectIdentity
                ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
            diagnosticJobs += systemEnable.jobs
            let daemonResult = LifecycleBatchResult(jobs: ensuredDaemon.jobs + systemEnable.jobs)
            guard systemEnable.succeeded else {
                lifecycleReport = LifecycleReport(title: "\(preset.displayName) Service Results", jobs: daemonResult.jobs)
                message = "Could not restore GlobalProtect: \(systemEnable.failureSummary ?? "system service could not be enabled")."
                diagnosticReason = .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            let wasKeptOff = isPresetKeptOffProvider?(preset) ?? false
            let enableResult: LifecycleBatchResult
            // launchd overrides outlive TaskScope preferences (including reset
            // or reinstall). Explicit Open must recover them even without intent.
            if wasKeptOff || preset.hasCanonicalGlobalProtectIdentity {
                enableResult = await lifecycle.enableUserLaunchAgents(for: preset)
                diagnosticJobs += enableResult.jobs
                guard enableResult.succeeded else {
                    lifecycleReport = LifecycleReport(
                        title: "\(preset.displayName) Service Results",
                        jobs: daemonResult.jobs + enableResult.jobs
                    )
                    message = "Could not allow \(preset.displayName) to run: \(enableResult.failureSummary ?? "user launch agent could not be enabled")."
                    diagnosticReason = .userLaunchAgentFailed
                    commandResult = TaskScopeCommandResult(status: .failed, message: message)
                    return
                }
            } else {
                enableResult = .notNeeded
            }

            let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
            diagnosticJobs += agentResult.jobs
            guard agentResult.succeeded else {
                lifecycleReport = LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: daemonResult.jobs + enableResult.jobs + agentResult.jobs
                )
                message = "Could not open \(preset.displayName): \(agentResult.failureSummary ?? "required user job failed")."
                diagnosticReason = .userLaunchAgentFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            if wasKeptOff || preset.hasCanonicalGlobalProtectIdentity {
                setPresetKeptOffHandler?(preset, false)
            }
            let serviceJobs = daemonResult.jobs + enableResult.jobs + agentResult.jobs
            let restored = daemonResult.didChangeState
                || enableResult.didChangeState
                || agentResult.didChangeState
            lifecycleReport = serviceJobs.isEmpty || (preset.hasCanonicalGlobalProtectIdentity && !restored)
                ? nil
                : LifecycleReport(
                    title: "\(preset.displayName) Service Results",
                    jobs: serviceJobs
                )

            // Late failures happen after Keep Off may have been cleared and the
            // services restored, so their messages say what already changed.
            var changes: [String] = []
            if wasKeptOff { changes.append("Keep Off was turned off") }
            if restored { changes.append("required services were restored") }
            let changeText = changes.joined(separator: " and ")
            let changeDetail = changeText.isEmpty
                ? ""
                : changeText.prefix(1).uppercased() + changeText.dropFirst() + ". "

            // Restoring the user launch agents can itself start the main process
            // (GlobalProtect's `pangpa` agent runs the main binary). Re-check with
            // a fresh inventory before opening so a second instance is never
            // launched, and fail closed when that check cannot be made.
            let afterServiceRead = await currentSnapshot(for: preset)
            if case .failure(.cancelled) = afterServiceRead { cancelledRead = true; return }
            guard !Task.isCancelled else { return }
            guard case .success(let afterServices) = afterServiceRead else {
                message = changeDetail + "Could not verify whether \(preset.displayName) started with its services; no app launch was requested."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }
            let alreadyRunning = afterServices.isMainRunning
            // An app that was already running before Open changed anything is
            // brought forward by a plain `open`, which reuses the running
            // instance. One that appeared only after its agents were restored was
            // started by launchd and is not opened again. GlobalProtect's UI is
            // never opened over a running one.
            let activatesRunningApp = alreadyRunning
                && mainWasRunning
                && !preset.hasSupportedGlobalProtectIdentity
            let reportsAlreadyRunning = alreadyRunning
                && mainWasRunning
                && !activatesRunningApp

            let openResult: AppBundleOpenResult = alreadyRunning && !activatesRunningApp
                ? .opened
                : await lifecycle.openAppBundle(at: preset.appPath)
            if case .failed(let detail) = openResult {
                let reason = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
                message = changeDetail + "Could not open \(preset.displayName): \(reason)."
                diagnosticReason = .launchFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
                return
            }

            if !alreadyRunning {
                _ = await lifecycle.waitForMainProcess(
                    for: preset,
                    timeoutSeconds: 5
                )
            }
            guard !Task.isCancelled else { return }
            let finalInventory = await refreshInventoryAfterMutation()
            if finalInventory == nil, lastInventoryReadWasCancelled { cancelledRead = true; return }

            let priorState = alreadyRunning ? "was running" : "was launched"
            if finalInventory == nil {
                message = changeDetail + "\(preset.displayName) \(priorState), but TaskScope could not verify its final state."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            } else if let finalInventory,
                      snapshot(for: preset, inventory: finalInventory).isMainRunning {
                if reportsAlreadyRunning {
                    message = changeDetail + "\(preset.displayName) is already running."
                } else {
                    message = restored
                        ? "Opened \(preset.displayName) after restoring required services."
                        : "Opened \(preset.displayName)."
                }
                commandResult = TaskScopeCommandResult(status: .completed, message: message)
            } else {
                message = changeDetail + "\(preset.displayName) \(priorState), but its main process could not be verified."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: message)
            }
        }
        if !ran {
            return TaskScopeCommandResult(status: .rejected, message: "Open for \(preset.displayName) was cancelled.")
        }
        return commandResult
    }

    /// Persists intent and disables user jobs. An explicit built-in GlobalProtect
    /// action also disables/unloads the fixed system service with authorization;
    /// background enforcement only verifies it and never requests privileges.
    ///
    /// With `recordIntent == false` this is background enforcement. It re-checks
    /// the persisted intent *inside* the operation gate: a poll tick that decided
    /// to enforce can be queued behind a user's Open, which clears the intent, and
    /// running the enforcement afterwards would re-disable the agents the user
    /// just restored and quit the app they just opened.
    @discardableResult
    func keepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool = true
    ) async -> TaskScopeCommandResult {
        await applyKeepOff(preset, recordIntent: recordIntent)
    }

    @discardableResult
    func stopGlobalProtectAfterFailedDisconnect(failureID: UUID) async -> TaskScopeCommandResult {
        await applyKeepOff(.globalProtect, recordIntent: true, confirmedFailureID: failureID)
    }

    private func applyKeepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool,
        confirmedFailureID: UUID? = nil
    ) async -> TaskScopeCommandResult {
        if let refusal = refusalForPresetFromNewerBuild(preset) { return refusal }
        let tracksPendingAction = recordIntent && preset.hasCanonicalGlobalProtectIdentity
        if tracksPendingAction {
            pendingGlobalProtectKeepOffCount += 1
            isGlobalProtectKeepOffPending = true
        }
        defer {
            if tracksPendingAction {
                pendingGlobalProtectKeepOffCount -= 1
                isGlobalProtectKeepOffPending = pendingGlobalProtectKeepOffCount > 0
            }
        }
        var commandResult = TaskScopeCommandResult(
            status: .failed,
            message: "Keep Off did not complete."
        )
        // Background enforcement was not just requested by the user, so the
        // processes it stops are still announced.
        await runAction(kind: .mutation, announcesTransitions: !recordIntent) {
            // Check before disconnect and again afterwards: settings or the
            // preset may change while the vendor UI is settling.
            @MainActor func preparationRefusal() -> String? {
                guard recordIntent else { return nil }
                if isKeepOffIntentWritableProvider?() == false {
                    return "Settings are unreadable. Reset settings in Settings → General before changing Keep Off."
                }
                if preset.hasCanonicalGlobalProtectIdentity,
                   let presets = watchedAppsProvider?(),
                   !presets.contains(where: { $0.id == preset.id && $0.hasCanonicalGlobalProtectIdentity }) {
                    return "The built-in GlobalProtect preset was removed. Keep Off was not recorded and no services were disabled."
                }
                return nil
            }
            if let refusal = preparationRefusal() {
                commandResult = TaskScopeCommandResult(status: .rejected, message: refusal)
                message = refusal
                return
            }
            if let confirmedFailureID {
                guard recordIntent, preset.hasCanonicalGlobalProtectIdentity,
                      confirmedFailureID == globalProtectDisconnectFailureID else {
                    commandResult = TaskScopeCommandResult(status: .rejected, message: "This disconnect failure is no longer current. Choose Keep GlobalProtect Off again.")
                    message = commandResult.message
                    return
                }
            }
            var diagnosticReason: LifecycleDiagnosticFailure.Reason = .incomplete
            var diagnosticJobs: [LifecycleJobResult] = []
            var report: LifecycleReport?
            var shouldPublishReport = false
            defer {
                if !recordIntent && Task.isCancelled {
                    commandResult = TaskScopeCommandResult(status: .rejected, message: "Keep Off enforcement cancelled; it will retry on the next poll.")
                } else {
                    let failure = BackgroundKeepOffFailure(message: commandResult.message, jobs: diagnosticJobs)
                    let isDuplicate = !recordIntent && commandResult.status == .failed
                        && backgroundKeepOffFailures[preset.id] == failure
                    if recordIntent || commandResult.status == .completed {
                        backgroundKeepOffFailures[preset.id] = nil
                    } else if commandResult.status == .failed {
                        backgroundKeepOffFailures[preset.id] = failure
                    }
                    if !isDuplicate {
                        if commandResult.status != .rejected { message = commandResult.message }
                        if shouldPublishReport { lifecycleReport = report }
                        if commandResult.status == .failed {
                            lifecycleDiagnostics.record(
                                presetID: preset.id, action: .keepOff,
                                backgroundEnforcement: !recordIntent, reason: diagnosticReason,
                                jobs: diagnosticJobs, at: now()
                            )
                        }
                    }
                }
            }
            guard recordIntent || !Task.isCancelled else { return }
            if !recordIntent, isPresetKeptOffProvider?(preset) != true {
                commandResult = TaskScopeCommandResult(
                    status: .rejected,
                    message: "Keep Off is no longer enabled for \(preset.displayName); enforcement skipped."
                )
                return
            }

            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                globalProtectDisconnectFailureID = nil
                if confirmedFailureID == nil {
                    message = "Disconnecting GlobalProtect before stopping its services…"
                    if case .failed(let detail) = await lifecycle.disconnectGlobalProtectIfNeeded() {
                        globalProtectDisconnectFailureID = UUID()
                        globalProtectDisconnectGraceUntil = now().addingTimeInterval(Self.disconnectFailureGraceSeconds)
                        message = detail
                        diagnosticReason = .disconnectFailed
                        commandResult = TaskScopeCommandResult(status: .failed, message: detail)
                        return
                    }
                }
            }
            if let refusal = preparationRefusal() {
                commandResult = TaskScopeCommandResult(status: .rejected, message: refusal)
                message = refusal
                return
            }
            // Record after a clean disconnect or separately confirmed recovery,
            // while holding the gate so polling cannot race the preparation.
            if recordIntent {
                setPresetKeptOffHandler?(preset, true)
            }
            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                message = "Stopping GlobalProtect and its services…"
            }

            let inventoryWasAvailable: Bool
            switch await currentSnapshot(for: preset) {
            case .success:
                inventoryWasAvailable = true
            case .failure:
                inventoryWasAvailable = false
            }
            guard recordIntent || !Task.isCancelled else { return }
            let userDisable = await lifecycle.disableUserLaunchAgents(for: preset, preservingVPNService: !recordIntent)
            guard recordIntent || !Task.isCancelled else { return }
            let systemDisable = preset.hasCanonicalGlobalProtectIdentity
                ? await lifecycle.disableSystemLaunchDaemons(for: preset, allowAdministratorPrompt: recordIntent)
                : .notNeeded
            guard recordIntent || !Task.isCancelled else { return }
            let disableResult = LifecycleBatchResult(jobs: userDisable.jobs + systemDisable.jobs)
            diagnosticJobs += disableResult.jobs
            // Background enforcement runs on every launch and poll tick; only a
            // failure is worth interrupting the user with a report sheet.
            if recordIntent || !disableResult.succeeded {
                shouldPublishReport = true
                report = disableResult.jobs.isEmpty
                    ? nil
                    : LifecycleReport(
                        title: "\(preset.displayName) Keep Off",
                        jobs: disableResult.jobs
                    )
            }

            var resultMessage = message
            guard inventoryWasAvailable else {
                resultMessage = disableResult.succeeded
                    ? "Keep Off disabled relaunch jobs, but the process list was unavailable; running processes were not signalled and enforcement will retry."
                    : "Keep Off remains enabled, but TaskScope could neither verify processes nor disable relaunch jobs."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
                return
            }

            let terminationOutcomes = await terminateProcesses(for: preset, scope: .all)
            if recordIntent && preset.hasCanonicalGlobalProtectIdentity {
                self.message = "Verifying GlobalProtect is off…"
            }
            await lifecycle.settleAfterProcessChange()
            let finalInventory = await refreshInventoryAfterMutation()
            guard recordIntent || !Task.isCancelled else { return }
            let nowSnapshot = snapshot(for: preset, inventory: finalInventory ?? [])
            let serviceObservation = preset.hasCanonicalGlobalProtectIdentity
                ? await globalProtectServiceObservationProvider?() : nil
            guard recordIntent || !Task.isCancelled else { return }

            if !disableResult.succeeded {
                resultMessage = "Keep Off was requested, but stopping services failed: \(disableResult.failureSummary ?? "unknown failure")."
                diagnosticReason = systemDisable.succeeded ? .userLaunchAgentFailed : .systemServiceFailed
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if terminationOutcomes.contains(.inventoryUnavailable) {
                resultMessage = "Keep Off disabled relaunch jobs, but the process list became unavailable before app processes could be stopped."
                diagnosticReason = .inventoryUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if terminationOutcomes.contains(.signalRejected) {
                resultMessage = "Keep Off disabled relaunch jobs, but a running process rejected the stop signal."
                diagnosticReason = .signalRejected
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if terminationOutcomes.contains(.escalationUnavailable) || finalInventory == nil
                || serviceObservation?.session == .unknown || serviceObservation?.system == .unknown {
                resultMessage = "Keep Off is enabled, but TaskScope could not verify the final process state."
                diagnosticReason = .verificationUnavailable
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if preset.hasCanonicalGlobalProtectIdentity
                && (serviceObservation?.system == .running
                    || (serviceObservation == nil && !nowSnapshot.protectedRunning.isEmpty)) {
                resultMessage = "Keep Off was requested, but a privileged VPN service is still running. Check the service report and your organization's policy before retrying."
                diagnosticReason = .stillRunning
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if recordIntent && serviceObservation?.session == .running {
                resultMessage = "Keep Off was requested, but the login-session VPN service is still running. Choose Apply Keep Off to retry the session stop."
                diagnosticReason = .stillRunning
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else if nowSnapshot.hasBackgroundKeepOffTargets
                || (recordIntent && serviceObservation == nil && nowSnapshot.hasCurrentUserLaunchAgent) {
                resultMessage = "Keep Off is enabled, but user-facing GlobalProtect processes may still run."
                diagnosticReason = .stillRunning
                commandResult = TaskScopeCommandResult(status: .failed, message: resultMessage)
            } else {
                if preset.hasCanonicalGlobalProtectIdentity && !recordIntent
                    && (serviceObservation?.session == .running
                        || (serviceObservation == nil && nowSnapshot.hasCurrentUserLaunchAgent)) {
                    resultMessage = "Keep Off disabled relaunch jobs. The running login-session VPN service was preserved; choose Apply Keep Off for a confirmed disconnect and stop."
                } else if preset.hasCanonicalGlobalProtectIdentity {
                    resultMessage = "GlobalProtect is off. Its user agents are disabled; the system VPN service is disabled or not installed. Choose Open to restore them without reinstalling."
                } else if !nowSnapshot.protectedRunning.isEmpty {
                    resultMessage = "\(preset.displayName) app is kept off. Protected system service remains available."
                } else if !nowSnapshot.unprivilegedProtectedRunning.isEmpty {
                    let names = nowSnapshot.unprivilegedProtectedRunning.joined(separator: ", ")
                    resultMessage = "\(preset.displayName) is kept off. Its user launch agents are disabled; a per-user \(names) instance is still running and should exit as launchd finishes unloading it."
                } else {
                    resultMessage = "\(preset.displayName) is kept off. Its user launch agents are disabled."
                }
                commandResult = TaskScopeCommandResult(status: .completed, message: resultMessage)
            }
        }
        if !recordIntent && Task.isCancelled {
            return TaskScopeCommandResult(status: .rejected, message: "Keep Off enforcement cancelled; it will retry on the next poll.")
        }
        return commandResult
    }

    private func clearKeepOffOverrides(
        _ preset: WatchedAppPreset
    ) async -> (result: TaskScopeCommandResult, jobs: [LifecycleJobResult]) {
        let systemEnable = preset.hasCanonicalGlobalProtectIdentity
            ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
        // Do not start restoring user jobs after a cancelled system request.
        let userEnable = systemEnable.succeeded
            ? await lifecycle.enableUserLaunchAgents(for: preset) : .notNeeded
        let enableResult = LifecycleBatchResult(jobs: systemEnable.jobs + userEnable.jobs)
        // Show the report only when something changed or failed; verified,
        // already-enabled jobs are not a restoration.
        lifecycleReport = enableResult.didChangeState || !enableResult.succeeded
            ? LifecycleReport(
                title: "\(preset.displayName) Keep Off",
                jobs: enableResult.jobs
            )
            : nil
        guard enableResult.succeeded else {
            let failure = enableResult.failureSummary ?? "service could not be enabled"
            message = isPresetKeptOffProvider?(preset) == true
                ? "Keep Off remains requested: \(failure)."
                : "Could not allow \(preset.displayName) to run: \(failure)."
            return (
                TaskScopeCommandResult(status: .failed, message: message),
                enableResult.jobs
            )
        }
        setPresetKeptOffHandler?(preset, false)
        message = "\(preset.displayName) is allowed to run. Nothing was started."
        return (TaskScopeCommandResult(status: .completed, message: message), enableResult.jobs)
    }

    /// Enforces persisted Keep Off intent after startup and if a user-facing job
    /// is restored externally. The system disable override persists in launchd;
    /// polling never requests authorization or repeatedly fights a restored system
    /// service. Its running state stays visible with an explicit retry action.
    ///
    /// Enforcement never queues behind a user-initiated mutation: while one runs
    /// the user is changing exactly the state enforcement would act on, and the
    /// gated re-check inside `keepOff` is the last line of defence for a tick
    /// that had already decided before the mutation started.
    ///
    /// A tick that has just applied fresh snapshots passes `usingFreshSnapshots`,
    /// so deciding whether enforcement is needed costs no second read. `keepOff`
    /// still reads uncached inside the gate before it disables or signals.
    func enforceKeptOffPresets(force: Bool = false, usingFreshSnapshots: Bool = false) async {
        for preset in keptOffPresetsProvider?() ?? [] {
            guard !operationGate.isMutationActive else { continue }
            // A failed explicit disconnect sent the user to GlobalProtect to
            // answer its request, and enforcement would close that UI. Leave it
            // for a bounded time, or until the next explicit action clears the
            // failure.
            if preset.hasCanonicalGlobalProtectIdentity,
               globalProtectDisconnectFailureID != nil,
               let graceUntil = globalProtectDisconnectGraceUntil,
               now() < graceUntil {
                continue
            }
            if !force {
                let current: WatchedAppSnapshot
                if usingFreshSnapshots, let fresh = snapshots.first(where: { $0.preset == preset }) {
                    current = fresh
                } else {
                    guard case .success(let fresh) = await currentSnapshot(for: preset) else { continue }
                    current = fresh
                }
                guard current.hasBackgroundKeepOffTargets else {
                    backgroundKeepOffFailures[preset.id] = nil
                    continue
                }
            }
            _ = await keepOff(preset, recordIntent: false)
        }
    }

    @discardableResult
    func quitMainApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .app)
    }

    @discardableResult
    func quitHelpers(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .helpers)
    }

    @discardableResult
    func quitAll(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if preset.hasCanonicalGlobalProtectIdentity {
            return await keepOff(preset)
        }
        return await quitAllKillable(preset)
    }

    /// Shortcuts Stop retains its user-process scope; URLs accept refresh only.
    /// The full VPN stop is requested by the explicitly confirmed in-app action.
    @discardableResult
    func quitAllKillable(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await stop(preset, scope: .all)
    }

    private func stop(_ preset: WatchedAppPreset, scope: PresetStopScope) async -> TaskScopeCommandResult {
        if let refusal = refusalForPresetFromNewerBuild(preset) { return refusal }
        var result = PresetStopResult.failed(scope.incompleteMessage, reason: .incomplete)
        var cancelled = false
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            // Admission is the cancellation boundary for Stop. Once admitted,
            // finish all scoped stops and verification even if its caller leaves.
            await Task { @MainActor in
                var diagnosticJobs: [LifecycleJobResult] = []
                defer {
                    if !cancelled { message = result.message }
                    if !cancelled, let reason = result.failureReason {
                        lifecycleDiagnostics.record(
                            presetID: preset.id, action: scope.diagnosticAction,
                            backgroundEnforcement: false, reason: reason,
                            jobs: diagnosticJobs, at: now()
                        )
                    }
                }
                let initial = await currentSnapshot(for: preset)
                if case .failure(.cancelled) = initial {
                    cancelled = true
                    return
                }
                guard case .success(let before) = initial else {
                    result = scope.inventoryFailure(for: preset)
                    return
                }
                // These scopes never disconnect the VPN, so for GlobalProtect they
                // leave its session VPN service loaded; Keep Off/Quit All stops it
                // only after a verified disconnect.
                let agentPreset = preset.hasSupportedGlobalProtectIdentity
                    ? preset.globalProtectInterfaceOnly
                    : preset
                let agents: LifecycleBatchResult
                if scope == .helpers {
                    // Unloading an agent running the main binary would also quit the app.
                    agents = await lifecycle.unloadUserLaunchAgents(
                        for: agentPreset, preservingPIDs: before.mainProcessPIDs
                    )
                } else {
                    agents = await lifecycle.unloadUserLaunchAgents(for: agentPreset)
                }
                diagnosticJobs = agents.jobs
                lifecycleReport = agents.jobs.isEmpty
                    ? nil
                    : LifecycleReport(title: "\(preset.displayName) Relaunch Jobs", jobs: agents.jobs)
                let terminations = await terminateProcesses(for: preset, scope: scope)
                await lifecycle.settleAfterProcessChange()
                let finalInventory = await refreshInventoryAfterMutation()
                result = scope.result(
                    before: before, after: snapshot(for: preset, inventory: finalInventory ?? []),
                    terminations: terminations, agents: agents, refreshed: finalInventory != nil
                )
            }.value
        }
        if !ran || cancelled {
            return TaskScopeCommandResult(status: .rejected, message: "Stop for \(preset.displayName) was cancelled.")
        }
        return result.commandResult
    }

    private func terminateProcesses(
        for preset: WatchedAppPreset,
        scope: PresetStopScope
    ) async -> [ProcessTerminationOutcome] {
        await lifecycle.terminateProcesses(for: preset, scope: scope)
    }

    @discardableResult
    func terminate(
        _ process: AppProcess,
        forceKill: Bool = false,
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async -> ProcessActionResult {
        guard process.pid != currentPID else {
            message = "Use Quit to close TaskScope."
            return .refused
        }
        guard ProcessSignalGuard.isSignalablePID(process.pid) else {
            message = "PID \(process.pid) can never be signalled."
            return .refused
        }

        var result: ProcessActionResult = .rejected
        await runAction(kind: .mutation) {
            let verificationResult = await verificationInventory.load(fetchExtendedStats: false)
            // An unreadable process list says nothing about this target. Treating it
            // as an identity change both lied to the user and wiped the whole
            // selection by reconciling against an empty inventory.
            if Task.isCancelled || verificationResult == .failure(.cancelled) {
                message = "Stop for \(process.name) was cancelled."
                return
            }
            guard case .success(let currentProcesses) = verificationResult else {
                if case .failure(let error) = verificationResult {
                    recordInventoryFailure(error)
                }
                message = "Could not verify \(process.name); nothing was stopped."
                result = .rejected
                return
            }
            recordInventorySuccess()
            guard currentProcesses.contains(where: { !$0.hasExited && $0.identity == process.identity }) else {
                let identityChanged = currentProcesses.contains { $0.pid == process.pid && !$0.hasExited }
                message = identityChanged
                    ? "\(process.name)'s identity changed; nothing was stopped."
                    : "\(process.name) is no longer running."
                result = identityChanged ? .identityChanged : .stale
                apply(snapshots(from: currentProcesses))
                if hasLoadedProcessList {
                    // Verification reads no Net/Disk figures, so keep the last
                    // observed ones for every row whose identity is unchanged.
                    let previous = Dictionary(
                        fullProcessInventory.map { ($0.identity, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    fullProcessInventory = currentProcesses.map { process in
                        var row = process
                        if let old = previous[row.identity] {
                            row.netInKB = old.netInKB
                            row.netOutKB = old.netOutKB
                            row.diskReadBytes = old.diskReadBytes
                            row.diskWriteBytes = old.diskWriteBytes
                        }
                        return row
                    }
                    publishDisplayProcesses()
                } else {
                    reconcileSelection(with: currentProcesses)
                }
                return
            }

            // Auto-stop rules can be disabled or deleted while this mutation is
            // queued or while identity verification is suspended. This is the
            // final authority check: no await may occur between it and kill(2).
            guard !Task.isCancelled, isAuthorized() else {
                message = "Stop for \(process.name) was cancelled."
                result = .rejected
                return
            }

            let signal: Int32 = forceKill ? SIGKILL : SIGTERM
            let delivery = processSignaler.deliver(signal, to: process.pid)
            if delivery == .delivered, !forceKill {
                await ProcessBatchTerminator.waitForExit(
                    of: [process.pid],
                    signaler: processSignaler,
                    settle: settleAfterProcessChange
                )
            } else {
                await settleAfterProcessChange()
            }

            switch delivery {
            case .rejected(let code):
                let detail = ProcessSignalGuard.refusalDetail(
                    for: process, currentPID: currentPID, currentUID: getuid(), errno: code
                )
                message = "Could not send \(forceKill ? "force stop" : "stop") to \(process.name). \(detail)"
                result = .refused
            case .noSuchProcess:
                // It exited between the identity check and the signal; the
                // requested outcome holds.
                message = "\(process.name) had already exited."
                result = .stopped
            case .delivered:
                if !processSignaler.isAlive(process.pid) {
                    message = forceKill ? "\(process.name) force stopped." : "\(process.name) stopped."
                    result = .stopped
                } else if forceKill {
                    message = "\(process.name) is still running after Force Stop."
                    result = .requestedStillRunning
                } else {
                    message = "Stop requested for \(process.name); it is still running."
                    result = .requestedStillRunning
                }
            }

            await refreshAfterMutation()
        }
        return result
    }

    func detailResult(for process: AppProcess) async -> ProcessDetailResult {
        await detailReader.readResult(for: process)
    }

    func detail(for process: AppProcess) async -> ProcessDetail? {
        await detailReader.readDetail(for: process)
    }

    func isCurrentProcess(_ process: AppProcess) -> Bool {
        process.pid == currentPID
    }

    /// Test observation of the projection used by `treeRoots(for:)`.
    var ppidMap: [Int32: Int32] {
        listProjection.ppidMap
    }

    @discardableResult
    private func refreshAfterMutation() async -> Bool {
        await refreshInventoryAfterMutation() != nil
    }

    private func refreshInventoryAfterMutation() async -> [AppProcess]? {
        switch await verificationInventory.load(fetchExtendedStats: hasLoadedProcessList && fetchExtendedStats) {
        case .success(let inventory):
            recordInventorySuccess()
            apply(snapshots(from: inventory))
            if hasLoadedProcessList {
                fullProcessInventory = inventory
                publishDisplayProcesses()
            }
            return inventory
        case .failure(let error):
            recordInventoryFailure(error)
            recordWatchedStatusFailure(error)
            if hasLoadedProcessList { recordProcessListFailure(error) }
            return nil
        }
    }

    private func currentSnapshots(
        sampleHistory: Bool = false
    ) async -> Result<[WatchedAppSnapshot], ProcessInventoryError> {
        let result = await processInventory.load(fetchExtendedStats: false)
        if sampleHistory { processHistory?.receivePolledInventory(result) }
        switch result {
        case .success(let inventory):
            recordInventorySuccess()
            return .success(snapshots(from: inventory))
        case .failure(let error):
            recordInventoryFailure(error)
            return .failure(error)
        }
    }

    private func currentSnapshot(
        for preset: WatchedAppPreset
    ) async -> Result<WatchedAppSnapshot, ProcessInventoryError> {
        switch await verificationInventory.load(fetchExtendedStats: false) {
        case .success(let inventory):
            recordInventorySuccess()
            return .success(snapshot(for: preset, inventory: inventory))
        case .failure(let error):
            recordInventoryFailure(error)
            return .failure(error)
        }
    }

    private func recordInventorySuccess() {
        processLoadError = nil
        lastInventoryReadWasCancelled = false
        lastInventoryFailure = nil
    }

    /// A cancelled read (a poll restart, a torn-down view) says nothing about
    /// the inventory and never becomes the persistent "stale list" error.
    private func recordInventoryFailure(_ error: ProcessInventoryError) {
        let failure = Task.isCancelled ? ProcessInventoryError.cancelled : error
        lastInventoryFailure = failure.localizedDescription
        lastInventoryReadWasCancelled = failure == .cancelled
        guard failure != .cancelled else { return }
        processLoadError = failure.localizedDescription
    }

    private func recordWatchedStatusFailure(_ error: ProcessInventoryError) {
        guard !Task.isCancelled, error != .cancelled else { return }
        watchedStatusLoadError = error.localizedDescription
        if watchedStatusAvailability != .unknown { watchedStatusAvailability = .stale }
    }

    /// Records a failed attempt to replace the displayed list. Called after
    /// `recordInventoryFailure`, so a cancelled read is already classified.
    private func recordProcessListFailure(_ error: ProcessInventoryError) {
        let failure = Task.isCancelled ? ProcessInventoryError.cancelled : error
        guard failure != .cancelled else { return }
        processListLoadError = failure.localizedDescription
    }

    private func snapshots(from inventory: [AppProcess]) -> [WatchedAppSnapshot] {
        let presets = watchedAppsProvider?() ?? []
        return snapshotBuilder.snapshots(for: presets, in: inventory)
    }

    private func snapshot(
        for preset: WatchedAppPreset,
        inventory: [AppProcess]
    ) -> WatchedAppSnapshot {
        snapshotBuilder.snapshot(for: preset, in: inventory)
    }

    func applyCurrentDisplayLimit() {
        guard hasLoadedProcessList else { return }
        publishDisplayProcesses()
    }

    @Published private(set) var fetchExtendedStats: Bool = false

    func beginExtendedMetrics() async {
        extendedMetricsConsumers += 1
        guard extendedMetricsConsumers == 1 else { return }
        fetchExtendedStats = true
        if hasLoadedProcessList {
            // Joining a basic list read already in flight would leave the
            // extended columns empty until a later refresh, so read once more.
            let appliedBefore = appliedExtendedProcessListReads
            await loadProcessList(showMessage: false)
            if appliedExtendedProcessListReads == appliedBefore, fetchExtendedStats {
                await loadProcessList(showMessage: false)
            }
        }
    }

    func endExtendedMetrics() {
        // Deliberately not clamped at zero. `beginExtendedMetrics` is async, so a
        // consumer's release can land before its own acquire; clamping swallowed the
        // early release and the late acquire then latched collection on with no
        // consumer left to turn it off — an un-stoppable nettop/ps fork per poll for
        // the life of the process. Letting the count go negative lets the late
        // acquire cancel out instead, which fails closed rather than open.
        extendedMetricsConsumers -= 1
        if extendedMetricsConsumers <= 0 {
            fetchExtendedStats = false
        }
    }

    /// The selection is reconciled against the *full* inventory, not the top-N
    /// display slice: a process selected through search can rank below the
    /// display limit and must survive a poll or a sort change. Exited or
    /// recycled PIDs are still pruned because their identity is gone.
    private func publishDisplayProcesses() {
        reconcileSelection(with: fullProcessInventory)
    }

    private func resortProcesses() {
        guard hasLoadedProcessList else { return }
        publishDisplayProcesses()
    }

    private func reconcileSelection(with inventory: [AppProcess]) {
        guard !selectedIdentities.isEmpty else { return }
        let currentIdentities = Set(inventory.map(\.identity))
        selectedIdentities = selectedIdentities.filter { currentIdentities.contains($0.value) }
        selectedPids = Set(selectedIdentities.keys)
    }

    /// Running names as notifications show them. Presets may share a process
    /// name (two Java apps both run JavaApplicationStub); such a name carries
    /// the preset's display name so the two stay apart. Diffing itself is per
    /// preset (see NotificationService), so one app quitting while the other
    /// runs is still announced.
    nonisolated static func notificationNames(for snapshots: [WatchedAppSnapshot]) -> Set<String> {
        let shared = NotificationService.sharedProcessNames(among: snapshots.map(\.preset))
        return Set(snapshots.flatMap { snapshot in
            snapshot.runningNames.map {
                NotificationService.displayName(for: $0, in: snapshot.preset, sharedNames: shared)
            }
        })
    }

    /// Seams over the notification singleton so the baseline/diff ordering is
    /// testable; all default to `NotificationService.shared`. Both baseline
    /// seams receive the snapshots of presets with notifications enabled.
    var notifyTransitions: ([WatchedAppSnapshot]) -> Void = {
        NotificationService.shared.diffAndNotify($0)
    }
    var primeNotificationBaseline: ([WatchedAppSnapshot]) -> Void = {
        NotificationService.shared.prime($0)
    }
    var refreshNotificationAuthorization: () async -> Void = {
        await NotificationService.shared.refreshAuthorizationIfUndeliverable()
    }
    /// Set while Open, Quit or an explicit Keep Off runs. The user just asked
    /// for those transitions and sees the action's result, so the reads inside
    /// the action re-baseline instead of announcing them.
    private var isApplyingOwnLifecycleAction = false

    /// The presets define detection scope as well as names. Bundle paths and
    /// which preset owns a helper must invalidate the baseline too.
    private func notifiablePresets(in watched: [WatchedAppSnapshot]) -> [WatchedAppPreset] {
        watched.map(\.preset).filter(\.notificationsEnabled)
    }

    private func apply(_ watched: [WatchedAppSnapshot]) {
        let previousPresets = notifiablePresets(in: snapshots)
        snapshots = watched
        lastSuccessfulWatchedReadAt = now()
        watchedStatusAvailability = .current
        watchedStatusLoadError = nil

        guard enableNotifications else { return }

        // Decide here rather than at the call site. A diff is only meaningful when
        // the preset detection scopes are unchanged; if it changed, the baseline
        // predates these presets and diffing would report an already-running app as
        // newly started. Self-detecting removes any dependence on callers passing
        // the right flag, and on the order in which they run.
        let notifiable = watched.filter { $0.preset.notificationsEnabled }
        if !isApplyingOwnLifecycleAction, previousPresets == notifiablePresets(in: watched) {
            notifyTransitions(notifiable)
        } else {
            primeNotificationBaseline(notifiable)
        }
    }

    @discardableResult
    private func runAction(
        kind: ProcessOperationGate.Kind,
        reportsProgress: Bool = true,
        announcesTransitions: Bool = true,
        _ operation: () async -> Void
    ) async -> Bool {
        await operationGate.run(kind: kind, reportsProgress: reportsProgress) {
            let wasApplyingOwnLifecycleAction = isApplyingOwnLifecycleAction
            if !announcesTransitions { isApplyingOwnLifecycleAction = true }
            defer { isApplyingOwnLifecycleAction = wasApplyingOwnLifecycleAction }
            await operation()
            if kind == .mutation, let shared = processInventory as? CoalescingProcessInventory {
                // Reads queued behind this mutation, and observers outside the
                // gate, must not be served a list cached before it ran.
                await shared.invalidate()
            }
        }
    }

    var watchedAppsProvider: (() -> [WatchedAppPreset])?
    var processListLimitProvider: (() -> Int)?
    var keptOffPresetsProvider: (() -> [WatchedAppPreset])?
    var isPresetKeptOffProvider: ((WatchedAppPreset) -> Bool)?
    var isKeepOffIntentWritableProvider: (() -> Bool)?
    var globalProtectServiceObservationProvider: (() async -> GlobalProtectServiceObservation)?
    var setPresetKeptOffHandler: ((WatchedAppPreset, Bool) -> Void)?
}
