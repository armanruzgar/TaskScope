import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-16: rules that test CPU or memory use, each held for a number of engine
/// checks in a row, with run time as an optional floor.
@MainActor
final class AutoStopConditionTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopConditionTests.\(UUID().uuidString)"
    private let path = "/conditions/Example"
    private var instant = ContinuousClock.now

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Stored form and forward safety

    func testARunTimeRuleIsStoredExactlyAsBeforeAndNewConditionsOnlyWhenSet() throws {
        let runtimeOnly = AutoStopRule(processName: "Example", executablePath: path, runtimeMinutes: 5, action: .prompt)
        XCTAssertEqual(try keys(of: runtimeOnly), ["action", "executablePath", "id", "isEnabled", "processName", "runtimeMinutes"])

        let cpuOnly = AutoStopRule(
            processName: "Example", runtimeMinutes: 5, checksRuntime: false, cpuPercentAtLeast: 150, action: .prompt
        )
        XCTAssertEqual(try keys(of: cpuOnly), [
            "action", "checksRuntime", "cpuPercentAtLeast", "id", "isEnabled", "processName", "runtimeMinutes", "sustainedChecks",
        ])
        let memoryAndRuntime = AutoStopRule(
            processName: "Example", runtimeMinutes: 30, memoryMBAtLeast: 8_192, sustainedChecks: 6, action: .silent
        )
        XCTAssertEqual(try keys(of: memoryAndRuntime), [
            "action", "id", "isEnabled", "memoryMBAtLeast", "processName", "runtimeMinutes", "sustainedChecks",
        ])

        for rule in [runtimeOnly, cpuOnly, memoryAndRuntime] {
            let decoded = try JSONDecoder().decode(AutoStopRule.self, from: JSONEncoder().encode(rule))
            XCTAssertEqual(decoded, rule)
            XCTAssertFalse(decoded.hasUnknownFields)
        }
    }

    /// A rule with a CPU or memory condition reaches TaskScope 1.1.0 as a rule
    /// with fields it does not know: it decodes, passes 1.1.0's validation (so
    /// no rule is rejected and nothing enters recovery), and stays disabled and
    /// read-only. A run-time rule reaches 1.1.0 unchanged.
    func testReleaseOneOneZeroKeepsANewConditionRuleDisabledAndReadOnly() throws {
        let newRules = [
            AutoStopRule(processName: "Hot", executablePath: path, runtimeMinutes: 5, checksRuntime: false,
                         cpuPercentAtLeast: 150, action: .kill),
            AutoStopRule(processName: "Big", runtimeMinutes: 30, memoryMBAtLeast: 8_192, action: .prompt),
        ]
        let classic = AutoStopRule(processName: "Old", runtimeMinutes: 5, action: .prompt)
        let payload = try JSONEncoder().encode(newRules + [classic])

        let decoded = try JSONDecoder().decode([Release110Rule].self, from: payload)

        XCTAssertEqual(decoded.map(\.hasUnknownFields), [true, true, false])
        XCTAssertEqual(decoded.map(\.isEnabled), [false, false, true])
        XCTAssertTrue(decoded.allSatisfy(\.passesRelease110Validation), "1.1.0 must keep, not reject, every rule")
        XCTAssertEqual(decoded.map(\.runtimeMinutes), [5, 30, 5], "the run-time field 1.1.0 requires is always written")
    }

    /// The same rule, the other way round: this build keeps a rule from a newer
    /// build disabled and read-only, also when that rule tests only a
    /// condition this build does not know.
    func testThisBuildKeepsARuleWithANewerConditionDisabledAndReadOnly() throws {
        let newer: [[String: Any]] = [[
            "id": UUID().uuidString, "processName": "Disk", "runtimeMinutes": 5, "checksRuntime": false,
            "diskMBPerSecondAtLeast": 50, "action": "prompt", "isEnabled": true,
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: newer), forKey: "rules")
        let store = makeStore()

        XCTAssertEqual(store.rules.count, 1, "a rule this build cannot evaluate is kept, not rejected")
        XCTAssertFalse(store.isRulesReadOnlyAfterRecovery)
        let rule = try XCTUnwrap(store.rules.first)
        XCTAssertTrue(rule.hasUnknownFields)
        XCTAssertFalse(rule.isEnabled)
        XCTAssertFalse(store.setEnabled(true, for: rule))
        XCTAssertEqual(store.validationError, "This rule contains fields from a newer build and is disabled and read-only. Use a build that understands it.")
    }

    // MARK: - Validation

    func testARuleNeedsAConditionAndInRangeValues() {
        func message(_ rule: AutoStopRule) -> String? {
            if case .failure(let failure) = AutoStopRuleValidation.validate(rule) { return failure.message }
            return nil
        }
        let base = AutoStopRule(processName: "Example", runtimeMinutes: 5, checksRuntime: false, action: .prompt)
        XCTAssertEqual(message(base), "Choose at least one condition: run time, CPU, or memory.")

        var cpu = base
        cpu.cpuPercentAtLeast = 0
        XCTAssertEqual(message(cpu), "CPU must be between 1% and 10,000%.")
        cpu.cpuPercentAtLeast = 10_001
        XCTAssertEqual(message(cpu), "CPU must be between 1% and 10,000%.")
        cpu.cpuPercentAtLeast = 10_000
        XCTAssertNil(message(cpu))
        cpu.sustainedChecks = 0
        XCTAssertEqual(message(cpu), "Checks in a row must be between 1 and 360.")
        cpu.sustainedChecks = 361
        XCTAssertEqual(message(cpu), "Checks in a row must be between 1 and 360.")

        var memory = base
        memory.memoryMBAtLeast = 0
        XCTAssertEqual(message(memory), "Memory must be between 1 and 1,048,576 MB.")
        memory.memoryMBAtLeast = 1_048_576
        XCTAssertNil(message(memory))

        // Run time stays a valid number while it is off: 1.1.0 requires it.
        var runtime = cpu
        runtime.sustainedChecks = 3
        runtime.runtimeMinutes = 0
        XCTAssertEqual(message(runtime), "Runtime must be between 1 and 1440 minutes.")
    }

    func testAutoStopStillNeedsATrustedPathWhateverItsConditions() {
        let store = makeStore()
        XCTAssertFalse(store.add(AutoStopRule(
            processName: "Example", runtimeMinutes: 5, checksRuntime: false, cpuPercentAtLeast: 150, action: .kill
        )))
        XCTAssertEqual(store.validationError, "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules.")
        XCTAssertTrue(store.add(AutoStopRule(
            processName: "Example", executablePath: path, runtimeMinutes: 5, checksRuntime: false,
            cpuPercentAtLeast: 150, action: .kill
        )))
    }

    func testAnUnusedCheckCountIsNotKeptOrStored() throws {
        let store = makeStore()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, sustainedChecks: 9, action: .prompt)))
        XCTAssertEqual(store.rules[0].sustainedChecks, AutoStopRule.defaultSustainedChecks)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "rules"))) as? [[String: Any]])
        XCTAssertNil(stored.first?["sustainedChecks"])
    }

    // MARK: - The engine

    func testACPURuleActsAfterItsChecksInARowWithoutARunTimeFloor() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 160, elapsed: "00:30")])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(cpuRule(.prompt)))

        await check(store, at: 0)
        await check(store, at: 10)
        XCTAssertTrue(store.pendingPrompts.isEmpty, "two checks are not three")
        await check(store, at: 20)
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [4101], "a 30-second-old process is prompted: run time is not tested")
    }

    func testACheckBelowTheThresholdStartsTheCountOver() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 160)])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(cpuRule(.prompt)))

        await check(store, at: 0)
        await check(store, at: 10)
        inventory.setProcesses([process(cpu: 149.9)])
        await check(store, at: 20)
        inventory.setProcesses([process(cpu: 160)])
        await check(store, at: 30)
        await check(store, at: 40)
        XCTAssertTrue(store.pendingPrompts.isEmpty)
        await check(store, at: 50)
        XCTAssertEqual(store.pendingPrompts.count, 1)
    }

    /// The immediate pass a rule edit starts must not shorten the sustained
    /// window, and checks with a long gap between them are not in a row.
    func testChecksTooCloseTogetherOrTooFarApartDoNotCountAsInARow() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 160)])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(cpuRule(.prompt)))

        await check(store, at: 0)
        await check(store, at: 1)
        await check(store, at: 10)
        XCTAssertTrue(store.pendingPrompts.isEmpty, "a check one second later adds nothing")
        await check(store, at: 50)
        await check(store, at: 60)
        XCTAssertTrue(store.pendingPrompts.isEmpty, "after a 40-second gap the count starts over")
        await check(store, at: 70)
        XCTAssertEqual(store.pendingPrompts.count, 1)
    }

    func testCPUAndMemoryMustBothHold() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 160, memoryMB: 512)])
        let store = makeStore(inventory: inventory)
        var rule = cpuRule(.prompt)
        rule.memoryMBAtLeast = 1_024
        XCTAssertTrue(store.add(rule))

        for second in stride(from: 0, through: 40, by: 10) { await check(store, at: second) }
        XCTAssertTrue(store.pendingPrompts.isEmpty, "memory never held")

        inventory.setProcesses([process(cpu: 160, memoryMB: 2_048)])
        for second in stride(from: 50, through: 70, by: 10) { await check(store, at: second) }
        XCTAssertEqual(store.pendingPrompts.count, 1)
    }

    /// Run time is a floor beside the sustained conditions: CPU counted before
    /// the floor counts, and the rule acts once both hold.
    func testARunTimeFloorIsAFurtherCondition() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 160, elapsed: "00:20")])
        let store = makeStore(inventory: inventory)
        var rule = cpuRule(.prompt)
        rule.checksRuntime = true
        rule.runtimeMinutes = 1
        XCTAssertTrue(store.add(rule))

        for second in stride(from: 0, through: 30, by: 10) { await check(store, at: second) }
        XCTAssertTrue(store.pendingPrompts.isEmpty, "the one-minute floor is not reached")

        inventory.setProcesses([process(cpu: 160, elapsed: "01:05")])
        await check(store, at: 40)
        XCTAssertEqual(store.pendingPrompts.count, 1, "the CPU checks before the floor counted")
    }

    func testLogOnlyAndHistorySayWhichConditionsMatched() async throws {
        let inventory = ScriptedInventory(processes: [process(memoryMB: 9_000)])
        let store = makeStore(inventory: inventory)
        let rule = AutoStopRule(
            processName: "Example", runtimeMinutes: 5, checksRuntime: false, memoryMBAtLeast: 8_192, action: .silent
        )
        XCTAssertTrue(store.add(rule))
        for second in stride(from: 0, through: 20, by: 10) { await check(store, at: second) }

        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.outcome, .logged)
        XCTAssertEqual(event.detail, "Conditions met.")
        XCTAssertEqual(event.conditions, "Memory ≥ 8,192 MB for 3 checks")
        XCTAssertEqual(makeStore().events.first?.conditions, event.conditions, "the matched conditions are stored with the event")

        // A run-time rule's history is worded as before.
        let runtimeStore = makeStore(inventory: ScriptedInventory(processes: [process()]), key: "other")
        XCTAssertTrue(runtimeStore.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent)))
        await runtimeStore.evaluateNow()
        XCTAssertEqual(runtimeStore.events.first?.detail, "Runtime threshold reached.")
        XCTAssertNil(runtimeStore.events.first?.conditions)
    }

    func testAnAutoStopCPURuleStopsAndItsRetryDoesNotWaitForCPUAgain() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 300)])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(cpuRule(.kill)))
        var stops: [Double] = []
        store.start(cadence: 10) { _, target in
            stops.append(target.cpu)
            return .requestedStillRunning
        }
        store.stop()

        for second in stride(from: 0, through: 20, by: 10) { await check(store, at: second) }
        XCTAssertEqual(stops, [300])
        XCTAssertEqual(store.events.first?.conditions, "CPU ≥ 150% for 3 checks")

        // Shutting down, the process uses little CPU; the one re-signal of the
        // accepted request still follows one cadence later.
        inventory.setProcesses([process(cpu: 2)])
        await check(store, at: 30)
        XCTAssertEqual(stops, [300, 2])
    }

    func testChangingTheCPUConditionStartsTheCountOverButOtherEditsKeepIt() async {
        let inventory = ScriptedInventory(processes: [process(cpu: 300)])
        let store = makeStore(inventory: inventory)
        var rule = cpuRule(.prompt)
        XCTAssertTrue(store.add(rule))
        await check(store, at: 0)
        await check(store, at: 10)

        rule.action = .silent
        XCTAssertTrue(store.update(rule))
        await check(store, at: 20)
        XCTAssertEqual(store.events.map(\.outcome), [.logged], "an action change keeps the checks counted so far")

        rule.cpuPercentAtLeast = 200
        XCTAssertTrue(store.update(rule))
        await check(store, at: 30)
        await check(store, at: 40)
        XCTAssertEqual(store.events.count, 1, "a new CPU value counts from its first check")
        await check(store, at: 50)
        XCTAssertEqual(store.events.map(\.outcome), [.logged, .logged])
    }

    func testThePromptSaysWhichConditionsMatchedWithCurrentValues() {
        var process = process(cpu: 162.4, memoryMB: 9_120.2, elapsed: "1:05:00")
        process.pid = 4242
        let cpu = AutoStopPrompt(id: occurrence(process), rule: cpuRule(.prompt), process: process)
        XCTAssertEqual(
            AutoStopPromptAlert.message(for: cpu),
            "Example (PID 4242) has used at least 150% CPU for 3 checks in a row (now 162% CPU). Stop it now? Dismiss stops reminders for this process until it restarts."
        )

        let all = AutoStopRule(processName: "Example", runtimeMinutes: 30, cpuPercentAtLeast: 150,
                               memoryMBAtLeast: 8_192, sustainedChecks: 1, action: .prompt)
        XCTAssertEqual(
            AutoStopPromptAlert.message(for: AutoStopPrompt(id: occurrence(process), rule: all, process: process)),
            "Example (PID 4242) has run for 1h 5m, beyond the 30-minute rule, and has used at least 150% CPU and 8,192 MB of memory (now 162% CPU and 9,120 MB). Stop it now? Dismiss stops reminders for this process until it restarts."
        )
    }

    func testAStreakCountsChecksInARowAtTheEngineCadence() {
        typealias Streak = AutoStopOccurrenceLedger.Streak
        let start = ContinuousClock.now
        let cadence: Duration = .seconds(10)
        func at(_ seconds: Double) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }

        let first = Streak.after(nil, holds: true, at: at(0), cadence: cadence)
        XCTAssertEqual(first, Streak(count: 1, lastCounted: at(0)))
        XCTAssertNil(Streak.after(first, holds: false, at: at(10), cadence: cadence), "a failed check ends it")
        XCTAssertNil(Streak.after(nil, holds: false, at: at(10), cadence: cadence))
        XCTAssertEqual(Streak.after(first, holds: true, at: at(4.9), cadence: cadence), first,
                       "under half a cadence later adds nothing")
        XCTAssertEqual(Streak.after(first, holds: true, at: at(5), cadence: cadence), Streak(count: 2, lastCounted: at(5)))
        XCTAssertEqual(Streak.after(first, holds: true, at: at(30), cadence: cadence), Streak(count: 2, lastCounted: at(30)))
        XCTAssertEqual(Streak.after(first, holds: true, at: at(30.1), cadence: cadence), Streak(count: 1, lastCounted: at(30.1)),
                       "more than three cadences apart is not in a row")
    }

    // MARK: - Wording

    func testConditionSummaries() {
        XCTAssertEqual(AutoStopRule(processName: "A", runtimeMinutes: 5, action: .prompt).conditionSummary, "After 5 min")
        XCTAssertEqual(cpuRule(.prompt).conditionSummary, "CPU ≥ 150% for 3 checks")
        XCTAssertEqual(
            AutoStopRule(processName: "A", runtimeMinutes: 5, checksRuntime: false, memoryMBAtLeast: 8_192,
                         sustainedChecks: 1, action: .prompt).conditionSummary,
            "Memory ≥ 8,192 MB for 1 check"
        )
        XCTAssertEqual(
            AutoStopRule(processName: "A", runtimeMinutes: 30, cpuPercentAtLeast: 150, memoryMBAtLeast: 8_192,
                         action: .prompt).conditionSummary,
            "After 30 min, CPU ≥ 150% and memory ≥ 8,192 MB for 3 checks"
        )
        XCTAssertEqual(AutoStopSampledConditionFields.spanDescription(checks: 3), "about 30 s")
        XCTAssertEqual(AutoStopSampledConditionFields.spanDescription(checks: 6), "about 1 min")
        XCTAssertEqual(AutoStopSampledConditionFields.spanDescription(checks: 9), "about 1.5 min")
    }

    // MARK: - Editors

    func testTheEditorDraftKeepsSwitchedOffValuesAndAppliesOnlyWhatIsOn() {
        var draft = AutoStopConditionsDraft(rule: AutoStopRule(
            processName: "A", runtimeMinutes: 20, cpuPercentAtLeast: 250, sustainedChecks: 4, action: .prompt
        ))
        XCTAssertTrue(draft.checksCPU)
        XCTAssertFalse(draft.checksMemory)
        draft.checksCPU = false
        draft.checksRuntime = false
        XCTAssertFalse(draft.hasCondition)
        draft.checksCPU = true
        XCTAssertEqual(draft.cpuPercent, 250, "switching CPU back on restores the typed value")

        let applied = draft.applied(to: AutoStopRule(processName: "A", runtimeMinutes: 5, action: .prompt))
        XCTAssertFalse(applied.checksRuntime)
        XCTAssertEqual(applied.runtimeMinutes, 20, "run time keeps its value while off")
        XCTAssertEqual(applied.cpuPercentAtLeast, 250)
        XCTAssertNil(applied.memoryMBAtLeast)
        XCTAssertEqual(applied.sustainedChecks, 4)
    }

    func testTheEditSheetShowsTheConditionsAndSavesThem() throws {
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 20, checksRuntime: false,
                                cpuPercentAtLeast: 250, memoryMBAtLeast: 4_096, sustainedChecks: 4, action: .prompt)
        var saved: AutoStopRule?
        let sheet = AutoStopRuleEditorSheet(rule: rule, onSave: { saved = $0 }, onCancel: {})

        XCTAssertNoThrow(try sheet.inspect().find(RuntimeMinutesControl.self))
        XCTAssertNoThrow(try sheet.inspect().find(AutoStopSampledConditionFields.self))
        for label in ["Check run time", "Check CPU", "Check memory"] {
            XCTAssertNoThrow(try sheet.inspect().find(ViewType.Toggle.self, where: {
                try $0.labelView().text().string() == label
            }), label)
        }
        try sheet.inspect().find(button: "Save").tap()
        XCTAssertEqual(saved, rule)
    }

    func testTheAddRuleSectionTitleSaysWhatIsSetWhileCollapsed() {
        var draft = AutoStopConditionsDraft()
        XCTAssertEqual(SettingsView.moreConditionsTitle(draft), "More conditions")
        draft.checksCPU = true
        draft.cpuPercent = 150
        XCTAssertEqual(SettingsView.moreConditionsTitle(draft), "More conditions: CPU ≥ 150% for 3 checks")
    }

    func testTheQuickSheetKeepsARulesOtherConditions() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 5, checksRuntime: false,
                                cpuPercentAtLeast: 150, sustainedChecks: 6, action: .prompt)
        XCTAssertTrue(store.add(rule))

        let outcome = QuickAutoStopRuleSaver.save(
            into: store, processName: "Example", observedProcessName: "Example", observedExecutablePath: path,
            runtimeMinutes: 9, action: .silent, existingRule: store.rules[0]
        )

        XCTAssertNil(outcome.error)
        XCTAssertEqual(store.rules[0].cpuPercentAtLeast, 150)
        XCTAssertEqual(store.rules[0].sustainedChecks, 6)
        XCTAssertFalse(store.rules[0].checksRuntime)
        XCTAssertEqual(store.rules[0].action, .silent)
        XCTAssertEqual(
            QuickAutoStopRuleSheet.otherConditionsNote(for: store.rules[0]),
            "This rule's conditions: CPU ≥ 150% for 6 checks. Updating keeps them; change them in Settings > Auto-Stop."
        )
        XCTAssertNil(QuickAutoStopRuleSheet.otherConditionsNote(for: AutoStopRule(processName: "A", runtimeMinutes: 5, action: .prompt)))

        // A rule that does not test run time shows no run-time control here.
        let sheet = QuickAutoStopRuleSheet(process: process(), existingRule: store.rules[0],
                                           onSave: { _, _, _ in nil }, onCancel: {})
        XCTAssertThrowsError(try sheet.inspect().find(RuntimeMinutesControl.self))
        XCTAssertNoThrow(try sheet.inspect().find(text: QuickAutoStopRuleSheet.otherConditionsNote(for: store.rules[0]) ?? ""))
    }

    // MARK: - Support

    private func makeStore(inventory: any ProcessInventoryProviding = ScriptedInventory(processes: []), key: String = "rules") -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults, key: key, eventsKey: "\(key).events", inventory: inventory,
            now: { Date(timeIntervalSince1970: 1_000) }, currentUID: getuid(), currentPID: getpid(),
            monotonicNow: { self.instant }
        )
    }

    /// One engine pass, `second` seconds after the test's first check.
    private func check(_ store: AutoStopRulesStore, at second: Int) async {
        instant = origin.advanced(by: .seconds(second))
        await store.evaluateNow()
    }

    private lazy var origin = instant

    private func cpuRule(_ action: AutoStopRule.Action) -> AutoStopRule {
        AutoStopRule(processName: "Example", executablePath: action == .kill ? path : nil, runtimeMinutes: 5,
                     checksRuntime: false, cpuPercentAtLeast: 150, action: action)
    }

    private func process(cpu: Double = 0, memoryMB: Double = 64, elapsed: String = "10:00") -> AppProcess {
        AppProcess.fixture(pid: 4101, parentPID: 1, uid: getuid(), cpu: cpu, memoryMB: memoryMB, command: "Example",
                   executablePath: path, elapsedTime: elapsed, startTime: "start",
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func occurrence(_ process: AppProcess) -> AutoStopOccurrence {
        AutoStopOccurrence(ruleID: UUID(), processIdentity: process.identity)
    }

    private func keys(of rule: AutoStopRule) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any]
        return try XCTUnwrap(object).keys.sorted()
    }
}

/// TaskScope 1.1.0's rule decoding and validation, copied from the v1.1.0 tag
/// (Sources/TaskScope/Models/AutoStopModels.swift and AutoStopRuleValidation.swift),
/// to pin what that release does with rules this build writes.
private struct Release110Rule: Decodable {
    var processName: String
    var executablePath: String?
    var runtimeMinutes: Int
    var action: AutoStopRule.Action
    var isEnabled: Bool
    var hasUnknownFields: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, processName, executablePath, runtimeMinutes, action, isEnabled
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(UUID.self, forKey: .id)
        processName = try container.decode(String.self, forKey: .processName)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        runtimeMinutes = try container.decode(Int.self, forKey: .runtimeMinutes)
        action = try container.decode(AutoStopRule.Action.self, forKey: .action)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let allKeys = try decoder.container(keyedBy: AnyKey.self).allKeys
        hasUnknownFields = !Set(allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue)))
        if hasUnknownFields { isEnabled = false }
    }

    var passesRelease110Validation: Bool {
        let name = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPath, !trimmedPath.isEmpty, !trimmedPath.hasPrefix("/") { return false }
        let hasPath = !(trimmedPath?.isEmpty ?? true)
        return !name.isEmpty
            && (1...1_440).contains(runtimeMinutes)
            && !(action == .kill && isEnabled && !hasPath)
    }
}
