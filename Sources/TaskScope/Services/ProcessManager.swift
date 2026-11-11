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

    @Published var sortOrder = ProcessSortOrder(key: .cpu) {
        didSet { resortProcesses() }
    }

    /// Setting only the key sorts in that key's default direction.
    var sortKey: ProcessSortKey {
        get { sortOrder.key }
        set { sortOrder = ProcessSortOrder(key: newValue) }
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
    var globalProtectDisconnectFailureID: UUID? {
        lifecycleCoordinator.globalProtectDisconnectFailureID
    }
    /// Explicit Keep Off actions in flight, shared with the preset deletion
    /// policy so a preset is not deleted halfway through its Keep Off.
    let keepOffActivity: KeepOffActivity
    private var keepOffActivityCancellable: AnyCancellable?
    var isGlobalProtectKeepOffPending: Bool {
        keepOffActivity.isPending(WatchedAppPreset.globalProtectID)
    }
    /// How long background enforcement leaves GlobalProtect's UI alone after an
    /// explicit disconnect failed and told the user to complete its request.
    static var disconnectFailureGraceSeconds: TimeInterval {
        PresetLifecycleCoordinator.disconnectFailureGraceSeconds
    }
    /// Settings and presets, passed whole at construction. Tests may replace a
    /// member after construction.
    var dependencies: Dependencies
    /// Open, Keep Off, Allow to Run, preset stops and background enforcement.
    private let lifecycleCoordinator: PresetLifecycleCoordinator
    private var lifecycleCoordinatorCancellable: AnyCancellable?
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
    /// Turns the network and disk counters of consecutive inventories into
    /// the per-second rates the list shows and sorts by.
    private var ioRates = ProcessIORateTracker()
    private var fullProcessInventory: [AppProcess] {
        get { listProjection.inventory }
        set {
            listProjection = ProcessListProjection(inventory: ioRates.apply(to: newValue, at: now()))
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
            await ProcessLifecycleController.settleAfterProcessChange(runtime: .live)
        },
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        pollingController: ProcessPollingController? = nil,
        processHistory: ProcessHistory? = nil,
        detailReader: any ProcessDetailReading = SystemProcessDetailReader(),
        keepOffActivity: KeepOffActivity = KeepOffActivity(),
        now: @escaping () -> Date = Date.init,
        dependencies: Dependencies
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
        self.keepOffActivity = keepOffActivity
        self.dependencies = dependencies
        lifecycleCoordinator = PresetLifecycleCoordinator(lifecycle: lifecycle, now: now)
        snapshotBuilder = WatchedSnapshotBuilder(excludedPID: currentPID)
        operationGateCancellable = operationGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        keepOffActivityCancellable = keepOffActivity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        lifecycleCoordinatorCancellable = lifecycleCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Configures the poll. `backgroundActivity` says whether anything needs
    /// the poll while no window or popover shows status: notifications diff its
    /// reads, Keep Off enforcement runs on its ticks, and the menu-bar icon
    /// shows the status they read. Without it, polling runs only between
    /// `beginObservingStatus` and `endObservingStatus`.
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
            order: sortOrder,
            limit: dependencies.processListLimit(),
            matching: predicate
        )
    }

    /// The sorted, filtered, limited list for `query`, memoized per inventory,
    /// sort order, and limit by the projection.
    func displayProcesses(for query: ProcessListQuery) -> [AppProcess] {
        listProjection.displayProcesses(
            for: query, order: sortOrder, limit: dependencies.processListLimit()
        )
    }

    func displayList(for query: ProcessListQuery) -> ProcessListProjection.DisplayList {
        listProjection.displayList(
            for: query, order: sortOrder, limit: dependencies.processListLimit()
        )
    }

    /// Tree roots give every displayed match its ancestor context from the full
    /// inventory, including ancestors outside the display limit.
    func treeRoots(for query: ProcessListQuery) -> [ProcessTreeNode] {
        listProjection.treeRoots(
            for: query, order: sortOrder, limit: dependencies.processListLimit()
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

    /// Get Watched App Status. It refreshes watched status like a poll tick,
    /// without changing the status line, and reports the preset from the
    /// snapshot that read verified, or, when the read failed, from the last
    /// snapshot as stale (unknown if there is none). It changes nothing else.
    func watchedStatus(for preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        await refreshWatchedStatus(showMessage: false)
        if Task.isCancelled || lastInventoryReadWasCancelled {
            return TaskScopeCommandResult(status: .rejected, message: "Status check for \(preset.displayName) was cancelled.")
        }
        let summary = watchedStatusSummary(for: preset)
        return TaskScopeCommandResult(status: .completed, message: summary.sentence, watchedStatus: summary)
    }

    /// The preset's state in the snapshots on screen, with its Keep Off intent.
    func watchedStatusSummary(for preset: WatchedAppPreset) -> WatchedAppStatusSummary {
        WatchedAppStatusSummary(
            preset: preset, snapshots: snapshots, availability: watchedStatusAvailability,
            isKeptOff: dependencies.isPresetKeptOff(preset)
        )
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

    @discardableResult
    func openApp(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if let refusal = lifecycleCoordinator.newerBuildRefusal(for: preset, host: self) { return refusal }
        var commandResult = TaskScopeCommandResult(status: .failed, message: "Open did not complete.")
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            let outcome = await lifecycleCoordinator.open(preset, host: self)
            publish(outcome)
            commandResult = outcome.result
        }
        if !ran {
            return TaskScopeCommandResult(status: .rejected, message: "Open for \(preset.displayName) was cancelled.")
        }
        return commandResult
    }

    /// Persists intent and disables user jobs; see
    /// `PresetLifecycleCoordinator.keepOff`. With `recordIntent == false` this
    /// is background enforcement, which re-checks the persisted intent inside
    /// the operation gate.
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
        if let refusal = lifecycleCoordinator.newerBuildRefusal(for: preset, host: self) { return refusal }
        // Pending from the request on, including time queued behind the gate.
        let tracksPendingAction = recordIntent
        if tracksPendingAction { keepOffActivity.begin(preset.id) }
        defer {
            if tracksPendingAction { keepOffActivity.end(preset.id) }
        }
        var commandResult = TaskScopeCommandResult(status: .failed, message: "Keep Off did not complete.")
        // Background enforcement was not just requested by the user, so the
        // processes it stops are still announced.
        await runAction(kind: .mutation, announcesTransitions: !recordIntent) {
            let outcome = await lifecycleCoordinator.keepOff(
                preset, recordIntent: recordIntent, confirmedFailureID: confirmedFailureID, host: self
            )
            publish(outcome)
            commandResult = outcome.result
        }
        if !recordIntent && Task.isCancelled {
            return TaskScopeCommandResult(status: .rejected, message: "Keep Off enforcement cancelled; it will retry on the next poll.")
        }
        return commandResult
    }

    /// Turns Keep Off off for a preset without opening it: clears its launchd
    /// disable overrides and its intent. The built-in GlobalProtect preset's
    /// switch uses Open instead, which also restores its VPN service.
    @discardableResult
    func allowToRun(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if let refusal = lifecycleCoordinator.newerBuildRefusal(for: preset, host: self) { return refusal }
        var commandResult = TaskScopeCommandResult(status: .failed, message: "Allow to Run did not complete.")
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            let outcome = await lifecycleCoordinator.allowToRun(preset, host: self)
            publish(outcome)
            commandResult = outcome.result
        }
        if !ran {
            return TaskScopeCommandResult(status: .rejected, message: "Allow to Run for \(preset.displayName) was cancelled.")
        }
        return commandResult
    }

    /// Enforces persisted Keep Off intent; see
    /// `PresetLifecycleCoordinator.enforceKeptOffPresets`.
    func enforceKeptOffPresets(force: Bool = false, usingFreshSnapshots: Bool = false) async {
        await lifecycleCoordinator.enforceKeptOffPresets(force: force, usingFreshSnapshots: usingFreshSnapshots, host: self)
    }

    func enforceKeepOff(_ preset: WatchedAppPreset) async {
        _ = await keepOff(preset, recordIntent: false)
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
        if preset.isBuiltInGlobalProtect {
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

    /// Quit App and Helpers, then Open, under one confirmation and one report.
    /// Custom presets only; see `PresetLifecycleCoordinator.restart`.
    @discardableResult
    func restart(_ preset: WatchedAppPreset) async -> TaskScopeCommandResult {
        if let refusal = lifecycleCoordinator.newerBuildRefusal(for: preset, host: self) { return refusal }
        var commandResult = TaskScopeCommandResult(status: .failed, message: "Restart did not complete.")
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            // Admitted, a restart finishes both steps even if its caller leaves,
            // so it never ends with the app quit and not reopened by accident.
            commandResult = await Task { @MainActor in
                let outcome = await lifecycleCoordinator.restart(preset, host: self)
                publish(outcome)
                return outcome.result
            }.value
        }
        if !ran {
            return TaskScopeCommandResult(status: .rejected, message: "Restart of \(preset.displayName) was cancelled.")
        }
        return commandResult
    }

    private func stop(_ preset: WatchedAppPreset, scope: PresetStopScope) async -> TaskScopeCommandResult {
        if let refusal = lifecycleCoordinator.newerBuildRefusal(for: preset, host: self) { return refusal }
        var commandResult = PresetStopResult.failed(scope.incompleteMessage, reason: .incomplete).commandResult
        let ran = await runAction(kind: .mutation, announcesTransitions: false) {
            // Admission is the cancellation boundary for Stop. Once admitted,
            // finish all scoped stops and verification even if its caller leaves.
            commandResult = await Task { @MainActor in
                let outcome = await lifecycleCoordinator.stop(preset, scope: scope, host: self)
                publish(outcome)
                return outcome.result
            }.value
        }
        if !ran {
            return TaskScopeCommandResult(status: .rejected, message: "Stop for \(preset.displayName) was cancelled.")
        }
        return commandResult
    }

    /// Shows what a preset lifecycle action decided: its status line, report
    /// and, for a failure, its diagnostic.
    private func publish(_ outcome: PresetLifecycleOutcome) {
        if let message = outcome.message { self.message = message }
        if case .replace(let report) = outcome.report { lifecycleReport = report }
        if let diagnostic = outcome.diagnostic {
            lifecycleDiagnostics.record(
                presetID: diagnostic.presetID, action: diagnostic.action,
                backgroundEnforcement: diagnostic.backgroundEnforcement, reason: diagnostic.reason,
                jobs: diagnostic.jobs, at: now()
            )
        }
    }

    func showProgress(_ text: String) {
        message = text
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
            switch await verifyTarget(process) {
            case .cancelled:
                message = "Stop for \(process.name) was cancelled."
                return
            case .unreadable:
                message = "Could not verify \(process.name); nothing was stopped."
                result = .rejected
                return
            case .changed(let identityChanged):
                message = identityChanged
                    ? "\(process.name)'s identity changed; nothing was stopped."
                    : "\(process.name) is no longer running."
                result = identityChanged ? .identityChanged : .stale
                return
            case .verified:
                break
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

    /// Pause, Resume and Send Signal: one signal to one process, through the
    /// same path as Stop. The captured identity is checked against a fresh
    /// inventory first; nothing is sent to a PID whose identity changed, and
    /// never to a process group. Only the user's own ordinary processes are
    /// eligible (`ProcessSignalEligibility`).
    @discardableResult
    func sendSignal(_ action: ProcessSignalAction, to process: AppProcess) async -> ProcessSignalOutcome {
        if let refusal = ProcessSignalEligibility.refusal(for: process, currentPID: currentPID, currentUID: getuid()) {
            message = "\(action.name) is not available for \(process.name). \(refusal)"
            return .refused
        }
        var outcome: ProcessSignalOutcome = .rejected
        await runAction(kind: .mutation) {
            switch await verifyTarget(process) {
            case .cancelled:
                message = "\(action.name) for \(process.name) was cancelled."
                return
            case .unreadable:
                message = "Could not verify \(process.name); nothing was sent."
                return
            case .changed(let identityChanged):
                message = identityChanged
                    ? "\(process.name)'s identity changed; nothing was sent."
                    : "\(process.name) is no longer running."
                outcome = identityChanged ? .identityChanged : .notRunning
                return
            case .verified:
                break
            }
            // No await may come between this check and kill(2).
            guard !Task.isCancelled else {
                message = "\(action.name) for \(process.name) was cancelled."
                return
            }
            let delivery = processSignaler.deliver(action.signal, to: process.pid)
            await settleAfterProcessChange()
            switch delivery {
            case .rejected(let code):
                let reason = code == EPERM ? "" : " (\(String(cString: strerror(code))))"
                message = "Could not send \(action.signalName) to \(process.name). The system refused the signal\(reason)."
                outcome = .refused
            case .noSuchProcess:
                message = "\(process.name) had already exited; nothing was sent."
                outcome = .notRunning
            case .delivered:
                message = action.deliveredMessage(for: process)
                outcome = .delivered
            }
            await refreshAfterMutation()
        }
        return outcome
    }

    private enum TargetVerification {
        case verified
        case cancelled
        case unreadable
        /// The target is gone or another process now has its PID. The fresh
        /// inventory has been published.
        case changed(identityChanged: Bool)
    }

    /// Checks a single-process action's captured identity against a fresh,
    /// uncached inventory read.
    private func verifyTarget(_ process: AppProcess) async -> TargetVerification {
        let verificationResult = await verificationInventory.load(fetchExtendedStats: false)
        // An unreadable process list says nothing about this target. Treating it
        // as an identity change both lied to the user and wiped the whole
        // selection by reconciling against an empty inventory.
        if Task.isCancelled || verificationResult == .failure(.cancelled) {
            return .cancelled
        }
        guard case .success(let currentProcesses) = verificationResult else {
            if case .failure(let error) = verificationResult {
                recordInventoryFailure(error)
            }
            return .unreadable
        }
        recordInventorySuccess()
        guard currentProcesses.contains(where: { !$0.hasExited && $0.identity == process.identity }) else {
            let identityChanged = currentProcesses.contains { $0.pid == process.pid && !$0.hasExited }
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
            return .changed(identityChanged: identityChanged)
        }
        return .verified
    }

    /// The row's command line for Copy Command Line, read only if the PID still
    /// has the row's identity. It is handed to the caller and never kept here.
    func commandLine(for process: AppProcess) async -> CommandLineReadResult {
        await detailReader.commandLine(for: process.identity)
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

    func refreshInventoryAfterMutation() async -> [AppProcess]? {
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

    func currentSnapshot(
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
        snapshotBuilder.snapshots(for: dependencies.watchedPresets(), in: inventory)
    }

    func snapshot(
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

}

extension ProcessManager: PresetLifecycleHost {}

extension ProcessManager {
    /// What ProcessManager reads from settings and presets, passed whole at
    /// construction. No member is optional, so a dependency that is not wired
    /// is a compile error instead of a default that silently fails open. The
    /// app builds it with `.app`; tests start from `.inert`.
    struct Dependencies {
        /// The watched presets, in display order.
        var watchedPresets: @MainActor () -> [WatchedAppPreset]
        /// How many rows the process list shows.
        var processListLimit: @MainActor () -> Int
        /// The presets background enforcement keeps off.
        var keptOffPresets: @MainActor () -> [WatchedAppPreset]
        var isPresetKeptOff: @MainActor (WatchedAppPreset) -> Bool
        /// False while settings are unreadable: Keep Off intent cannot be
        /// written, so explicit Keep Off is refused.
        var isKeepOffIntentWritable: @MainActor () -> Bool
        /// GlobalProtect's session and system VPN service state, read after a
        /// built-in Keep Off; nil when there is no reading, so the final
        /// process snapshot decides.
        var globalProtectServiceObservation: @MainActor () async -> GlobalProtectServiceObservation?
        /// Records or clears a preset's Keep Off intent.
        var setPresetKeptOff: @MainActor (WatchedAppPreset, Bool) -> Void

        /// No presets, the default list limit, nothing kept off, writable Keep
        /// Off intent, no service reading, and intent writes ignored.
        static var inert: Dependencies {
            Dependencies(
                watchedPresets: { [] },
                processListLimit: { SettingsStore.defaultProcessListLimit },
                keptOffPresets: { [] },
                isPresetKeptOff: { _ in false },
                isKeepOffIntentWritable: { true },
                globalProtectServiceObservation: { nil },
                setPresetKeptOff: { _, _ in }
            )
        }
    }
}
