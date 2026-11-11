import Darwin
import Foundation

/// Why the engine is asking for a process to be stopped. The authority check
/// differs by kind: an automatic stop needs an enabled Auto Stop rule whose
/// captured value is still current, while a prompt the user just confirmed
/// only needs its rule to still exist and be enabled.
enum AutoStopActionKind: Equatable, Sendable {
    case automatic
    case confirmedPrompt
}

typealias AutoStopActionHandler = (AutoStopRule, AppProcess, AutoStopActionKind) async -> ProcessActionResult

@MainActor
final class AutoStopRulesStore: ObservableObject {
    static let maximumRuntimeMinutes = AutoStopRuleValidation.maximumRuntimeMinutes

    @Published private(set) var rules: [AutoStopRule] {
        didSet {
            normalizeRules()
            cancelUnauthorizedActions()
            saveRules()
            updateEnginePolling()
        }
    }
    @Published private(set) var pendingPrompts: [AutoStopPrompt] = []
    @Published private(set) var events: [AutoStopEvent]
    @Published private(set) var engineError: String?
    @Published private(set) var isEngineRunning = false
    @Published private(set) var validationError: String?
    @Published private(set) var rulesRecoveryMessage: String?
    @Published private(set) var eventsRecoveryMessage: String?

    var recoveryMessages: [String] {
        [rulesRecoveryMessage, eventsRecoveryMessage].compactMap { $0 }
    }

    var hasAppPromptPresenter = false
    private var promptActions: [UUID: Task<Void, Never>] = [:]

    func stopPrompt(_ prompt: AutoStopPrompt) {
        guard let claimed = claimPrompt(prompt) else { return }
        let id = UUID()
        promptActions[id] = Task { [weak self] in
            await self?.finishStop(claimed)
            self?.promptActions[id] = nil
        }
    }

    func waitForPromptActions() async {
        while !promptActions.isEmpty {
            for task in Array(promptActions.values) { await task.value }
        }
    }

    var currentPrompt: AutoStopPrompt? {
        pendingPrompts.first
    }

    private struct InFlightAction {
        /// The rule value captured when the action started. Any edit to the
        /// rule makes this differ from the stored rule and cancels the action.
        var rule: AutoStopRule
        var task: Task<ProcessActionResult, Never>
    }

    /// A stop that was accepted but whose target had not exited when checked.
    /// Resolved on a later tick: `.stopped` once the identity disappears, or
    /// one re-signal for automatic stops followed by a single failure record.
    private struct PendingExit {
        var prompt: AutoStopPrompt
        var canRetry: Bool
        /// A confirmed Stop Now records one failure if the process is still
        /// running one engine cadence after the request was accepted.
        var reportsStillRunning = false
        var firstAcceptedAt: ContinuousClock.Instant

        /// A stop the user confirmed from a prompt. It is never re-signalled,
        /// so it carries no authority, and its exit is tracked as history
        /// even after the rule is edited, switched off or deleted.
        var isConfirmedStop: Bool { prompt.rule.action == .prompt }
    }

    private let rulesPersistence: RecoveringCodableStorage<[AutoStopRule]>
    private let eventsPersistence: RecoveringCodableStorage<[AutoStopEvent]>
    private let now: () -> Date
    private let monotonicNow: () -> ContinuousClock.Instant
    private let uptimeClock: () -> UptimeSample
    /// Sleep observed while this store runs; see `ruleRuntime(of:at:)`.
    private var processAges = ProcessAgeHistory()
    private let currentUID: uid_t
    private let currentPID: Int32
    private let inventory: any ProcessInventoryProviding
    private let pollingController: ProcessPollingController
    private let eventLimit: Int
    private var handledOccurrences: Set<AutoStopOccurrence> = []
    private var reportedFailures: Set<AutoStopOccurrence> = []
    /// Last matching targets retain their signal budget across still-matching
    /// Auto Stop edits, including edits made while a signal is in flight.
    private var automaticProcesses: [AutoStopOccurrence: AppProcess] = [:]
    /// Occurrences the user dismissed. Deliberately survives rule edits and
    /// enable toggles: a dismissed process must not prompt again just because
    /// the rule was switched off and on.
    private var dismissedOccurrences: Set<AutoStopOccurrence> = []
    private var pendingExits: [AutoStopOccurrence: PendingExit] = [:]
    private var actionHandler: AutoStopActionHandler?
    private var inFlightActions: [AutoStopOccurrence: InFlightAction] = [:]
    private var isNormalizing = false
    private var isEvaluating = false
    private var needsReevaluation = false
    private var allowsRulesPersistence: Bool
    private var allowsEventsPersistence: Bool
    private var engineCadence: TimeInterval = 10

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.autoStopRules.v1",
        eventsKey: String = "TaskScope.autoStopEvents.v1",
        inventory: any ProcessInventoryProviding = SystemProcessInventory(),
        eventLimit: Int = 200,
        now: @escaping () -> Date = Date.init,
        pollingController: ProcessPollingController? = nil,
        currentUID: uid_t = getuid(),
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        monotonicNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        uptimeClock: @escaping () -> UptimeSample = UptimeSample.now
    ) {
        let boundedEventLimit = max(1, eventLimit)
        let rulesPersistence = RecoveringCodableStorage<[AutoStopRule]>(
            userDefaults: userDefaults,
            key: key
        )
        let eventsPersistence = RecoveringCodableStorage<[AutoStopEvent]>(
            userDefaults: userDefaults,
            key: eventsKey
        )
        self.rulesPersistence = rulesPersistence
        self.eventsPersistence = eventsPersistence
        self.inventory = inventory
        self.pollingController = pollingController ?? ProcessPollingController()
        self.eventLimit = boundedEventLimit
        self.now = now
        self.monotonicNow = monotonicNow
        self.uptimeClock = uptimeClock
        self.currentUID = currentUID
        self.currentPID = currentPID
        let rulesLoad = rulesPersistence.loadRecoveringElements()
        let eventsLoad = eventsPersistence.loadRecoveringElements()
        let loadedRules = (
            value: rulesLoad.value,
            message: rulesLoad.unrewritableDataDescription.map { "Auto-stop rules were read, but the payload \($0)" } ?? rulesLoad.backupKey.map {
                PersistenceRecovery.unreadableDataMessage(
                    backupKey: $0,
                    isPreserved: rulesLoad.isBackupPreserved
                )
            }
        )
        let loadedEvents = (
            value: eventsLoad.value,
            message: eventsLoad.unrewritableDataDescription.map { "Auto-stop events were read, but the payload \($0)" } ?? eventsLoad.backupKey.map {
                PersistenceRecovery.unreadableDataMessage(
                    backupKey: $0,
                    isPreserved: eventsLoad.isBackupPreserved
                )
            }
        )
        let validatedRules = AutoStopRuleValidation.validateStored(loadedRules.value ?? [])
        let rejectedCount = rulesLoad.rejectedCount + validatedRules.rejectedCount
        var rulesMessage = loadedRules.message
        var permitsRulesPersistence = loadedRules.message == nil
        if loadedRules.message == nil, rejectedCount > 0,
           let backup = rulesPersistence.preserveCurrentPayload(
               suffix: "rejectedMigrationBackup"
           ) {
            permitsRulesPersistence = false
            rulesMessage = "Rejected \(rejectedCount) invalid or duplicate stored auto-stop rule\(rejectedCount == 1 ? "" : "s"). \(PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)); reset after review to commit only the recovered safe rules."
        }
        var eventsMessage = loadedEvents.message
        var permitsEventsPersistence = loadedEvents.message == nil
        if loadedEvents.message == nil, eventsLoad.rejectedCount > 0 {
            permitsEventsPersistence = false
            if let backup = eventsPersistence.preserveCurrentPayload(suffix: "rejectedMigrationBackup") {
                eventsMessage = "Rejected \(eventsLoad.rejectedCount) invalid stored auto-stop event\(eventsLoad.rejectedCount == 1 ? "" : "s"). \(PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)); reset after review to commit the recovered events."
            }
        }
        // A decode failure must never lead to the unreadable payload being replaced
        // by the empty array we fell back to, so persistence stays disabled for that
        // key until the user explicitly resets it.
        allowsRulesPersistence = permitsRulesPersistence
        allowsEventsPersistence = permitsEventsPersistence
        rules = validatedRules.rules
        events = Array((loadedEvents.value ?? []).prefix(boundedEventLimit))
        rulesRecoveryMessage = rulesMessage
        eventsRecoveryMessage = eventsMessage
        // Processes already running may count sleep observed from here on.
        processAges.record(uptimeClock())

        if allowsEventsPersistence,
           let loadedEventCount = loadedEvents.value?.count,
           loadedEventCount > boundedEventLimit {
            saveEvents()
        }
    }

    deinit {
        inFlightActions.values.forEach { $0.task.cancel() }
    }

    /// Test convenience; Settings reads the two read-only flags below.
    var hasUnreadableData: Bool {
        !allowsRulesPersistence || !allowsEventsPersistence
    }

    var isRulesReadOnlyAfterRecovery: Bool {
        !allowsRulesPersistence
    }

    var isEventsReadOnlyAfterRecovery: Bool {
        !allowsEventsPersistence
    }

    /// False while the unreadable rule payload a reset would replace exists in
    /// no recovery slot, so the reset would destroy its only copy.
    var isRulesRecoveryBackupPreserved: Bool {
        rulesPersistence.isCurrentPayloadPreserved
    }

    /// The same for the event log's payload.
    var isEventsRecoveryBackupPreserved: Bool {
        eventsPersistence.isCurrentPayloadPreserved
    }

    /// Accepts only the rules that decoded and passed current validation, then
    /// resumes durable rule mutations.
    func resetRulesAfterCorruption() {
        guard !allowsRulesPersistence else { return }
        allowsRulesPersistence = true
        rulesRecoveryMessage = nil
        validationError = nil
        saveRules()
    }

    /// Commits the recovered events and resumes durable event logging.
    func resetEventsAfterCorruption() {
        guard !allowsEventsPersistence else { return }
        allowsEventsPersistence = true
        eventsRecoveryMessage = nil
        validationError = nil
        saveEvents()
    }

    /// Test convenience that resets both independently protected payloads;
    /// Settings resets each one with its own button.
    func resetAfterCorruption() {
        resetRulesAfterCorruption()
        resetEventsAfterCorruption()
    }

    @discardableResult
    func add(_ rule: AutoStopRule) -> Bool {
        guard !rejectUnknownRule(rule) else { return false }
        guard !rejectRulesIfReadOnly() else { return false }
        guard let normalized = validatedForEditing(rule, replacing: nil) else { return false }
        guard !rules.contains(where: {
            $0.processName.caseInsensitiveCompare(normalized.processName) == .orderedSame
        }) else {
            validationError = "A rule for \(normalized.processName) already exists."
            return false
        }
        validationError = nil
        rules.append(normalized)
        return true
    }

    /// Drops a validation message whose edit was abandoned, so it does not
    /// linger under the Add Rule form.
    func clearValidationError() {
        validationError = nil
    }

    @discardableResult
    func update(_ rule: AutoStopRule) -> Bool {
        guard !rejectUnknownRule(rule) else { return false }
        guard !rejectRulesIfReadOnly() else { return false }
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            validationError = "This auto-stop rule no longer exists."
            return false
        }
        guard let normalized = validatedForEditing(rule, replacing: rules[index]) else { return false }
        guard !rules.contains(where: {
            $0.id != rule.id &&
            $0.processName.caseInsensitiveCompare(normalized.processName) == .orderedSame
        }) else {
            validationError = "A rule for \(normalized.processName) already exists."
            return false
        }
        validationError = nil
        let sample = recordUptime()
        var retained = Set(automaticProcesses.compactMap { occurrence, process in
            occurrence.ruleID == rule.id && qualifiesForAutomaticStop(normalized, process: process, at: sample)
                ? occurrence : nil
        })
        // A confirmed Stop Now stays handled until its process exits, whatever
        // the edit: the user already answered for that occurrence, and its
        // signal was accepted, so it must neither prompt nor be signalled again.
        retained.formUnion(pendingExits.compactMap { occurrence, pending in
            occurrence.ruleID == rule.id && pending.isConfirmedStop ? occurrence : nil
        })
        let untracked = pendingExits.compactMap { occurrence, pending in
            occurrence.ruleID == rule.id && !retained.contains(occurrence) ? pending : nil
        }
        rules[index] = normalized
        handledOccurrences = handledOccurrences.filter { $0.ruleID != rule.id || retained.contains($0) }
        reportedFailures = reportedFailures.filter { $0.ruleID != rule.id || retained.contains($0) }
        pendingExits = pendingExits.filter { $0.key.ruleID != rule.id || retained.contains($0.key) }
        automaticProcesses = automaticProcesses.filter { $0.key.ruleID != rule.id || retained.contains($0.key) }
        recordUntrackedExits(untracked)
        // Editing or disabling a rule must retire its live prompts too, exactly as
        // `remove(_:)` does; otherwise a disabled rule's alert stays actionable.
        // Dismissed occurrences are kept on purpose (see `dismissedOccurrences`).
        pendingPrompts.removeAll { $0.rule.id == rule.id }
        return true
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for rule: AutoStopRule) -> Bool {
        var updated = rule
        updated.isEnabled = enabled
        return update(updated)
    }

    @discardableResult
    func duplicate(_ rule: AutoStopRule) -> Bool {
        guard !rejectUnknownRule(rule) else { return false }
        guard !rejectRulesIfReadOnly() else { return false }
        var copy = rule
        copy.id = UUID()
        copy.isEnabled = false
        copy.processName = uniqueName(basedOn: rule.processName)
        return add(copy)
    }

    @discardableResult
    func remove(at offsets: IndexSet) -> Bool {
        guard !rejectRulesIfReadOnly() else { return false }
        guard !offsets.contains(where: { rules.indices.contains($0) && rejectUnknownRule(rules[$0]) }) else {
            return false
        }
        let removedIDs = Set(offsets.compactMap { rules.indices.contains($0) ? rules[$0].id : nil })
        rules.remove(atOffsets: IndexSet(offsets.filter { rules.indices.contains($0) }))
        forgetOccurrences(forRuleIDs: removedIDs)
        validationError = nil
        return true
    }

    @discardableResult
    func remove(_ rule: AutoStopRule) -> Bool {
        guard !rejectUnknownRule(rule) else { return false }
        guard !rejectRulesIfReadOnly() else { return false }
        guard rules.contains(where: { $0.id == rule.id }) else { return false }
        rules.removeAll { $0.id == rule.id }
        forgetOccurrences(forRuleIDs: [rule.id])
        validationError = nil
        return true
    }

    private func forgetOccurrences(forRuleIDs removedIDs: Set<UUID>) {
        let untracked = pendingExits.compactMap { occurrence, pending in
            removedIDs.contains(occurrence.ruleID) && !pending.isConfirmedStop ? pending : nil
        }
        handledOccurrences = handledOccurrences.filter { !removedIDs.contains($0.ruleID) }
        reportedFailures = reportedFailures.filter { !removedIDs.contains($0.ruleID) }
        dismissedOccurrences = dismissedOccurrences.filter { !removedIDs.contains($0.ruleID) }
        // A confirmed Stop Now's exit is still recorded once it happens; it is
        // history and needs no rule (see `PendingExit.isConfirmedStop`).
        pendingExits = pendingExits.filter { !removedIDs.contains($0.key.ruleID) || $0.value.isConfirmedStop }
        automaticProcesses = automaticProcesses.filter { !removedIDs.contains($0.key.ruleID) }
        pendingPrompts.removeAll { removedIDs.contains($0.rule.id) }
        recordUntrackedExits(untracked)
    }

    /// An accepted Auto Stop whose rule was switched off, deleted, or edited so
    /// that it no longer applies loses its retry and its exit tracking, because
    /// a retired rule has no authority left. Close its "waiting for the process
    /// to exit" record so the history does not wait forever. A spent retry
    /// already ended with its own failure record, and a retry still in flight
    /// records its own outcome.
    private func recordUntrackedExits(_ untracked: [PendingExit]) {
        let closing = EventBatch()
        for pending in untracked where pending.canRetry {
            record(pending.prompt, outcome: .stopRequested, detail: Self.untrackedExitDetail, batch: closing)
        }
        flush(closing)
    }

    private static let untrackedExitDetail =
        "The rule changed or was removed before the process exited; its exit will not be tracked."

    /// Starts the engine with a handler that receives the kind of stop it is
    /// being asked to perform, so it can apply the matching authority check.
    func start(
        cadence: TimeInterval = 10,
        perform handler: @escaping AutoStopActionHandler
    ) {
        actionHandler = handler
        guard !isEngineRunning else { return }
        isEngineRunning = true
        engineCadence = max(2, cadence)
        updateEnginePolling()
    }

    /// Test convenience for handlers that do not distinguish the action kind.
    func start(
        cadence: TimeInterval = 10,
        actionHandler: @escaping (AutoStopRule, AppProcess) async -> ProcessActionResult
    ) {
        start(cadence: cadence) { rule, process, _ in
            await actionHandler(rule, process)
        }
    }

    func stop() {
        pollingController.stop()
        inFlightActions.values.forEach { $0.task.cancel() }
        inFlightActions.removeAll()
        isEngineRunning = false
    }

    /// Polling is needed while a rule is enabled, and also while a confirmed
    /// stop waits for its process to exit, so that exit is still recorded after
    /// the user switches off or deletes the last rule.
    private var needsPolling: Bool {
        rules.contains(where: \.isEnabled) || pendingExits.values.contains(where: \.isConfirmedStop)
    }

    private func updateEnginePolling() {
        guard isEngineRunning else { return }
        guard needsPolling else {
            pollingController.stop()
            engineError = nil
            return
        }
        pollingController.restart(interval: engineCadence, performImmediately: true) { [weak self] in
            await self?.evaluateNow()
        }
    }

    /// Runs one evaluation. Evaluations never overlap: a request that arrives
    /// while one is in progress (a rule edit restarts polling with an immediate
    /// tick) is honoured by re-running once the current pass finishes, and a
    /// pass whose task was cancelled stops at its next suspension point.
    func evaluateNow() async {
        guard !isEvaluating else {
            needsReevaluation = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        repeat {
            needsReevaluation = false
            let loaded = await inventory.load(fetchExtendedStats: false)
            guard !Task.isCancelled else { break }
            switch loaded {
            case .failure(let error):
                engineError = error.localizedDescription
            case .success(let processes):
                engineError = nil
                await evaluate(processes)
            }
        } while needsReevaluation && !Task.isCancelled

        if needsReevaluation, Task.isCancelled, isEngineRunning {
            // The polling task was replaced mid-pass; its replacement's immediate
            // evaluation was refused above, so run it once now.
            needsReevaluation = false
            Task { @MainActor [weak self] in
                await self?.evaluateNow()
            }
        }
    }

    /// Synchronously removes `prompt` from the queue and hands it back, or returns
    /// nil if it is already gone.
    ///
    /// Alert buttons must claim before doing any async work. SwiftUI writes
    /// `isPresented = false` as soon as a button is tapped, and that write-back runs
    /// before any `Task { }` the button enqueued — so an action that re-resolved the
    /// target afterwards would act on whatever prompt had become the queue head.
    func claimPrompt(_ prompt: AutoStopPrompt) -> AutoStopPrompt? {
        guard let index = pendingPrompts.firstIndex(where: { $0.id == prompt.id }) else { return nil }
        return pendingPrompts.remove(at: index)
    }

    /// Completes a stop for a prompt already claimed via `claimPrompt`.
    func finishStop(_ prompt: AutoStopPrompt) async {
        let result = await actionHandler?(prompt.rule, prompt.process, .confirmedPrompt) ?? .rejected
        if result.succeeded {
            record(prompt, outcome: .stopped, detail: "Stopped after confirmation.")
        } else if result.isAwaitingExit {
            // The signal was accepted; the exit is observed on a later tick. A
            // confirmed prompt is never re-signalled automatically.
            handledOccurrences.insert(prompt.id)
            pendingExits[prompt.id] = PendingExit(
                prompt: prompt,
                canRetry: false,
                reportsStillRunning: true,
                firstAcceptedAt: monotonicNow()
            )
            // The last enabled rule may have been switched off while the signal
            // was in flight, which stopped polling; resume it to see this exit.
            if !rules.contains(where: \.isEnabled) { updateEnginePolling() }
            record(
                prompt,
                outcome: .stopRequested,
                detail: "Stop requested after confirmation; waiting for the process to exit."
            )
        } else if result == .identityChanged {
            record(prompt, outcome: .failed, detail: "Process identity changed; nothing was stopped.")
        } else if result == .stale {
            record(prompt, outcome: .processEnded, detail: "Process ended before the stop request.")
        } else if result == .refused {
            record(prompt, outcome: .failed, detail: refusalDetail(for: prompt.process))
        } else {
            // Nothing was signalled for a reason that may clear (an unreadable
            // process list, a stopped engine). Un-handle so a still-running
            // occurrence prompts again instead of being silently abandoned.
            handledOccurrences.remove(prompt.id)
            record(prompt, outcome: .failed, detail: "Stop request did not complete.")
        }
    }

    /// Dismisses one specific prompt. Idempotent: dismissing a prompt that a button
    /// already claimed is a no-op, so SwiftUI's automatic write-back cannot consume
    /// a second, never-displayed prompt.
    func dismissPrompt(_ prompt: AutoStopPrompt) {
        guard let claimed = claimPrompt(prompt) else { return }
        dismissedOccurrences.insert(claimed.id)
        record(claimed, outcome: .dismissed, detail: "Dismissed; this process occurrence will not prompt again.")
    }

    /// Test convenience; the alert claims a specific prompt (see `claimPrompt`).
    func stopCurrentPrompt() async {
        guard let prompt = currentPrompt, let claimed = claimPrompt(prompt) else { return }
        await finishStop(claimed)
    }

    /// Test convenience; the alert dismisses a specific prompt.
    func dismissCurrentPrompt() {
        guard let prompt = currentPrompt else { return }
        dismissPrompt(prompt)
    }

    @discardableResult
    func clearEvents() -> Bool {
        guard !rejectEventsIfReadOnly() else { return false }
        events.removeAll()
        saveEvents()
        validationError = nil
        return true
    }

    /// A rule captured before an `await` may have been edited, disabled, or
    /// deleted while the action was in flight; `rules` is the only authority once
    /// we resume, and the whole captured value must still be present.
    private func isStillActive(_ rule: AutoStopRule) -> Bool {
        rule.isEnabled && rules.contains(rule)
    }

    /// An automatic stop found due during a pass, dispatched after every
    /// prompt and Log Only event of that pass has been handled.
    private struct DueStop {
        var rule: AutoStopRule
        var process: AppProcess
        var occurrence: AutoStopOccurrence
        var isRetry: Bool
    }

    private func evaluate(_ processes: [AppProcess]) async {
        // Resolve ended and moved occurrences first. A handled mark then already
        // follows a moved executable (same PID and start time) to its new
        // identity, so the loop below cannot act on that occurrence twice.
        let observations = EventBatch()
        pruneEndedOccurrences(processes, batch: observations)
        if isEngineRunning, !needsPolling {
            // Polling outlived the last enabled rule only to see a confirmed
            // stop's process exit, and none is left to watch.
            pollingController.stop()
        }

        // This loop never suspends, so no rule can change while it runs.
        let activeRules = rules.filter(\.isEnabled)
        let sample = recordUptime()
        var dueStops: [DueStop] = []
        for process in processes {
            guard let runtime = ruleRuntime(of: process, at: sample) else { continue }
            for rule in activeRules where matches(rule, process: process) && isStillActive(rule) {
                let occurrence = AutoStopOccurrence(ruleID: rule.id, processIdentity: process.identity)
                guard runtime >= TimeInterval(rule.runtimeMinutes) * 60,
                      (rule.action != .prompt || !dismissedOccurrences.contains(occurrence)) else {
                    continue
                }

                if rule.action == .kill { automaticProcesses[occurrence] = process }
                // A queued prompt shows the process as it is now, not as it was
                // when the threshold was first crossed (same occurrence, so an
                // answer still acts on the same process).
                if let index = pendingPrompts.firstIndex(where: { $0.id == occurrence }),
                   pendingPrompts[index].process != process {
                    pendingPrompts[index].process = process
                }
                if handledOccurrences.contains(occurrence) {
                    // Already acted on. The only follow-up is a single re-signal of
                    // an automatic stop whose target has not exited yet.
                    guard rule.action == .kill,
                          let pending = pendingExits[occurrence],
                          pending.canRetry,
                          pending.firstAcceptedAt.duration(to: monotonicNow()) >= .seconds(engineCadence) else {
                        continue
                    }
                    dueStops.append(DueStop(rule: rule, process: process, occurrence: occurrence, isRetry: true))
                    continue
                }

                let prompt = AutoStopPrompt(id: occurrence, rule: rule, process: process)
                switch rule.action {
                case .prompt:
                    handledOccurrences.insert(occurrence)
                    pendingPrompts.append(prompt)
                case .kill:
                    // Marked handled only when it is dispatched below, so a pass
                    // that ends before reaching it leaves it to the next pass.
                    dueStops.append(DueStop(rule: rule, process: process, occurrence: occurrence, isRetry: false))
                case .silent:
                    handledOccurrences.insert(occurrence)
                    if !record(
                        prompt,
                        outcome: .logged,
                        detail: "Runtime threshold reached.",
                        requiresDurability: true,
                        batch: observations
                    ) {
                        // A log-only occurrence has not completed until its event is
                        // durably recorded. Retry after the event recovery gate is reset.
                        handledOccurrences.remove(occurrence)
                    }
                }
            }
        }
        // One save for the whole pass. `flush` also un-handles any Log Only
        // occurrence whose event could not be saved.
        flush(observations)

        // An automatic stop can wait on the process-operation gate behind another
        // mutation (a preset stop, or Keep GlobalProtect Off waiting for an
        // administrator), so stops run only after every other rule was served.
        for stop in dueStops {
            guard !Task.isCancelled else { return }
            // An earlier stop's suspension lets rules change. A changed rule no
            // longer authorizes this stop; the next pass evaluates the new value.
            guard isStillActive(stop.rule) else { continue }
            if stop.isRetry {
                guard let pending = pendingExits[stop.occurrence], pending.canRetry else { continue }
                pendingExits[stop.occurrence]?.canRetry = false
            } else {
                guard handledOccurrences.insert(stop.occurrence).inserted else { continue }
            }
            // A stop records at most one event and saves it at once, so the
            // history stays current while a later stop waits on the gate.
            await performAutomaticStop(
                rule: stop.rule,
                process: stop.process,
                occurrence: stop.occurrence,
                prompt: AutoStopPrompt(id: stop.occurrence, rule: stop.rule, process: stop.process),
                isRetry: stop.isRetry
            )
        }
    }

    private func performAutomaticStop(
        rule: AutoStopRule,
        process: AppProcess,
        occurrence: AutoStopOccurrence,
        prompt: AutoStopPrompt,
        isRetry: Bool
    ) async {
        let firstAcceptedAt = pendingExits[occurrence]?.firstAcceptedAt
        let action = Task { [actionHandler] in
            guard !Task.isCancelled else { return ProcessActionResult.rejected }
            return await actionHandler?(rule, process, .automatic) ?? .rejected
        }
        inFlightActions[occurrence] = InFlightAction(rule: rule, task: action)
        let result = await action.value
        inFlightActions[occurrence] = nil

        // A retired rule cannot authorize more work, but a signal already
        // delivered must remain in the event history.
        let sample = recordUptime()
        let isActive = isStillActive(rule) || (automaticProcesses[occurrence] != nil && rules.contains {
            $0.id == rule.id && qualifiesForAutomaticStop($0, process: process, at: sample)
        })
        if result == .rejected, !isStillActive(rule), isActive {
            // An edit revoked the captured pre-signal authority. Preserve any
            // accepted first request's retry budget, but do not log a failure
            // for an action that never sent its signal.
            if let pending = pendingExits[occurrence] {
                pendingExits[occurrence] = PendingExit(
                    prompt: pending.prompt, canRetry: true, firstAcceptedAt: pending.firstAcceptedAt
                )
            } else {
                handledOccurrences.remove(occurrence)
            }
            return
        }
        if !isActive {
            handledOccurrences.remove(occurrence)
            pendingExits[occurrence] = nil
            guard result == .stopped || result == .requestedStillRunning else {
                // A retry follows an accepted first request whose record says it
                // is waiting for the exit; the retired rule tracks nothing more,
                // so close that record (see `recordUntrackedExits`).
                if isRetry {
                    if result == .stale {
                        record(prompt, outcome: .stopped, detail: "Exited after the stop request.")
                    } else {
                        record(prompt, outcome: .stopRequested, detail: Self.untrackedExitDetail)
                    }
                }
                return
            }
        }

        switch result {
        case .stopped:
            reportedFailures.remove(occurrence)
            pendingExits[occurrence] = nil
            record(
                prompt,
                outcome: .stopped,
                detail: isRetry ? "Stopped automatically after a second stop request." : "Stopped automatically."
            )
        case .identityChanged:
            pendingExits[occurrence] = nil
            record(prompt, outcome: .failed, detail: "Process identity changed; automatic stopping will not retry.")
        case .stale:
            // The verified identity is gone: the process exited after the
            // engine observed it, or after the first stop request on a retry.
            pendingExits[occurrence] = nil
            if isRetry {
                record(prompt, outcome: .stopped, detail: "Exited after the stop request.")
            } else {
                record(prompt, outcome: .processEnded, detail: "Process ended before the automatic stop.")
            }
        case .requestedStillRunning where !isRetry || !isActive:
            if isActive {
                pendingExits[occurrence] = PendingExit(prompt: prompt, canRetry: true, firstAcceptedAt: firstAcceptedAt ?? monotonicNow())
            }
            record(prompt, outcome: .stopRequested, detail: isActive
                ? "Stop requested; waiting for the process to exit."
                : "Stop requested; the rule changed or was removed, so automatic stopping will not retry.")
        case .requestedStillRunning:
            // Two stop requests were accepted and the process is still running.
            // Stop retrying so a process that ignores SIGTERM is not signalled on
            // every tick; the user can force stop it. A later exit is still
            // recorded when the identity disappears.
            pendingExits[occurrence] = PendingExit(prompt: prompt, canRetry: false, firstAcceptedAt: firstAcceptedAt ?? monotonicNow())
            record(
                prompt,
                outcome: .failed,
                detail: "Still running after a second stop request; automatic stopping will not retry. Use Force Stop if it must exit."
            )
        case .refused:
            // The kernel or a safety guard refused the signal. Retrying every tick
            // cannot succeed, so the occurrence stays handled until it exits.
            pendingExits[occurrence] = nil
            record(prompt, outcome: .failed, detail: refusalDetail(for: process) + " Automatic stopping will not retry.")
        case .rejected where isRetry:
            // The re-signal never ran (most often an unreadable process list).
            // Keep the single retry available for the next tick.
            pendingExits[occurrence] = PendingExit(prompt: prompt, canRetry: true, firstAcceptedAt: firstAcceptedAt ?? monotonicNow())
        case .rejected:
            // Nothing was signalled — most often because the process list could
            // not be read. Un-handle so the next tick retries instead of
            // abandoning a still-running process, but log the failure only once
            // per occurrence so a persistent fault cannot flood the event log.
            handledOccurrences.remove(occurrence)
            pendingExits[occurrence] = nil
            if reportedFailures.insert(occurrence).inserted {
                record(prompt, outcome: .failed, detail: "Automatic stop did not complete.")
            }
        }
    }

    private func pruneEndedOccurrences(_ processes: [AppProcess], batch: EventBatch) {
        let runningProcesses = processes.filter { !$0.hasExited }
        let runningIdentities = Set(runningProcesses.map(\.identity))
        automaticProcesses = automaticProcesses.filter { runningIdentities.contains($0.key.processIdentity) }
        let currentByPID = Dictionary(runningProcesses.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // A kernel path can change during one lifetime. Keep Dismiss and the
        // automatic signal budget, but let unanswered prompts use the new identity.
        func currentOccurrence(_ occurrence: AutoStopOccurrence) -> AutoStopOccurrence? {
            guard let process = currentByPID[occurrence.processIdentity.pid],
                  process.startTime == occurrence.processIdentity.startTime else { return nil }
            return AutoStopOccurrence(ruleID: occurrence.ruleID, processIdentity: process.identity)
        }
        let unanswered = Set(pendingPrompts.map(\.id))
        let carried = handledOccurrences.filter {
            runningIdentities.contains($0.processIdentity) || !unanswered.contains($0)
        }
        handledOccurrences = Set(carried.compactMap(currentOccurrence))
        reportedFailures = Set(reportedFailures.compactMap(currentOccurrence))
        dismissedOccurrences = Set(dismissedOccurrences.compactMap(currentOccurrence))
        // A confirmed stop is never re-signalled, but one engine cadence after it
        // was accepted a process that is still running gets one failure record,
        // so the history does not say "waiting" for as long as it runs.
        for (occurrence, pending) in pendingExits where pending.reportsStillRunning
            && runningIdentities.contains(occurrence.processIdentity)
            && pending.firstAcceptedAt.duration(to: monotonicNow()) >= .seconds(engineCadence) {
            pendingExits[occurrence]?.reportsStillRunning = false
            record(pending.prompt, outcome: .failed,
                   detail: "Still running after the confirmed stop request. Use Force Stop if it must exit.", batch: batch)
        }
        // A different start time on the same PID means the captured lifetime
        // ended and the kernel reused its PID. Only the same lifetime with a
        // moved or unreadable executable is an identity change.
        for (occurrence, pending) in pendingExits
        where !runningIdentities.contains(occurrence.processIdentity) {
            pendingExits[occurrence] = nil
            if currentOccurrence(occurrence) != nil {
                record(pending.prompt, outcome: .failed,
                       detail: "Process identity changed; exit could not be confirmed and stopping will not retry.", batch: batch)
            } else {
                record(pending.prompt, outcome: .stopped, detail: "Exited after the stop request.", batch: batch)
            }
        }
        for prompt in pendingPrompts where !runningIdentities.contains(prompt.id.processIdentity) {
            if currentOccurrence(prompt.id) != nil {
                record(prompt, outcome: .failed, detail: "Process identity changed before the prompt was handled; nothing was stopped.", batch: batch)
            } else {
                record(prompt, outcome: .processEnded, detail: "Process ended before the prompt was handled.", batch: batch)
            }
        }
        pendingPrompts.removeAll {
            !runningIdentities.contains($0.id.processIdentity)
                || dismissedOccurrences.contains($0.id)
        }
    }

    /// Events recorded together (one engine pass, or one rule change) and saved
    /// once: every save re-encodes, merges and rewrites the whole log.
    private final class EventBatch {
        var entries: [(event: AutoStopEvent, durableOccurrence: AutoStopOccurrence?)] = []
    }

    /// Publishes a batch newest first and saves the log once. When the save
    /// fails, a Log Only occurrence has not completed (see `record`), so its
    /// event is dropped and the occurrence is retried on a later pass; other
    /// events stay in memory, as an unsaved single event does.
    private func flush(_ batch: EventBatch) {
        guard !batch.entries.isEmpty else { return }
        let previous = events
        events = Array((batch.entries.reversed().map(\.event) + previous).prefix(eventLimit))
        let durable = batch.entries.compactMap(\.durableOccurrence)
        if !saveEvents(), !durable.isEmpty {
            handledOccurrences.subtract(durable)
            events = Array((batch.entries.reversed().filter { $0.durableOccurrence == nil }.map(\.event) + previous).prefix(eventLimit))
        }
        batch.entries.removeAll()
    }

    @discardableResult
    private func record(
        _ prompt: AutoStopPrompt,
        outcome: AutoStopEvent.Outcome,
        detail: String,
        requiresDurability: Bool = false,
        batch: EventBatch? = nil
    ) -> Bool {
        guard !requiresDurability || allowsEventsPersistence else { return false }
        let event = AutoStopEvent(
            timestamp: now(),
            processName: prompt.process.name,
            pid: prompt.process.pid,
            ruleID: prompt.rule.id,
            outcome: outcome,
            detail: detail
        )
        if let batch {
            // Published and saved by `flush`, which also enforces durability.
            batch.entries.append((event, requiresDurability ? prompt.id : nil))
            return true
        }
        events.insert(event, at: 0)
        if events.count > eventLimit {
            events.removeLast(events.count - eventLimit)
        }
        // Keep truthful in-memory history while preserving an unreadable primary
        // payload. The recovery banner makes its non-durable state visible, and an
        // explicit reset commits the recovered session history.
        let persisted = saveEvents()
        if requiresDurability, !persisted {
            events.removeAll { $0.id == event.id }
            return false
        }
        return true
    }

    private func matches(_ rule: AutoStopRule, process: AppProcess) -> Bool {
        guard !process.hasExited,
              process.pid != currentPID,
              ProcessSignalGuard.isSignalablePID(process.pid),
              process.uid == currentUID,
              rule.processName.caseInsensitiveCompare(process.name) == .orderedSame else {
            return false
        }
        guard let rulePath = rule.executablePath else { return true }
        guard let processPath = process.executablePath else { return false }
        return AutoStopRuleValidation.pathsMatch(rulePath, processPath)
    }

    private func qualifiesForAutomaticStop(_ rule: AutoStopRule, process: AppProcess, at sample: UptimeSample) -> Bool {
        rule.isEnabled && rule.action == .kill && matches(rule, process: process)
            && (ruleRuntime(of: process, at: sample) ?? 0) >= TimeInterval(rule.runtimeMinutes) * 60
    }

    private func recordUptime() -> UptimeSample {
        let sample = uptimeClock()
        processAges.record(sample)
        return sample
    }

    /// The runtime a rule may act on. `ps etime` is wall-clock arithmetic, so
    /// a live row must also reach the threshold on the kernel's monotonic
    /// clocks, and a forward clock step cannot make a rule act early. Rows
    /// from sources that never read kernel start times use `etime` alone.
    private func ruleRuntime(of process: AppProcess, at sample: UptimeSample) -> TimeInterval? {
        guard let elapsed = process.runtimeSeconds else { return nil }
        switch process.monotonicStart {
        case .notRead:
            return elapsed
        case .unavailable:
            return nil
        case .uptimeNanoseconds(let start):
            return processAges.minimumAge(sinceUptime: start, at: sample).map { min(elapsed, $0) }
        }
    }

    private func refusalDetail(for process: AppProcess) -> String {
        ProcessSignalGuard.refusalDetail(for: process, currentPID: currentPID, currentUID: currentUID)
    }

    /// Cancels every in-flight automatic stop whose captured rule is no longer
    /// present exactly as captured: any edit (path, name, runtime, action) or a
    /// disable/delete revokes the authority the action started with.
    private func cancelUnauthorizedActions() {
        for (_, action) in inFlightActions where !authorizes(action.rule, kind: .automatic) {
            action.task.cancel()
        }
    }

    /// The final authority check the stop path runs immediately before
    /// `kill(2)`. An automatic stop requires the captured rule to still be
    /// stored unchanged, enabled, and set to Auto Stop; a confirmed prompt
    /// requires only that its rule still exists and is enabled.
    func authorizes(_ rule: AutoStopRule, kind: AutoStopActionKind) -> Bool {
        switch kind {
        case .automatic:
            return rule.isEnabled && rule.action == .kill && rules.contains(rule)
        case .confirmedPrompt:
            return rules.contains { $0.id == rule.id && $0.isEnabled }
        }
    }

    private func rejectUnknownRule(_ rule: AutoStopRule) -> Bool {
        guard rule.hasUnknownFields || rules.contains(where: { $0.id == rule.id && $0.hasUnknownFields }) else {
            return false
        }
        validationError = "This rule contains fields from a newer build and is disabled and read-only. Use a build that understands it."
        return true
    }

    private func rejectRulesIfReadOnly() -> Bool {
        guard !allowsRulesPersistence else { return false }
        validationError = "Auto-stop rule data is in recovery mode; reset the rules before making changes."
        return true
    }

    private func rejectEventsIfReadOnly() -> Bool {
        guard !allowsEventsPersistence else { return false }
        validationError = "Auto-stop event data is in recovery mode; reset the event log before clearing it."
        return true
    }

    private func validated(_ rule: AutoStopRule) -> AutoStopRule? {
        switch AutoStopRuleValidation.validate(rule) {
        case .success(let normalized):
            return normalized
        case .failure(let error):
            validationError = error.message
            return nil
        }
    }

    /// `validated` plus the checks for a rule the user adds or edits; see
    /// `AutoStopRuleValidation.validateForEditing`.
    private func validatedForEditing(_ rule: AutoStopRule, replacing stored: AutoStopRule?) -> AutoStopRule? {
        switch AutoStopRuleValidation.validateForEditing(rule, replacing: stored) {
        case .success(let normalized):
            return normalized
        case .failure(let error):
            validationError = error.message
            return nil
        }
    }

    private func uniqueName(basedOn name: String) -> String {
        var suffix = 2
        var candidate = "\(name) Copy"
        while rules.contains(where: { $0.processName.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(name) Copy \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func normalizeRules() {
        guard !isNormalizing else { return }
        var normalized: [AutoStopRule] = []
        for rule in rules {
            // The comparison `add`, `update` and the engine use, so a rule they
            // accepted is never dropped here.
            guard let valid = validated(rule),
                  !normalized.contains(where: {
                      $0.processName.caseInsensitiveCompare(valid.processName) == .orderedSame
                  }) else { continue }
            normalized.append(valid)
        }
        guard normalized != rules else { return }
        isNormalizing = true
        rules = normalized
        isNormalizing = false
    }

    private func saveRules() {
        guard allowsRulesPersistence else { return }
        rulesPersistence.savePreservingUnknownFields(rules)
    }

    @discardableResult
    private func saveEvents() -> Bool {
        guard allowsEventsPersistence else { return false }
        return eventsPersistence.savePreservingUnknownFields(events)
    }

}
