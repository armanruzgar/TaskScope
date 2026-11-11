import Darwin
import Foundation
import os

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
    /// One debug line per engine pass, so its cadence can be checked:
    /// `log stream --level debug --predicate 'subsystem == "<bundle id>" AND category == "AutoStop"'`.
    /// It holds counts only, never process names.
    private static let logger = Logger(subsystem: TaskScopeLogging.subsystem(), category: "AutoStop")

    @Published private(set) var rules: [AutoStopRule] {
        didSet {
            normalizeRules()
            cancelUnauthorizedActions()
            saveRules()
            updateEnginePolling()
        }
    }
    /// The ledger's prompt queue, published for the alert and the prompt
    /// coordinator; see `ledger`.
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
    /// Everything the engine remembers about each rule-and-process occurrence:
    /// prompts, dismissals, Log Only records, stops in flight or waiting for an
    /// exit, and reported failures. Every change goes through its transitions.
    private var ledger = AutoStopOccurrenceLedger() {
        didSet {
            let prompts = ledger.prompts
            if prompts != pendingPrompts { pendingPrompts = prompts }
        }
    }
    private var actionHandler: AutoStopActionHandler?
    /// The automatic stop being sent, with the rule value captured when it
    /// started. Passes never overlap and run their stops one at a time, so
    /// there is at most one. Any edit to the rule makes the captured value
    /// differ from the stored rule and cancels the stop.
    private var automaticStop: (rule: AutoStopRule, task: Task<ProcessActionResult, Never>)?
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
        automaticStop?.task.cancel()
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
        // Editing or disabling a rule retires its live prompts, exactly as
        // deleting it does, so a switched-off rule's alert is not actionable;
        // see `AutoStopOccurrenceLedger.ruleChanged` for what an edit keeps.
        let records = ledger.ruleChanged(old: rules[index], new: normalized) { process in
            qualifiesForAutomaticStop(normalized, process: process, at: sample)
        }
        rules[index] = normalized
        record(records)
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

    /// A deleted rule's prompts, dismissals and progress go with it; see
    /// `AutoStopOccurrenceLedger.ruleRemoved` for what stays.
    private func forgetOccurrences(forRuleIDs removedIDs: Set<UUID>) {
        record(removedIDs.flatMap { ledger.ruleRemoved(id: $0) })
    }

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
        automaticStop?.task.cancel()
        automaticStop = nil
        isEngineRunning = false
    }

    /// Polling is needed while a rule is enabled, and also while a confirmed
    /// stop waits for its process to exit, so that exit is still recorded after
    /// the user switches off or deletes the last rule.
    private var needsPolling: Bool {
        rules.contains(where: \.isEnabled) || ledger.hasConfirmedStopAwaitingExit
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
                Self.logger.debug("Auto-stop pass: the process list could not be read.")
                engineError = error.localizedDescription
            case .success(let processes):
                Self.logger.debug("Auto-stop pass over \(processes.count, privacy: .public) processes.")
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
        ledger.claimPrompt(prompt.id)
    }

    /// Completes a stop for a prompt already claimed via `claimPrompt`.
    func finishStop(_ prompt: AutoStopPrompt) async {
        let result = await actionHandler?(prompt.rule, prompt.process, .confirmedPrompt) ?? .rejected
        let outcome = ledger.confirmedStopFinished(
            prompt,
            result: result,
            refusalDetail: refusalDetail(for: prompt.process),
            at: monotonicNow()
        )
        // The last enabled rule may have been switched off while the signal
        // was in flight, which stopped polling; resume it to see this exit.
        if result.isAwaitingExit, !rules.contains(where: \.isEnabled) { updateEnginePolling() }
        record([outcome])
    }

    /// Dismisses one specific prompt. Idempotent: dismissing a prompt that a button
    /// already claimed is a no-op, so SwiftUI's automatic write-back cannot consume
    /// a second, never-displayed prompt.
    func dismissPrompt(_ prompt: AutoStopPrompt) {
        guard let dismissal = ledger.dismissPrompt(prompt.id) else { return }
        record([dismissal])
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

    private func evaluate(_ processes: [AppProcess]) async {
        // The ledger follows moved and ended occurrences before it evaluates
        // the rules, so the pass cannot act on one occurrence twice. This call
        // never suspends, so no rule can change while it runs.
        let sample = recordUptime()
        let pass = ledger.observed(
            inventory: processes,
            rules: rules,
            at: monotonicNow(),
            cadence: .seconds(engineCadence),
            canLogDurably: allowsEventsPersistence,
            matches: { rule, process in matches(rule, process: process) },
            runtime: { process in ruleRuntime(of: process, at: sample) }
        )
        if isEngineRunning, !needsPolling {
            // Polling outlived the last enabled rule only to see a confirmed
            // stop's process exit, and none is left to watch.
            pollingController.stop()
        }
        // One save for the whole pass. `record` also undoes any Log Only
        // record that could not be saved, so its occurrence is logged later.
        record(pass.records)

        // An automatic stop can wait on the process-operation gate behind another
        // mutation (a preset stop, or Keep GlobalProtect Off waiting for an
        // administrator), so stops run only after every other rule was served.
        for stop in pass.dueStops {
            guard !Task.isCancelled else { return }
            // An earlier stop's suspension lets rules change. A changed rule no
            // longer authorizes this stop; the next pass evaluates the new value.
            guard isStillActive(stop.rule), ledger.beginAutomaticStop(stop) else { continue }
            // A stop records at most one event and saves it at once, so the
            // history stays current while a later stop waits on the gate.
            await performAutomaticStop(stop)
        }
    }

    private func performAutomaticStop(_ stop: AutoStopDueStop) async {
        let action = Task { [actionHandler] in
            guard !Task.isCancelled else { return ProcessActionResult.rejected }
            return await actionHandler?(stop.rule, stop.process, .automatic) ?? .rejected
        }
        automaticStop = (stop.rule, action)
        let result = await action.value
        automaticStop = nil

        let sample = recordUptime()
        record(ledger.automaticStopFinished(
            stop,
            result: result,
            isAuthorized: isStillActive(stop.rule),
            stillApplies: rules.contains {
                $0.id == stop.rule.id && qualifiesForAutomaticStop($0, process: stop.process, at: sample)
            },
            refusalDetail: refusalDetail(for: stop.process),
            at: monotonicNow()
        ))
    }

    /// Publishes records newest first and saves the log once: every save
    /// re-encodes, merges and rewrites the whole log. When the save fails, a
    /// Log Only occurrence has not completed (see `AutoStopRecord.isDurable`),
    /// so its record is dropped and the occurrence is logged on a later pass.
    /// Other records stay in memory: truthful history while an unreadable
    /// primary payload is preserved. The recovery banner makes that state
    /// visible, and an explicit reset commits the session's history.
    private func record(_ records: [AutoStopRecord]) {
        guard !records.isEmpty else { return }
        let written = records.map { record in
            (record: record, event: AutoStopEvent(
                timestamp: now(),
                processName: record.prompt.process.name,
                pid: record.prompt.process.pid,
                ruleID: record.prompt.rule.id,
                outcome: record.outcome,
                detail: record.detail,
                // Says which conditions the rule acted on; a run-time rule's
                // records say so already.
                conditions: record.prompt.rule.isRuntimeOnly ? nil : record.prompt.rule.conditionSummary
            ))
        }
        let previous = events
        events = Array((written.reversed().map(\.event) + previous).prefix(eventLimit))
        let durable = written.filter(\.record.isDurable)
        if !saveEvents(), !durable.isEmpty {
            ledger.revertLogged(durable.map(\.record.prompt.id))
            events = Array((written.reversed().filter { !$0.record.isDurable }.map(\.event) + previous).prefix(eventLimit))
        }
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

    /// Whether `rule` would stop `process`: an enabled Auto Stop rule that
    /// matches it, with its run-time floor reached. The CPU and memory
    /// conditions are judged over several checks, so an edit or a returning
    /// stop does not re-judge them here.
    private func qualifiesForAutomaticStop(_ rule: AutoStopRule, process: AppProcess, at sample: UptimeSample) -> Bool {
        guard rule.isEnabled, rule.action == .kill, matches(rule, process: process),
              let runtime = ruleRuntime(of: process, at: sample) else { return false }
        return rule.runtimeFloorSeconds.map { runtime >= $0 } ?? true
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

    /// Cancels the automatic stop in flight when its captured rule is no longer
    /// present exactly as captured: any edit (path, name, runtime, action) or a
    /// disable/delete revokes the authority the action started with.
    private func cancelUnauthorizedActions() {
        if let automaticStop, !authorizes(automaticStop.rule, kind: .automatic) {
            automaticStop.task.cancel()
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
