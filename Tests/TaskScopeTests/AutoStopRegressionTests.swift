import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class AutoStopRegressionTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!
    private var monotonicInstant = ContinuousClock.now
    private var wallDate = Date(timeIntervalSince1970: 1_000)
    private let path = "/Applications/Example.app/Contents/MacOS/Example"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.AutoStop.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEveryActionExcludesOtherUsersUnknownOwnersAndSelf() async {
        let targets = [process(pid: 41), process(pid: 42, uid: getuid() + 1),
                       process(pid: 43, uid: nil), process(pid: getpid()), process(pid: 1)]
        for action in AutoStopRule.Action.allCases {
            defaults.removePersistentDomain(forName: suiteName)
            let store = makeStore(processes: targets)
            XCTAssertTrue(store.add(rule(action: action)))
            var attempts: [Int32] = []
            store.start { _, target in attempts.append(target.pid); return .stopped }
            store.stop()
            await store.evaluateNow()
            XCTAssertEqual(attempts, action == .kill ? [41] : [], action.rawValue)
            XCTAssertEqual(store.pendingPrompts.map(\.process.pid), action == .prompt ? [41] : [], action.rawValue)
            XCTAssertEqual(store.events.map(\.pid), action == .prompt ? [] : [41], action.rawValue)
        }
    }

    func testSinglePassUsesTheSameOwnerAndSelfScope() async {
        let store = makeStore(processes: [process(pid: 41), process(pid: 42, uid: nil),
                                          process(pid: 43, uid: getuid() + 1), process(pid: getpid())])
        XCTAssertTrue(store.add(rule(action: .prompt)))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41])
    }

    func testUnrelatedRuleEditDoesNotAccelerateAcceptedStopRetry() async {
        let store = makeStore(processes: [process(pid: 41)])
        XCTAssertTrue(store.add(rule()))
        var attempts = 0
        store.start(cadence: 3_600) { _, _ in attempts += 1; return .requestedStillRunning }
        await waitUntil { store.events.count == 1 }
        XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .silent)))
        await store.evaluateNow()
        await drainTasks()
        store.stop()
        XCTAssertEqual(attempts, 1, "An immediate evaluation must not shorten the retry interval")
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])
        wallDate = wallDate.addingTimeInterval(86_400)
        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_599))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 1, "Wall-clock changes and early evaluations do not authorize a retry")
        monotonicInstant = monotonicInstant.advanced(by: .seconds(1))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2, "Exactly one retry is available after the cadence elapses")
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2)
    }

    func testStillMatchingEditDuringAcceptedStopKeepsItsOccurrenceBudget() async {
        let store = makeStore(processes: [process(pid: 41)])
        XCTAssertTrue(store.add(rule()))
        var attempts = 0
        store.start(cadence: 3_600) { captured, _ in
            attempts += 1
            if attempts == 1 {
                var edited = captured
                edited.runtimeMinutes = 2
                XCTAssertTrue(store.update(edited))
                // Forces the replacement poll into evaluateNow's queued-pass path.
                await store.evaluateNow()
            }
            return .requestedStillRunning
        }
        await waitUntil { !store.events.isEmpty }
        await drainTasks()
        await store.evaluateNow()
        store.stop()
        XCTAssertEqual(attempts, 1, "An in-flight matching edit must retain the first accepted request")
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])
        XCTAssertEqual(store.events.first?.detail, "Stop requested; waiting for the process to exit.")
        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_600))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2)
        var edited = store.rules[0]
        edited.runtimeMinutes = 3
        XCTAssertTrue(store.update(edited))
        monotonicInstant = monotonicInstant.advanced(by: .seconds(3_600))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2, "A later matching edit cannot replenish the spent retry")
        XCTAssertEqual(store.events.map(\.outcome), [.failed, .stopRequested])
    }

    func testMixedEventPayloadKeepsValidEventsReadOnlyUntilReset() throws {
        let valid = AutoStopEvent(timestamp: Date(timeIntervalSince1970: 1_000), processName: "Example",
                                  pid: 41, ruleID: UUID(), outcome: .logged, detail: "Retained")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        json["futureMetadata"] = ["version": 2]
        let payload = try JSONSerialization.data(withJSONObject: [NSNull(), json, ["id": "invalid"], ["timestamp": "tomorrow"]])
        defaults.set(payload, forKey: "events")
        let store = makeStore()
        XCTAssertEqual(store.events, [valid])
        XCTAssertTrue(store.isEventsReadOnlyAfterRecovery)
        XCTAssertTrue(store.eventsRecoveryMessage?.contains("Rejected 3") == true)
        XCTAssertEqual(defaults.data(forKey: "events.rejectedMigrationBackup"), payload)
        XCTAssertFalse(store.clearEvents())
        XCTAssertEqual(defaults.data(forKey: "events"), payload)
        store.resetEventsAfterCorruption()
        XCTAssertFalse(store.isEventsReadOnlyAfterRecovery)
        XCTAssertEqual(makeStore().events, [valid])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "events"))) as? [[String: Any]])
        XCTAssertNotNil(saved.first?["futureMetadata"])
        XCTAssertEqual(defaults.data(forKey: "events.rejectedMigrationBackup"), payload)
    }

    func testQuickSheetDisclosesEnablingAnyDisabledNameOnlyAutoStopRule() throws {
        let store = makeStore()
        let parked = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .kill, isEnabled: false)
        XCTAssertTrue(store.add(parked))
        let target = process(pid: 41)
        var status: String?
        let sheet = QuickAutoStopRuleSheet(process: target, existingRule: parked, onSave: { name, minutes, action in
            let result = QuickAutoStopRuleSaver.save(into: store, processName: name, observedProcessName: target.name,
                observedExecutablePath: target.executablePath, runtimeMinutes: minutes, action: action, existingRule: parked)
            status = result.statusMessage
            return result.error
        }, onCancel: {})
        XCTAssertNoThrow(try sheet.inspect().find(text: "Saving enables this Auto Stop rule."))
        try sheet.inspect().find(button: "Update Rule").tap()
        XCTAssertTrue(store.rules[0].isEnabled)
        XCTAssertEqual(status, "Enabled auto-stop rule for Example.")
    }

    func testWatchThisProcessRejectsUnmatchableMainProcesses() throws {
        var missingPath = process(pid: 41)
        missingPath.executablePath = nil
        for target in [missingPath,
            process(pid: 41, path: "/usr/bin/Example"),
            process(pid: 41, path: "/Applications/Example.app/Contents/Helpers/Example"),
            process(pid: 41, path: "/Applications/Example.app/Contents/PlugIns/Widget.appex/Contents/MacOS/Example"),
            process(pid: 41, path: "/Applications/Example.app/Contents/XPCServices/Worker.xpc/Contents/MacOS/Example"),
            process(pid: 41, uid: getuid() + 1), process(pid: 41, uid: nil), process(pid: getpid())
        ] {
            let form = QuickWatchedPresetFormState(displayName: "Example", mainProcessName: "Example", helperNames: "",
                appPath: QuickWatchedPresetSheet.inferredAppPath(for: target, fallbackName: target.name))
            var saves = 0
            let sheet = QuickWatchedPresetSheet(draft: QuickWatchedPresetDraft(processes: [target]),
                onSave: { _ in saves += 1; return nil }, onCancel: {}, form: form)
            try sheet.inspect().find(button: "Add Preset").tap()
            XCTAssertEqual(saves, 0, target.executablePath ?? "missing path")
            XCTAssertNotNil(form.validationError)
            if target.executablePath == "/usr/bin/Example" {
                XCTAssertEqual(form.appPath, "", "Never fabricate a bundle for a non-bundled executable")
            }
        }
    }

    func testSaveSelectionRejectsHelpersOutsideTheBundleOrUser() throws {
        for helper in [process(pid: 42, path: "/Applications/Other.app/Contents/Helpers/Helper"),
                       process(pid: 42, uid: nil, path: "/Applications/Example.app/Contents/Helpers/Helper"),
                       process(pid: 42, uid: getuid() + 1, path: "/Applications/Example.app/Contents/Helpers/Helper")] {
            let form = QuickWatchedPresetFormState(displayName: "Example", mainProcessName: "Example", helperNames: "Helper",
                appPath: "/Applications/Example.app")
            var saves = 0
            let sheet = QuickWatchedPresetSheet(draft: QuickWatchedPresetDraft(processes: [process(pid: 41), helper]),
                onSave: { _ in saves += 1; return nil }, onCancel: {}, form: form)
            try sheet.inspect().find(button: "Add Preset").tap()
            XCTAssertEqual(saves, 0)
            XCTAssertNotNil(form.validationError)
        }
    }

    func testSaveSelectionAcceptsMainAndHelpersThatThePresetCanObserve() throws {
        let targets = [process(pid: 41), process(pid: 42, path: "/Applications/Example.app/Contents/Helpers/Helper")]
        var saved: WatchedAppPreset?
        let sheet = QuickWatchedPresetSheet(draft: QuickWatchedPresetDraft(processes: targets),
            onSave: { saved = $0; return nil }, onCancel: {})
        try sheet.inspect().find(button: "Add Preset").tap()
        let preset = try XCTUnwrap(saved)
        let snapshot = WatchedSnapshotBuilder(excludedPID: getpid()).snapshot(for: preset, in: targets)
        XCTAssertEqual(snapshot.mainProcessPIDs, [41])
        XCTAssertEqual(snapshot.runningNames, ["Example", "Helper"])
    }

    func testInjectedOwnerAndSelfScopeAreUsed() async {
        let store = AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events",
            inventory: RegressionInventory(processes: [process(pid: 41, uid: 1234), process(pid: 42, uid: 1234), process(pid: 43, uid: 5678)]),
            currentUID: 1234, currentPID: 42)
        XCTAssertTrue(store.add(rule(action: .prompt)))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41])
    }

    func testRefusedPromptUsesTheSpecificSafetyGuardDetail() async {
        let store = makeStore()
        store.start { _, _ in .refused }
        store.stop()
        let promptRule = rule(action: .prompt)
        for (target, detail) in [
            (process(pid: getpid()), "TaskScope cannot stop itself; use Quit to close TaskScope."),
            (process(pid: 1), "This PID cannot be signalled."),
            (process(pid: 41, uid: nil), "The process is not owned by the current user.")
        ] {
            let prompt = AutoStopPrompt(id: AutoStopOccurrence(ruleID: promptRule.id, processIdentity: target.identity),
                rule: promptRule, process: target)
            await store.finishStop(prompt)
            XCTAssertEqual(store.events.first?.detail, detail)
        }
    }

    private func makeStore(processes: [AppProcess] = []) -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events", inventory: RegressionInventory(processes: processes),
            now: { self.wallDate }, monotonicNow: { self.monotonicInstant })
    }

    private func rule(action: AutoStopRule.Action = .kill) -> AutoStopRule {
        AutoStopRule(processName: "Example", executablePath: path, runtimeMinutes: 1, action: action)
    }

    private func process(pid: Int32, uid: uid_t? = getuid(), path: String? = nil) -> AppProcess {
        let executable = path ?? self.path
        return AppProcess(pid: pid, parentPID: 1, uid: uid, cpu: 1, memoryMB: 1, command: executable,
            executablePath: executable, elapsedTime: "10:00", startTime: "start-\(pid)", netInKB: nil,
            netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }

    private func drainTasks() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private struct RegressionInventory: ProcessInventoryProviding {
    let processes: [AppProcess]
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> { .success(processes) }
}
