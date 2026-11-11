import XCTest
@testable import TaskScope

/// The occurrence ledger's transition table. Each row drives a fresh ledger to
/// its starting state through the ledger's own operations, applies its events,
/// and checks the state the occurrence ends in and every record the events
/// returned.
final class AutoStopOccurrenceLedgerTests: XCTestCase {
    func testTransitionTable() {
        for row in Self.rows {
            var harness = LedgerHarness()
            harness.reach(row.start)
            harness.clearOutputs()
            for event in row.events { harness.apply(event) }

            let message = "\(row.start) → \(row.events)"
            let key = row.moved ? harness.movedKey : harness.key
            XCTAssertEqual(Self.phase(harness.ledger.entries[key]), row.expect, message, line: row.line)
            if row.moved {
                XCTAssertNil(harness.ledger.entries[harness.key], "the entry follows the moved executable; \(message)", line: row.line)
            }
            XCTAssertEqual(harness.records.map(Self.describe), row.records, message, line: row.line)
            XCTAssertEqual(harness.dueStops.map(\.isRetry), row.due, message, line: row.line)
            if let tracked = row.tracked {
                XCTAssertEqual(harness.ledger.entries[key]?.target != nil, tracked, "target; \(message)", line: row.line)
            }
            XCTAssertEqual(
                harness.ledger.prompts.map(\.id),
                row.expect == .prompting ? [key] : [],
                "the prompt queue holds exactly the prompting occurrences; \(message)",
                line: row.line
            )
        }
    }

    private static let refusal = "Refused for the test."
    private static let untracked = "Stop requested: " + AutoStopOccurrenceLedger.untrackedExitDetail

    private static let rows: [Row] = [
        // Observation while the process keeps running.
        Row(.none, [.observe(action: .prompt)], .prompting),
        Row(.none, [.observe(action: .kill)], .none, due: [false]),
        Row(.none, [.observe(action: .silent)], .logged, records: ["Logged: Runtime threshold reached."]),
        Row(.none, [.observe(action: .silent, canLog: false)], .none),
        Row(.none, [.observe(.young, action: .prompt)], .none),
        Row(.prompting, [.observe()], .prompting),
        Row(.dismissed, [.observe()], .dismissed),
        Row(.dismissed, [.changed(to: .kill), .observe()], .dismissed, due: [false]),
        Row(.dismissed, [.changed(to: .silent), .observe()], .logged, records: ["Logged: Runtime threshold reached."]),
        Row(.logged, [.observe()], .logged),
        Row(.confirmedInFlight, [.observe()], .confirmedInFlight),
        Row(.confirmedAwaitingExit, [.observe()], .awaitingExit(canRetry: false)),
        Row(.confirmedAwaitingExit, [.observe(at: 1), .observe(at: 2)], .awaitingExit(canRetry: false),
            records: ["Failed: Still running after the confirmed stop request. Use Force Stop if it must exit."]),
        Row(.automaticAwaitingExit, [.observe()], .awaitingExit(canRetry: true), tracked: true),
        Row(.automaticAwaitingExit, [.observe(at: 1)], .awaitingExit(canRetry: true), due: [true]),
        Row(.spentRetry, [.observe(at: 3)], .awaitingExit(canRetry: false)),
        Row(.failedReported, [.observe()], .failedReported, due: [false], tracked: true),
        Row(.settled, [.observe()], .settled, tracked: true),

        // The process ended.
        Row(.prompting, [.observe(.ended)], .none, records: ["Ended: Process ended before the prompt was handled."]),
        Row(.prompting, [.observe(.reused)], .none, records: ["Ended: Process ended before the prompt was handled."]),
        Row(.dismissed, [.observe(.ended)], .none),
        Row(.logged, [.observe(.ended)], .none),
        Row(.confirmedInFlight, [.observe(.ended)], .none),
        Row(.confirmedAwaitingExit, [.observe(.ended)], .none, records: ["Stopped: Exited after the stop request."]),
        Row(.automaticAwaitingExit, [.observe(.ended)], .none, records: ["Stopped: Exited after the stop request."]),
        Row(.automaticAwaitingExit, [.observe(.reused)], .none, records: ["Stopped: Exited after the stop request."]),
        Row(.spentRetry, [.observe(.ended)], .none, records: ["Stopped: Exited after the stop request."]),
        Row(.failedReported, [.observe(.ended)], .none),
        Row(.settled, [.observe(.ended)], .none),

        // The process moved its executable within one lifetime.
        Row(.prompting, [.observe(.moved)], .prompting, moved: true),
        Row(.promptingAtPath, [.observe(.moved)], .none,
            records: ["Failed: Process identity changed before the prompt was handled; nothing was stopped."]),
        Row(.dismissed, [.observe(.moved)], .dismissed, moved: true),
        Row(.logged, [.observe(.moved)], .logged, moved: true),
        Row(.confirmedInFlight, [.observe(.moved)], .confirmedInFlight, moved: true),
        Row(.confirmedInFlight, [.observe(.moved), .confirmed(.requestedStillRunning)], .awaitingExit(canRetry: false),
            records: ["Stop requested: Stop requested after confirmation; waiting for the process to exit."], moved: true),
        Row(.confirmedAwaitingExit, [.observe(.moved)], .settled,
            records: ["Failed: Process identity changed; exit could not be confirmed and stopping will not retry."], moved: true),
        Row(.automaticAwaitingExit, [.observe(.moved)], .settled,
            records: ["Failed: Process identity changed; exit could not be confirmed and stopping will not retry."],
            moved: true, tracked: false),
        Row(.failedReported, [.observe(.moved)], .failedReported, moved: true, tracked: false),
        Row(.settled, [.observe(.moved)], .settled, moved: true, tracked: false),

        // A rule saved (unchanged here) or switched off and on.
        Row(.prompting, [.saved(stillApplies: true)], .none),
        Row(.dismissed, [.saved(stillApplies: false)], .dismissed),
        Row(.logged, [.saved(stillApplies: false), .observe()], .logged, records: ["Logged: Runtime threshold reached."]),
        Row(.confirmedInFlight, [.saved(stillApplies: false), .observe()], .confirmedInFlight),
        Row(.confirmedAwaitingExit, [.saved(stillApplies: false), .observe()], .awaitingExit(canRetry: false)),
        Row(.automaticInFlight, [.saved(stillApplies: true)], .automaticInFlight, tracked: true),
        Row(.automaticInFlight, [.saved(stillApplies: false)], .automaticInFlight, tracked: false),
        Row(.automaticAwaitingExit, [.saved(stillApplies: true)], .awaitingExit(canRetry: true), tracked: true),
        Row(.automaticAwaitingExit, [.saved(stillApplies: false)], .none, records: [untracked]),
        Row(.spentRetry, [.saved(stillApplies: false)], .none),
        Row(.failedReported, [.saved(stillApplies: true)], .failedReported, tracked: true),
        Row(.failedReported, [.saved(stillApplies: false)], .none),
        Row(.settled, [.saved(stillApplies: true), .observe()], .settled, tracked: true),
        Row(.settled, [.saved(stillApplies: false), .observe()], .none, due: [false]),

        // A rule deleted.
        Row(.prompting, [.removed], .none),
        Row(.dismissed, [.removed], .none),
        Row(.logged, [.removed], .none),
        Row(.confirmedInFlight, [.removed], .none),
        Row(.confirmedAwaitingExit, [.removed], .awaitingExit(canRetry: false)),
        Row(.automaticInFlight, [.removed], .automaticInFlight, tracked: false),
        Row(.automaticAwaitingExit, [.removed], .none, records: [untracked]),
        Row(.spentRetry, [.removed], .none),
        Row(.failedReported, [.removed], .none),
        Row(.settled, [.removed], .none),

        // Prompt answers.
        Row(.prompting, [.claim], .confirmedInFlight),
        Row(.prompting, [.dismiss], .dismissed,
            records: ["Dismissed: Dismissed; this process occurrence will not prompt again."]),
        Row(.dismissed, [.dismiss, .claim], .dismissed),
        Row(.confirmedInFlight, [.dismiss], .confirmedInFlight),
        Row(.confirmedInFlight, [.confirmed(.stopped)], .settled, records: ["Stopped: Stopped after confirmation."]),
        Row(.confirmedInFlight, [.confirmed(.requestedStillRunning)], .awaitingExit(canRetry: false),
            records: ["Stop requested: Stop requested after confirmation; waiting for the process to exit."]),
        Row(.confirmedInFlight, [.confirmed(.identityChanged)], .settled,
            records: ["Failed: Process identity changed; nothing was stopped."]),
        Row(.confirmedInFlight, [.confirmed(.stale)], .settled, records: ["Ended: Process ended before the stop request."]),
        Row(.confirmedInFlight, [.confirmed(.refused)], .settled, records: ["Failed: \(refusal)"]),
        Row(.confirmedInFlight, [.confirmed(.rejected), .observe()], .prompting,
            records: ["Failed: Stop request did not complete."]),
        Row(.confirmedInFlight, [.observe(.ended), .confirmed(.requestedStillRunning)], .awaitingExit(canRetry: false),
            records: ["Stop requested: Stop requested after confirmation; waiting for the process to exit."]),
        Row(.confirmedInFlight, [.removed, .confirmed(.stopped)], .none, records: ["Stopped: Stopped after confirmation."]),

        // An automatic stop returns while its rule is unchanged.
        Row(.automaticInFlight, [.automatic(.stopped)], .settled, records: ["Stopped: Stopped automatically."]),
        Row(.automaticInFlight, [.automatic(.requestedStillRunning)], .awaitingExit(canRetry: true),
            records: ["Stop requested: Stop requested; waiting for the process to exit."]),
        Row(.automaticInFlight, [.automatic(.identityChanged)], .settled,
            records: ["Failed: Process identity changed; automatic stopping will not retry."]),
        Row(.automaticInFlight, [.automatic(.stale)], .settled, records: ["Ended: Process ended before the automatic stop."]),
        Row(.automaticInFlight, [.automatic(.refused)], .settled,
            records: ["Failed: \(refusal) Automatic stopping will not retry."]),
        Row(.automaticInFlight, [.automatic(.rejected)], .failedReported, records: ["Failed: Automatic stop did not complete."]),
        Row(.failedInFlight, [.automatic(.rejected)], .failedReported),
        Row(.failedInFlight, [.automatic(.stopped)], .settled, records: ["Stopped: Stopped automatically."]),
        Row(.retryInFlight, [.automatic(.stopped)], .settled,
            records: ["Stopped: Stopped automatically after a second stop request."]),
        Row(.retryInFlight, [.automatic(.requestedStillRunning)], .awaitingExit(canRetry: false),
            records: ["Failed: Still running after a second stop request; automatic stopping will not retry. Use Force Stop if it must exit."]),
        Row(.retryInFlight, [.automatic(.stale)], .settled, records: ["Stopped: Exited after the stop request."]),
        Row(.retryInFlight, [.automatic(.rejected)], .awaitingExit(canRetry: true)),

        // An edit that still stops the target revoked the captured authority
        // before the signal: nothing is recorded and the budget is kept.
        Row(.automaticInFlight, [.saved(stillApplies: true), .automatic(.rejected, authorized: false)], .none),
        Row(.failedInFlight, [.saved(stillApplies: true), .automatic(.rejected, authorized: false)], .failedReported),
        Row(.retryInFlight, [.saved(stillApplies: true), .automatic(.rejected, authorized: false)], .awaitingExit(canRetry: true)),
        Row(.automaticInFlight, [.saved(stillApplies: true), .automatic(.requestedStillRunning, authorized: false)],
            .awaitingExit(canRetry: true), records: ["Stop requested: Stop requested; waiting for the process to exit."]),

        // A retired rule: a delivered signal is still recorded, nothing is tracked.
        Row(.automaticInFlight, [.saved(stillApplies: false), .automatic(.stopped, authorized: false, stillApplies: false)],
            .none, records: ["Stopped: Stopped automatically."]),
        Row(.automaticInFlight, [.removed, .automatic(.requestedStillRunning, authorized: false, stillApplies: false)], .none,
            records: ["Stop requested: Stop requested; the rule changed or was removed, so automatic stopping will not retry."]),
        Row(.automaticInFlight, [.removed, .automatic(.refused, authorized: false, stillApplies: false)], .none),
        Row(.automaticInFlight, [.removed, .automatic(.rejected, authorized: false, stillApplies: false)], .none),
        Row(.automaticInFlight, [.saved(stillApplies: false), .automatic(.rejected, authorized: false, stillApplies: true)], .none),
        Row(.retryInFlight, [.removed, .automatic(.stale, authorized: false, stillApplies: false)], .none,
            records: ["Stopped: Exited after the stop request."]),
        Row(.retryInFlight, [.saved(stillApplies: false), .automatic(.rejected, authorized: false, stillApplies: false)], .none,
            records: [untracked]),
        Row(.retryInFlight, [.removed, .automatic(.requestedStillRunning, authorized: false, stillApplies: false)], .none,
            records: ["Stop requested: Stop requested; the rule changed or was removed, so automatic stopping will not retry."]),

        // A Log Only record whose save failed is undone and logged again.
        Row(.logged, [.revertLogged, .observe()], .logged, records: ["Logged: Runtime threshold reached."]),
    ]

    // MARK: - Ordering and bookkeeping

    func testPromptsQueueInOrderAndAMovedPromptKeepsItsPlace() {
        var harness = LedgerHarness()
        let first = harness.process(.running)
        var second = harness.process(.running)
        second.pid = 4343
        harness.observe([first, second], action: .prompt)
        XCTAssertEqual(harness.ledger.prompts.map(\.process.pid), [4242, 4343])

        var moved = first
        moved.executablePath = LedgerHarness.movedPath
        harness.observe([moved, second], action: .prompt)

        XCTAssertEqual(harness.ledger.prompts.map(\.process.pid), [4242, 4343], "the moved prompt keeps its place")
        XCTAssertEqual(harness.ledger.prompts.first?.process.executablePath, LedgerHarness.movedPath)
        XCTAssertTrue(harness.records.isEmpty, "nothing failed or ended")
    }

    func testAQueuedPromptShowsTheProcessAsItIsNow() {
        var harness = LedgerHarness()
        harness.observe(action: .prompt)
        var busier = harness.process(.running)
        busier.cpu = 87
        harness.observe([busier], action: .prompt)
        XCTAssertEqual(harness.ledger.prompts.map(\.process.cpu), [87])
    }

    func testRetryKeepsTheFirstAcceptanceTimeAcrossARejectedReSignal() {
        var harness = LedgerHarness()
        harness.reach(.retryInFlight)
        harness.apply(.automatic(.rejected))
        guard case .awaitingExit(let waiting)? = harness.ledger.entries[harness.key]?.state else {
            return XCTFail("expected an accepted stop")
        }
        XCTAssertEqual(waiting.since, harness.t0, "a re-signal that never ran does not restart the cadence")
        XCTAssertTrue(waiting.canRetry)
    }

    func testOnlyAConfirmedStopAwaitingExitKeepsTheEngineObserving() {
        for (start, expected) in [(Start.confirmedAwaitingExit, true), (.automaticAwaitingExit, false), (.confirmedInFlight, false)] {
            var harness = LedgerHarness()
            harness.reach(start)
            XCTAssertEqual(harness.ledger.hasConfirmedStopAwaitingExit, expected, "\(start)")
        }
    }

    func testADueStopIsDispatchedOnlyWhileItsOccurrenceIsStillUnhandled() {
        var harness = LedgerHarness()
        harness.observe(action: .kill)
        let due = harness.dueStops[0]
        XCTAssertTrue(harness.ledger.beginAutomaticStop(due))
        XCTAssertFalse(harness.ledger.beginAutomaticStop(due), "a stop already in flight is not dispatched twice")

        var retry = due
        retry.isRetry = true
        XCTAssertFalse(harness.ledger.beginAutomaticStop(retry), "only an accepted stop with its retry left is re-signalled")
    }

    func testRecordsOfOnePassAreOrderedStillRunningThenExitsThenEndedPrompts() {
        var harness = LedgerHarness()
        harness.reach(.confirmedAwaitingExit)
        var other = harness.process(.running)
        other.pid = 4343
        harness.observe([harness.process(.running), other], action: .prompt)
        XCTAssertEqual(harness.ledger.prompts.map(\.process.pid), [4343])
        harness.clearOutputs()

        harness.observe([], action: .prompt, at: 1)

        XCTAssertEqual(harness.records.map(Self.describe), [
            "Stopped: Exited after the stop request.",
            "Ended: Process ended before the prompt was handled.",
        ])
    }

    // MARK: - Table support

    private static func describe(_ record: AutoStopRecord) -> String {
        "\(record.outcome.label): \(record.detail)"
    }

    private static func phase(_ entry: AutoStopOccurrenceLedger.Entry?) -> Phase {
        guard let entry else { return .none }
        switch entry.state {
        case nil: return entry.isDismissed ? .dismissed : .none
        case .prompting?: return .prompting
        case .logged?: return .logged
        case .failedReported?: return .failedReported
        case .settled?: return .settled
        case .awaitingExit(let waiting)?: return .awaitingExit(canRetry: waiting.canRetry)
        case .inFlight(let flight)?:
            switch flight.kind {
            case .automatic: return .automaticInFlight
            case .retry: return .retryInFlight
            case .confirmed: return .confirmedInFlight
            }
        }
    }

    fileprivate enum Phase: Equatable {
        case none, dismissed, prompting, logged, failedReported, settled
        case automaticInFlight, retryInFlight, confirmedInFlight
        case awaitingExit(canRetry: Bool)
    }

    private struct Row {
        var start: Start
        var events: [Event]
        var expect: Phase
        var records: [String]
        var due: [Bool]
        var moved: Bool
        var tracked: Bool?
        var line: UInt

        init(
            _ start: Start,
            _ events: [Event],
            _ expect: Phase,
            records: [String] = [],
            due: [Bool] = [],
            moved: Bool = false,
            tracked: Bool? = nil,
            line: UInt = #line
        ) {
            self.start = start
            self.events = events
            self.expect = expect
            self.records = records
            self.due = due
            self.moved = moved
            self.tracked = tracked
            self.line = line
        }
    }
}

fileprivate enum Start: String {
    case none, prompting, promptingAtPath, dismissed, logged
    case confirmedInFlight, confirmedAwaitingExit
    case automaticInFlight, automaticAwaitingExit, retryInFlight, spentRetry
    case failedReported, failedInFlight, settled
}

fileprivate enum ProcessState {
    /// Still running, past the one-minute threshold.
    case running
    /// The same lifetime with its executable at another path.
    case moved
    /// No longer listed.
    case ended
    /// Its PID now belongs to a new, younger process.
    case reused
    /// The same identity, but below the threshold.
    case young
}

fileprivate enum Event: CustomStringConvertible {
    /// One engine pass, `at` engine cadences after the start.
    case observe(ProcessState = .running, action: AutoStopRule.Action? = nil, at: Int = 0, canLog: Bool = true)
    /// The rule saved unchanged; `stillApplies` answers whether it would stop the target.
    case saved(stillApplies: Bool)
    /// The rule's action changed; an Auto Stop target is no longer stopped.
    case changed(to: AutoStopRule.Action)
    case removed
    case claim
    case dismiss
    case confirmed(ProcessActionResult)
    case automatic(ProcessActionResult, authorized: Bool = true, stillApplies: Bool = true)
    case revertLogged

    var description: String {
        switch self {
        case .observe(let state, let action, let at, let canLog):
            "observe(\(state), \(action.map(\.rawValue) ?? "same rule"), +\(at) cadences\(canLog ? "" : ", log unwritable"))"
        case .saved(let stillApplies): "saved(stillApplies: \(stillApplies))"
        case .changed(let action): "changed(to: \(action))"
        case .removed: "removed"
        case .claim: "claim"
        case .dismiss: "dismiss"
        case .confirmed(let result): "confirmed(\(result))"
        case .automatic(let result, let authorized, let stillApplies):
            "automatic(\(result), authorized: \(authorized), stillApplies: \(stillApplies))"
        case .revertLogged: "revertLogged"
        }
    }
}

/// Drives one ledger through its operations, the way the store does, with a
/// matcher that compares names and, for path-bound rules, paths.
fileprivate struct LedgerHarness {
    static let path = "/ledger/Example"
    static let movedPath = "/ledger/moved/Example"
    static let cadence: Duration = .seconds(10)

    let t0 = ContinuousClock.now
    let ruleID = UUID()
    var ledger = AutoStopOccurrenceLedger()
    var records: [AutoStopRecord] = []
    var dueStops: [AutoStopDueStop] = []
    var action: AutoStopRule.Action = .prompt
    var isPathBound = false
    private var inFlight: AutoStopDueStop?
    private var claimed: AutoStopPrompt?
    private var refusal = "Refused for the test."

    var key: AutoStopOccurrence {
        AutoStopOccurrence(ruleID: ruleID, processIdentity: process(.running).identity)
    }

    var movedKey: AutoStopOccurrence {
        AutoStopOccurrence(ruleID: ruleID, processIdentity: process(.moved).identity)
    }

    func rule(_ action: AutoStopRule.Action? = nil) -> AutoStopRule {
        let action = action ?? self.action
        return AutoStopRule(
            id: ruleID,
            processName: "Example",
            executablePath: action == .kill || isPathBound ? Self.path : nil,
            runtimeMinutes: 1,
            action: action
        )
    }

    func process(_ state: ProcessState) -> AppProcess {
        AppProcess.fixture(
            pid: 4242,
            parentPID: 1,
            uid: 501,
            cpu: 12,
            memoryMB: 64,
            command: "Example",
            executablePath: state == .moved ? Self.movedPath : Self.path,
            elapsedTime: state == .reused || state == .young ? "00:30" : "10:00",
            startTime: state == .reused ? "later" : "start",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    mutating func clearOutputs() {
        records = []
        dueStops = []
    }

    mutating func observe(
        _ processes: [AppProcess]? = nil,
        action: AutoStopRule.Action? = nil,
        at cadences: Int = 0,
        canLog: Bool = true
    ) {
        if let action { self.action = action }
        let pass = ledger.observed(
            inventory: processes ?? [process(.running)],
            rules: [rule()],
            at: t0.advanced(by: Self.cadence * cadences),
            cadence: Self.cadence,
            canLogDurably: canLog,
            matches: { rule, process in
                rule.processName.caseInsensitiveCompare(process.name) == .orderedSame
                    && (rule.executablePath == nil || rule.executablePath == process.executablePath)
            },
            runtime: { $0.runtimeSeconds }
        )
        records += pass.records
        dueStops += pass.dueStops
    }

    mutating func reach(_ start: Start) {
        switch start {
        case .none:
            break
        case .prompting:
            observe(action: .prompt)
        case .promptingAtPath:
            isPathBound = true
            observe(action: .prompt)
        case .dismissed:
            reach(.prompting)
            apply(.dismiss)
        case .logged:
            observe(action: .silent)
        case .confirmedInFlight:
            reach(.prompting)
            apply(.claim)
        case .confirmedAwaitingExit:
            reach(.confirmedInFlight)
            apply(.confirmed(.requestedStillRunning))
        case .automaticInFlight:
            observe(action: .kill)
            begin()
        case .automaticAwaitingExit:
            reach(.automaticInFlight)
            apply(.automatic(.requestedStillRunning))
        case .retryInFlight:
            reach(.automaticAwaitingExit)
            observe(at: 1)
            begin()
        case .spentRetry:
            reach(.retryInFlight)
            apply(.automatic(.requestedStillRunning))
        case .failedReported:
            reach(.automaticInFlight)
            apply(.automatic(.rejected))
        case .failedInFlight:
            reach(.failedReported)
            observe()
            begin()
        case .settled:
            reach(.automaticInFlight)
            apply(.automatic(.stopped))
        }
    }

    private mutating func begin() {
        guard let due = dueStops.last, ledger.beginAutomaticStop(due) else {
            return XCTFail("expected a due automatic stop to dispatch")
        }
        inFlight = due
        dueStops = []
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .observe(let state, let action, let at, let canLog):
            let processes: [AppProcess] = switch state {
            case .ended: []
            default: [process(state)]
            }
            observe(processes, action: action, at: at, canLog: canLog)
        case .saved(let stillApplies):
            records += ledger.ruleChanged(old: rule(), new: rule()) { _ in stillApplies }
        case .changed(let newAction):
            let old = rule()
            action = newAction
            records += ledger.ruleChanged(old: old, new: rule()) { _ in false }
        case .removed:
            records += ledger.ruleRemoved(id: ruleID)
        case .claim:
            if let prompt = ledger.claimPrompt(key) { claimed = prompt }
        case .dismiss:
            if let record = ledger.dismissPrompt(key) { records.append(record) }
        case .confirmed(let result):
            guard let claimed else { return XCTFail("no claimed prompt to finish") }
            records.append(ledger.confirmedStopFinished(claimed, result: result, refusalDetail: refusal, at: t0))
        case .automatic(let result, let authorized, let stillApplies):
            guard let inFlight else { return XCTFail("no automatic stop in flight") }
            records += ledger.automaticStopFinished(
                inFlight,
                result: result,
                isAuthorized: authorized,
                stillApplies: stillApplies,
                refusalDetail: refusal,
                at: t0
            )
        case .revertLogged:
            ledger.revertLogged([key])
        }
    }
}
