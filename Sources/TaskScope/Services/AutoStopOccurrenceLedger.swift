import Foundation

/// A history record that an occurrence transition asks the store to write.
struct AutoStopRecord: Equatable {
    var prompt: AutoStopPrompt
    var outcome: AutoStopEvent.Outcome
    var detail: String
    /// Log Only: the occurrence counts as logged only once this record is
    /// saved, so the store undoes a failed save with `revertLogged(_:)`.
    var isDurable = false
}

/// An automatic stop found due during an engine pass. The store dispatches
/// these one at a time after every prompt and Log Only record of the pass.
struct AutoStopDueStop: Equatable {
    var rule: AutoStopRule
    var process: AppProcess
    var occurrence: AutoStopOccurrence
    var isRetry: Bool
}

/// The auto-stop engine's memory of each occurrence: one rule matching one
/// process lifetime. Every per-occurrence fact lives in one entry, and every
/// change is one of the transitions below, so a rule edit, a deletion, a moved
/// executable or an exit updates all of it together.
///
/// The ledger decides; the store supplies the facts it cannot know (whether a
/// rule matches a process, how long a process has run, whether an edited rule
/// would still stop a process) and writes the records the transitions return.
struct AutoStopOccurrenceLedger {
    /// What the engine has done for an occurrence.
    enum State: Equatable {
        /// The prompt is queued or on screen, unanswered. `order` keeps the
        /// queue first in, first out, also when a prompt follows its process
        /// to a moved executable.
        case prompting(AutoStopPrompt, order: Int)
        /// Log Only recorded the occurrence.
        case logged
        /// A stop request is running.
        case inFlight(InFlight)
        /// A stop request was accepted, but the process had not exited when it
        /// was last checked.
        case awaitingExit(AwaitingExit)
        /// An automatic stop sent nothing and its failure was recorded. It is
        /// tried again on the next pass, without another record.
        case failedReported
        /// Acted on; nothing more happens until the process ends.
        case settled

        /// Whether the occurrence was acted on, so a pass starts nothing new
        /// for it. A reported failure is retried, so it is not handled.
        var isHandled: Bool {
            self != .failedReported
        }
    }

    /// A stop request whose signal was accepted.
    struct AwaitingExit: Equatable {
        var prompt: AutoStopPrompt
        /// An automatic stop may be re-signalled once, one engine cadence after
        /// its first request was accepted.
        var canRetry: Bool
        /// When the first request was accepted.
        var since: ContinuousClock.Instant
        /// A confirmed stop records one failure if its process still runs one
        /// engine cadence after the request was accepted.
        var reportsStillRunning: Bool

        /// A stop the user confirmed from a prompt. It is never re-signalled,
        /// so it carries no authority, and its exit is tracked as history even
        /// after the rule is edited, switched off or deleted.
        var isConfirmed: Bool { prompt.rule.action == .prompt }
    }

    /// A stop request that has not returned yet.
    struct InFlight: Equatable {
        enum Kind: Equatable {
            /// The first automatic request. `afterReportedFailure` when an
            /// earlier attempt's failure is already in the history.
            case automatic(afterReportedFailure: Bool)
            /// The single re-signal of the accepted request `previous`.
            case retry(previous: AwaitingExit)
            /// A stop the user confirmed from a prompt.
            case confirmed
        }

        var kind: Kind
        /// The rule as captured when the request started, and its target.
        var prompt: AutoStopPrompt
    }

    /// Engine checks in a row on which a rule's CPU and memory conditions held
    /// for an occurrence.
    struct Streak: Equatable {
        var count: Int
        /// The check that last added to `count`.
        var lastCounted: ContinuousClock.Instant

        /// The streak after one more check. A check that fails ends it. One that
        /// comes less than half an engine cadence after the last counted check
        /// (the immediate pass a rule edit starts, say) cannot shorten the
        /// sustained window, so it adds nothing. A gap of more than three
        /// cadences (sleep, or unreadable process lists) means the checks
        /// were not in a row, so the streak starts over.
        static func after(
            _ streak: Streak?,
            holds: Bool,
            at now: ContinuousClock.Instant,
            cadence: Duration
        ) -> Streak? {
            guard holds else { return nil }
            guard let streak else { return Streak(count: 1, lastCounted: now) }
            let gap = streak.lastCounted.duration(to: now)
            if gap > cadence * 3 { return Streak(count: 1, lastCounted: now) }
            guard gap >= cadence / 2 else { return streak }
            return Streak(count: streak.count + 1, lastCounted: now)
        }
    }

    struct Entry: Equatable {
        var state: State?
        /// The user dismissed this occurrence's prompt. Dismiss is the user's
        /// answer rather than engine progress, so it is kept beside the state:
        /// it survives rule edits and enable toggles, it blocks only prompting
        /// (a rule changed to Auto Stop or Log Only still acts), and it ends
        /// with the process or the rule.
        var isDismissed = false
        /// Auto Stop: the process as last observed due under the rule. A rule
        /// edit keeps the occurrence's progress only while the edited rule
        /// would still stop this process. Nil once an edit, a deletion or a
        /// moved executable ended that claim.
        var target: AppProcess?
        /// The checks in a row on which the rule's CPU and memory conditions
        /// held; nil for a rule without them or after a check where they failed.
        var streak: Streak?
    }

    private(set) var entries: [AutoStopOccurrence: Entry] = [:]
    private var nextPromptOrder = 0

    /// Queued prompts, oldest first.
    var prompts: [AutoStopPrompt] {
        entries.values
            .compactMap { entry -> (order: Int, prompt: AutoStopPrompt)? in
                guard case .prompting(let prompt, let order)? = entry.state else { return nil }
                return (order, prompt)
            }
            .sorted { $0.order < $1.order }
            .map(\.prompt)
    }

    /// A confirmed stop is waiting for its process to exit, so the engine
    /// keeps observing even with no enabled rule left.
    var hasConfirmedStopAwaitingExit: Bool {
        entries.values.contains {
            guard case .awaitingExit(let waiting)? = $0.state else { return false }
            return waiting.isConfirmed
        }
    }

    // MARK: - Observation

    /// One engine pass. Identities are followed first: an entry whose process
    /// moved its executable (same PID and start time) moves with it, and an
    /// entry whose process ended is resolved. Only then is every enabled rule
    /// evaluated against the inventory, so a moved occurrence is never acted
    /// on twice.
    ///
    /// Returns the records to write, in order, and the automatic stops that
    /// are due. A stop is marked in flight only when it is dispatched (see
    /// `beginAutomaticStop`), so a pass that ends early leaves the rest to the
    /// next pass.
    mutating func observed(
        inventory processes: [AppProcess],
        rules: [AutoStopRule],
        at now: ContinuousClock.Instant,
        cadence: Duration,
        canLogDurably: Bool,
        matches: (AutoStopRule, AppProcess) -> Bool,
        runtime: (AppProcess) -> TimeInterval?
    ) -> (records: [AutoStopRecord], dueStops: [AutoStopDueStop]) {
        var records = followIdentities(processes, rules: rules, at: now, cadence: cadence, matches: matches)
        let dueStops = evaluate(
            processes,
            rules: rules,
            at: now,
            cadence: cadence,
            canLogDurably: canLogDurably,
            matches: matches,
            runtime: runtime,
            records: &records
        )
        return (records, dueStops)
    }

    private mutating func followIdentities(
        _ processes: [AppProcess],
        rules: [AutoStopRule],
        at now: ContinuousClock.Instant,
        cadence: Duration,
        matches: (AutoStopRule, AppProcess) -> Bool
    ) -> [AutoStopRecord] {
        let running = processes.filter { !$0.hasExited }
        let runningIdentities = Set(running.map(\.identity))
        let currentByPID = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // A different start time on the same PID means the captured lifetime
        // ended and the kernel reused its PID. Only the same lifetime with a
        // moved or unreadable executable is the same occurrence.
        func movedProcess(_ occurrence: AutoStopOccurrence) -> AppProcess? {
            guard let process = currentByPID[occurrence.processIdentity.pid],
                  process.startTime == occurrence.processIdentity.startTime else { return nil }
            return process
        }

        var stillRunning: [(AwaitingExit, AutoStopRecord)] = []
        var exits: [(AwaitingExit, AutoStopRecord)] = []
        var endedPrompts: [(order: Int, record: AutoStopRecord)] = []
        var followed: [AutoStopOccurrence: Entry] = [:]
        func keep(_ entry: Entry, at key: AutoStopOccurrence) {
            guard var existing = followed[key] else {
                followed[key] = entry
                return
            }
            // Two identities of one lifetime cannot both be current, so this
            // merge is defensive: no answer or progress is lost.
            existing.isDismissed = existing.isDismissed || entry.isDismissed
            if existing.state == nil { existing.state = entry.state }
            if existing.target == nil { existing.target = entry.target }
            if existing.streak == nil { existing.streak = entry.streak }
            followed[key] = existing
        }

        for (occurrence, original) in entries {
            var entry = original
            if runningIdentities.contains(occurrence.processIdentity) {
                // A confirmed stop is never re-signalled, but one engine cadence
                // after it was accepted a process that is still running gets
                // one failure record, so the history does not say "waiting"
                // for as long as it runs.
                if case .awaitingExit(var waiting)? = entry.state, waiting.reportsStillRunning,
                   waiting.since.duration(to: now) >= cadence {
                    waiting.reportsStillRunning = false
                    entry.state = .awaitingExit(waiting)
                    stillRunning.append((waiting, AutoStopRecord(
                        prompt: waiting.prompt,
                        outcome: .failed,
                        detail: "Still running after the confirmed stop request. Use Force Stop if it must exit."
                    )))
                }
                keep(entry, at: occurrence)
                continue
            }

            // The observed Auto Stop target is gone, whatever happens below.
            entry.target = nil
            let moved = movedProcess(occurrence)
            let movedKey = moved.map { AutoStopOccurrence(ruleID: occurrence.ruleID, processIdentity: $0.identity) }
            switch entry.state {
            case .prompting(let prompt, let order)?:
                // An unanswered prompt whose process moved its executable stays
                // queued, in its place, under the new identity while its rule
                // still matches the process (a name-only rule). It has neither
                // failed nor ended, so nothing is recorded.
                if let moved, let movedKey,
                   let rule = rules.first(where: { $0.id == occurrence.ruleID }),
                   rule.isEnabled, rule.action == .prompt, matches(rule, moved) {
                    entry.state = .prompting(AutoStopPrompt(id: movedKey, rule: rule, process: moved), order: order)
                } else {
                    entry.state = nil
                    endedPrompts.append((order, moved == nil
                        ? AutoStopRecord(prompt: prompt, outcome: .processEnded,
                                         detail: "Process ended before the prompt was handled.")
                        : AutoStopRecord(prompt: prompt, outcome: .failed,
                                         detail: "Process identity changed before the prompt was handled; nothing was stopped.")))
                }
            case .awaitingExit(let waiting)?:
                // The same lifetime with a moved executable cannot confirm the
                // exit; a stop is not retried after that.
                entry.state = movedKey == nil ? nil : .settled
                exits.append((waiting, moved == nil
                    ? AutoStopRecord(prompt: waiting.prompt, outcome: .stopped,
                                     detail: "Exited after the stop request.")
                    : AutoStopRecord(prompt: waiting.prompt, outcome: .failed,
                                     detail: "Process identity changed; exit could not be confirmed and stopping will not retry.")))
            default:
                // Logged, settled, a reported failure, a dismissal and a stop in
                // flight follow a moved executable and end with the process. A
                // confirmed stop in flight records its own outcome when it returns.
                break
            }
            if let movedKey { keep(entry, at: movedKey) }
        }

        entries = [:]
        for (key, entry) in followed {
            var entry = entry
            // A dismissed occurrence never prompts, also when an identity move
            // brings a dismissal and a prompt together.
            if entry.isDismissed, case .prompting? = entry.state { entry.state = nil }
            put(entry, at: key)
        }

        func exitOrder(_ lhs: (AwaitingExit, AutoStopRecord), _ rhs: (AwaitingExit, AutoStopRecord)) -> Bool {
            if lhs.0.since != rhs.0.since { return lhs.0.since < rhs.0.since }
            return Self.recordOrder(lhs.1, rhs.1)
        }
        return stillRunning.sorted(by: exitOrder).map(\.1)
            + exits.sorted(by: exitOrder).map(\.1)
            + endedPrompts.sorted { $0.order < $1.order }.map(\.record)
    }

    private mutating func evaluate(
        _ processes: [AppProcess],
        rules: [AutoStopRule],
        at now: ContinuousClock.Instant,
        cadence: Duration,
        canLogDurably: Bool,
        matches: (AutoStopRule, AppProcess) -> Bool,
        runtime: (AppProcess) -> TimeInterval?,
        records: inout [AutoStopRecord]
    ) -> [AutoStopDueStop] {
        let activeRules = rules.filter(\.isEnabled)
        var dueStops: [AutoStopDueStop] = []
        for process in processes {
            // A process whose run time cannot be read safely (no kernel start
            // time) is not acted on by any rule, whatever its conditions.
            guard let runtime = runtime(process) else { continue }
            for rule in activeRules where matches(rule, process) {
                let occurrence = AutoStopOccurrence(ruleID: rule.id, processIdentity: process.identity)
                var entry = entries[occurrence] ?? Entry()
                // CPU and memory are counted on every check, also before the
                // run-time floor is reached: the floor is a further condition.
                if rule.hasSampledConditions {
                    entry.streak = Streak.after(
                        entry.streak, holds: rule.sampledConditionsHold(for: process), at: now, cadence: cadence
                    )
                }
                guard rule.runtimeFloorSeconds.map({ runtime >= $0 }) ?? true,
                      rule.action != .prompt || !entry.isDismissed else {
                    put(entry, at: occurrence)
                    continue
                }

                if rule.action == .kill, entry.state != nil { entry.target = process }
                // A queued prompt shows the process as it is now, not as it was
                // when the threshold was first crossed (same occurrence, so an
                // answer still acts on the same process).
                if case .prompting(var prompt, let order)? = entry.state, prompt.process != process {
                    prompt.process = process
                    entry.state = .prompting(prompt, order: order)
                }

                if let state = entry.state, state.isHandled {
                    // Already acted on. The only follow-up is a single re-signal
                    // of an automatic stop whose target has not exited yet; it
                    // belongs to the accepted request, so it does not wait for
                    // the CPU and memory conditions again.
                    if rule.action == .kill, case .awaitingExit(let waiting) = state, waiting.canRetry,
                       waiting.since.duration(to: now) >= cadence {
                        dueStops.append(AutoStopDueStop(rule: rule, process: process, occurrence: occurrence, isRetry: true))
                    }
                    put(entry, at: occurrence)
                    continue
                }
                guard !rule.hasSampledConditions || (entry.streak?.count ?? 0) >= rule.sustainedChecks else {
                    put(entry, at: occurrence)
                    continue
                }

                let prompt = AutoStopPrompt(id: occurrence, rule: rule, process: process)
                switch rule.action {
                case .prompt:
                    entry.state = .prompting(prompt, order: nextPromptOrder)
                    nextPromptOrder += 1
                case .kill:
                    dueStops.append(AutoStopDueStop(rule: rule, process: process, occurrence: occurrence, isRetry: false))
                case .silent:
                    // A Log Only occurrence has not completed until its event is
                    // durably recorded; it is retried once the event log can be
                    // written again.
                    if canLogDurably {
                        entry.state = .logged
                        records.append(AutoStopRecord(
                            prompt: prompt,
                            outcome: .logged,
                            detail: rule.isRuntimeOnly ? "Runtime threshold reached." : "Conditions met.",
                            isDurable: true
                        ))
                    }
                }
                put(entry, at: occurrence)
            }
        }
        return dueStops
    }

    /// Undoes Log Only records whose save failed, so their occurrences are
    /// logged again on a later pass.
    mutating func revertLogged(_ occurrences: [AutoStopOccurrence]) {
        for occurrence in occurrences {
            guard var entry = entries[occurrence], entry.state == .logged else { continue }
            entry.state = nil
            put(entry, at: occurrence)
        }
    }

    // MARK: - Automatic stops

    /// Marks a due stop in flight just before the store dispatches it. False
    /// when the occurrence changed since the pass found it due, so nothing is
    /// sent.
    mutating func beginAutomaticStop(_ stop: AutoStopDueStop) -> Bool {
        var entry = entries[stop.occurrence] ?? Entry()
        let prompt = AutoStopPrompt(id: stop.occurrence, rule: stop.rule, process: stop.process)
        if stop.isRetry {
            guard case .awaitingExit(var previous)? = entry.state, previous.canRetry else { return false }
            previous.canRetry = false
            entry.state = .inFlight(InFlight(kind: .retry(previous: previous), prompt: prompt))
        } else {
            switch entry.state {
            case nil:
                entry.state = .inFlight(InFlight(kind: .automatic(afterReportedFailure: false), prompt: prompt))
            case .failedReported?:
                entry.state = .inFlight(InFlight(kind: .automatic(afterReportedFailure: true), prompt: prompt))
            default:
                return false
            }
        }
        entry.target = stop.process
        put(entry, at: stop.occurrence)
        return true
    }

    /// Resolves a returned automatic stop.
    ///
    /// - Parameters:
    ///   - isAuthorized: the rule captured for the request is still stored
    ///     unchanged and enabled.
    ///   - stillApplies: the rule as stored now would still stop the target.
    ///     Together with an edit that kept the target (see `Entry.target`),
    ///     this keeps the occurrence's budget across still-matching edits.
    ///   - refusalDetail: why the signal was refused, for a `.refused` result.
    mutating func automaticStopFinished(
        _ stop: AutoStopDueStop,
        result: ProcessActionResult,
        isAuthorized: Bool,
        stillApplies: Bool,
        refusalDetail: String,
        at now: ContinuousClock.Instant
    ) -> [AutoStopRecord] {
        var entry = entries[stop.occurrence] ?? Entry()
        let flight: InFlight
        if case .inFlight(let current)? = entry.state, current.kind != .confirmed {
            flight = current
        } else {
            // Not reachable while passes do not overlap. Resolve it as a request
            // whose rule no longer tracks the target.
            let prompt = AutoStopPrompt(id: stop.occurrence, rule: stop.rule, process: stop.process)
            flight = InFlight(
                kind: stop.isRetry
                    ? .retry(previous: AwaitingExit(prompt: prompt, canRetry: false, since: now, reportsStillRunning: false))
                    : .automatic(afterReportedFailure: false),
                prompt: prompt
            )
            entry.target = nil
        }
        let prompt = flight.prompt
        let previous: AwaitingExit?
        if case .retry(let accepted) = flight.kind { previous = accepted } else { previous = nil }
        let afterReportedFailure = flight.kind == .automatic(afterReportedFailure: true)
        let isRetry = previous != nil
        let since = previous?.since ?? now
        let isActive = isAuthorized || (entry.target != nil && stillApplies)
        var records: [AutoStopRecord] = []
        func record(_ outcome: AutoStopEvent.Outcome, _ detail: String) {
            records.append(AutoStopRecord(prompt: prompt, outcome: outcome, detail: detail))
        }
        defer { put(entry, at: stop.occurrence) }

        if result == .rejected, !isAuthorized, isActive {
            // An edit revoked the captured pre-signal authority. Keep an
            // accepted first request's retry, but record nothing for a request
            // that never sent its signal.
            if var waiting = previous {
                waiting.canRetry = true
                waiting.reportsStillRunning = false
                entry.state = .awaitingExit(waiting)
            } else {
                entry.state = afterReportedFailure ? .failedReported : nil
            }
            return records
        }
        if !isActive {
            // A retired rule cannot authorize more work, but a signal already
            // delivered must remain in the history.
            entry.state = nil
            entry.target = nil
            guard result == .stopped || result == .requestedStillRunning else {
                // A retry follows an accepted first request whose record says
                // it is waiting for the exit; the retired rule tracks nothing
                // more, so close that record.
                if isRetry {
                    if result == .stale {
                        record(.stopped, "Exited after the stop request.")
                    } else {
                        record(.stopRequested, Self.untrackedExitDetail)
                    }
                }
                return records
            }
        }

        switch result {
        case .stopped:
            if isActive { entry.state = .settled }
            record(.stopped, isRetry ? "Stopped automatically after a second stop request." : "Stopped automatically.")
        case .identityChanged:
            entry.state = .settled
            record(.failed, "Process identity changed; automatic stopping will not retry.")
        case .stale:
            // The verified identity is gone: the process exited after the
            // engine observed it, or after the first stop request on a retry.
            entry.state = .settled
            if isRetry {
                record(.stopped, "Exited after the stop request.")
            } else {
                record(.processEnded, "Process ended before the automatic stop.")
            }
        case .requestedStillRunning where !isRetry || !isActive:
            if isActive {
                entry.state = .awaitingExit(AwaitingExit(
                    prompt: prompt, canRetry: true, since: since, reportsStillRunning: false
                ))
            }
            record(.stopRequested, isActive
                ? "Stop requested; waiting for the process to exit."
                : "Stop requested; the rule changed or was removed, so automatic stopping will not retry.")
        case .requestedStillRunning:
            // Two stop requests were accepted and the process is still running.
            // Stop retrying so a process that ignores SIGTERM is not signalled
            // on every tick; the user can force stop it. A later exit is still
            // recorded when the identity disappears.
            entry.state = .awaitingExit(AwaitingExit(
                prompt: prompt, canRetry: false, since: since, reportsStillRunning: false
            ))
            record(.failed, "Still running after a second stop request; automatic stopping will not retry. Use Force Stop if it must exit.")
        case .refused:
            // The kernel or a safety guard refused the signal. Retrying every
            // tick cannot succeed, so the occurrence stays handled until it
            // exits.
            entry.state = .settled
            record(.failed, refusalDetail + " Automatic stopping will not retry.")
        case .rejected where isRetry:
            // The re-signal never ran (most often an unreadable process list).
            // Keep the single retry available for the next tick.
            entry.state = .awaitingExit(AwaitingExit(
                prompt: prompt, canRetry: true, since: since, reportsStillRunning: false
            ))
        case .rejected:
            // Nothing was signalled, most often because the process list could
            // not be read. Retry on the next tick instead of abandoning a
            // still-running process, but record the failure only once per
            // occurrence so a persistent fault cannot flood the history.
            entry.state = .failedReported
            if !afterReportedFailure {
                record(.failed, "Automatic stop did not complete.")
            }
        }
        return records
    }

    // MARK: - Prompts

    /// Takes a queued prompt for a confirmed stop. Nil when it is no longer
    /// queued (answered, retired, or its process ended).
    mutating func claimPrompt(_ id: AutoStopOccurrence) -> AutoStopPrompt? {
        guard var entry = entries[id], case .prompting(let prompt, _)? = entry.state else { return nil }
        entry.state = .inFlight(InFlight(kind: .confirmed, prompt: prompt))
        put(entry, at: id)
        return prompt
    }

    /// Resolves a confirmed stop for `prompt`, as claimed with `claimPrompt`.
    mutating func confirmedStopFinished(
        _ prompt: AutoStopPrompt,
        result: ProcessActionResult,
        refusalDetail: String,
        at now: ContinuousClock.Instant
    ) -> AutoStopRecord {
        // The claimed request, also after it followed a moved executable. It
        // is gone when its process ended or its rule was deleted meanwhile.
        let flightKey = entries.first { _, entry in
            guard case .inFlight(let flight)? = entry.state else { return false }
            return flight.kind == .confirmed && flight.prompt.id == prompt.id
        }?.key
        let key = flightKey ?? prompt.id
        var entry = entries[key] ?? Entry()
        let isClaimed = flightKey != nil
        defer { put(entry, at: key) }

        switch result {
        case .stopped:
            if isClaimed { entry.state = .settled }
            return AutoStopRecord(prompt: prompt, outcome: .stopped, detail: "Stopped after confirmation.")
        case .requestedStillRunning:
            // The signal was accepted; the exit is observed on a later tick. A
            // confirmed prompt is never re-signalled automatically.
            entry.state = .awaitingExit(AwaitingExit(
                prompt: prompt, canRetry: false, since: now, reportsStillRunning: true
            ))
            return AutoStopRecord(
                prompt: prompt,
                outcome: .stopRequested,
                detail: "Stop requested after confirmation; waiting for the process to exit."
            )
        case .identityChanged:
            if isClaimed { entry.state = .settled }
            return AutoStopRecord(prompt: prompt, outcome: .failed, detail: "Process identity changed; nothing was stopped.")
        case .stale:
            if isClaimed { entry.state = .settled }
            return AutoStopRecord(prompt: prompt, outcome: .processEnded, detail: "Process ended before the stop request.")
        case .refused:
            if isClaimed { entry.state = .settled }
            return AutoStopRecord(prompt: prompt, outcome: .failed, detail: refusalDetail)
        case .rejected:
            // Nothing was signalled for a reason that may clear (an unreadable
            // process list, a stopped engine). Forget the answer so a
            // still-running occurrence prompts again instead of being silently
            // abandoned.
            entry.state = nil
            return AutoStopRecord(prompt: prompt, outcome: .failed, detail: "Stop request did not complete.")
        }
    }

    /// Dismisses one queued prompt. Nil, and no change, when it is no longer
    /// queued, so a repeated dismissal cannot consume another prompt.
    mutating func dismissPrompt(_ id: AutoStopOccurrence) -> AutoStopRecord? {
        guard var entry = entries[id], case .prompting(let prompt, _)? = entry.state else { return nil }
        entry.state = nil
        entry.isDismissed = true
        put(entry, at: id)
        return AutoStopRecord(
            prompt: prompt,
            outcome: .dismissed,
            detail: "Dismissed; this process occurrence will not prompt again."
        )
    }

    // MARK: - Rule changes

    /// A rule was saved, possibly unchanged, or switched on or off.
    ///
    /// Its prompts are retired and its Log Only records forgotten, so a
    /// still-matching process is prompted or logged again. Dismissals stay. A
    /// confirmed stop stays tracked until its process exits: the user already
    /// answered for that occurrence. Auto Stop progress stays only for targets
    /// the edited rule would still stop (`stillApplies`); an accepted request
    /// that loses its tracking gets a closing record. Checks counted toward
    /// the CPU and memory conditions start over only when those conditions
    /// changed.
    mutating func ruleChanged(
        old: AutoStopRule,
        new: AutoStopRule,
        stillApplies: (AppProcess) -> Bool
    ) -> [AutoStopRecord] {
        assert(old.id == new.id, "A rule change keeps the rule's identity.")
        let sampledConditionsChanged = old.cpuPercentAtLeast != new.cpuPercentAtLeast
            || old.memoryMBAtLeast != new.memoryMBAtLeast
            || old.sustainedChecks != new.sustainedChecks
        var records: [(AwaitingExit, AutoStopRecord)] = []
        for (occurrence, original) in entries where occurrence.ruleID == new.id {
            var entry = original
            if sampledConditionsChanged { entry.streak = nil }
            let isRetained = entry.target.map(stillApplies) ?? false
            if !isRetained { entry.target = nil }
            switch entry.state {
            case .prompting?, .logged?:
                entry.state = nil
            case .inFlight?:
                // A request in flight returns to the ledger, a confirmed one as
                // the user's answer and an automatic one as tracked only while
                // its target was retained.
                break
            case .awaitingExit(let waiting)? where !waiting.isConfirmed && !isRetained:
                entry.state = nil
                if waiting.canRetry {
                    records.append((waiting, Self.untrackedExitRecord(waiting.prompt)))
                }
            case .awaitingExit?:
                break
            case .failedReported?, .settled?:
                if !isRetained { entry.state = nil }
            case nil:
                break
            }
            put(entry, at: occurrence)
        }
        return Self.sorted(records)
    }

    /// A rule was deleted. Everything it held is forgotten, its dismissals too,
    /// except a confirmed stop waiting for its exit, which is history that
    /// needs no rule, and an automatic stop in flight, which records its own
    /// outcome. An accepted Auto Stop that loses its tracking gets a closing
    /// record.
    mutating func ruleRemoved(id: UUID) -> [AutoStopRecord] {
        var records: [(AwaitingExit, AutoStopRecord)] = []
        for (occurrence, original) in entries where occurrence.ruleID == id {
            var entry = original
            entry.isDismissed = false
            entry.target = nil
            entry.streak = nil
            switch entry.state {
            case .awaitingExit(let waiting)? where waiting.isConfirmed:
                break
            case .awaitingExit(let waiting)?:
                entry.state = nil
                if waiting.canRetry {
                    records.append((waiting, Self.untrackedExitRecord(waiting.prompt)))
                }
            case .inFlight(let flight)? where flight.kind != .confirmed:
                break
            default:
                entry.state = nil
            }
            put(entry, at: occurrence)
        }
        return Self.sorted(records)
    }

    static let untrackedExitDetail =
        "The rule changed or was removed before the process exited; its exit will not be tracked."

    /// An accepted Auto Stop whose rule was switched off, deleted, or edited
    /// so that it no longer applies loses its retry and its exit tracking,
    /// because a retired rule has no authority left. This closes its "waiting
    /// for the process to exit" record so the history does not wait forever.
    /// A spent retry already ended with its own failure record, and a retry in
    /// flight records its own outcome.
    private static func untrackedExitRecord(_ prompt: AutoStopPrompt) -> AutoStopRecord {
        AutoStopRecord(prompt: prompt, outcome: .stopRequested, detail: untrackedExitDetail)
    }

    // MARK: - Storage

    /// Stores an entry, dropping it once it holds nothing: no state, no
    /// dismissal and no streak. A target alone is never kept.
    private mutating func put(_ entry: Entry, at key: AutoStopOccurrence) {
        var entry = entry
        if entry.state == nil { entry.target = nil }
        entries[key] = entry.state == nil && !entry.isDismissed && entry.streak == nil ? nil : entry
    }

    private static func sorted(_ records: [(AwaitingExit, AutoStopRecord)]) -> [AutoStopRecord] {
        records.sorted {
            if $0.0.since != $1.0.since { return $0.0.since < $1.0.since }
            return recordOrder($0.1, $1.1)
        }.map(\.1)
    }

    /// A stable order for records made in one step, which reads its entries
    /// from an unordered dictionary.
    private static func recordOrder(_ lhs: AutoStopRecord, _ rhs: AutoStopRecord) -> Bool {
        if lhs.prompt.process.pid != rhs.prompt.process.pid {
            return lhs.prompt.process.pid < rhs.prompt.process.pid
        }
        return lhs.prompt.rule.id.uuidString < rhs.prompt.rule.id.uuidString
    }
}
