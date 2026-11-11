import XCTest
@testable import TaskScope

@MainActor
final class PersistenceForwardCompatibilityTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.PersistenceForwardCompatibilityTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUnknownRuleFieldsDisableEnforcementAndMutationWithoutLosingStoredAuthority() async throws {
        for action in AutoStopRule.Action.allCases {
            let rule = AutoStopRule(processName: "Example", executablePath: "/test/Example", runtimeMinutes: 1, action: action)
            var raw = try object(rule)
            raw["futureScope"] = ["uid": 123]
            try seed([raw], key: "rules")
            let store = makeRulesStore()
            let loaded = try XCTUnwrap(store.rules.first)
            XCTAssertTrue(loaded.hasUnknownFields)
            XCTAssertFalse(loaded.isEnabled)
            var callbacks = 0
            store.start { _, _ in
                callbacks += 1
                return .stopped
            }
            store.stop()
            await store.evaluateNow()
            XCTAssertEqual(callbacks, 0)
            XCTAssertTrue(store.pendingPrompts.isEmpty)
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertFalse(store.authorizes(rule, kind: .automatic))
            XCTAssertFalse(store.authorizes(rule, kind: .confirmedPrompt))
            XCTAssertFalse(store.setEnabled(true, for: loaded))
            XCTAssertFalse(store.update(rule), "a fabricated known-only copy must not remove the unknown restriction")
            XCTAssertFalse(store.duplicate(loaded))
            XCTAssertFalse(store.remove(loaded))
            XCTAssertFalse(store.remove(at: IndexSet(integer: 0)))

            XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .silent)))
            let saved = try rows("rules")
            XCTAssertEqual(saved[0] as NSDictionary, raw as NSDictionary)
            XCTAssertFalse(makeRulesStore().rules[0].isEnabled)
        }
    }

    func testKnownRulesRemainEditableAlongsideUnknownRulesAndCanRemoveOptionalPaths() async throws {
        var future = try object(AutoStopRule(processName: "Future", runtimeMinutes: 1, action: .silent))
        future["futureFlag"] = NSNull()
        let known = AutoStopRule(processName: "Example", executablePath: "/test/Example", runtimeMinutes: 1, action: .silent)
        try seed([future, object(known)], key: "rules")
        let store = makeRulesStore()
        var updated = known
        updated.executablePath = nil
        XCTAssertTrue(store.update(updated))
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.logged])
        let saved = try rows("rules")
        XCTAssertEqual(saved[0] as NSDictionary, future as NSDictionary)
        XCTAssertNil(saved[1]["executablePath"])
        XCTAssertTrue(store.remove(updated))
        XCTAssertEqual(try rows("rules").count, 1)
    }

    func testEventTrimAndAppendPreserveUnknownFieldsAndNonStringOutcomes() async throws {
        let outcomes: [Any] = [["kind": "future", "code": 7], NSNull(), 42, "futureString"]
        var originals: [[String: Any]] = []
        for outcome in outcomes {
            var event = try object(AutoStopEvent(timestamp: Date(), processName: "Example", pid: 42, ruleID: UUID(), outcome: .logged, detail: "future"))
            event["outcome"] = outcome
            event["futureDetail"] = ["nested": [true, false]]
            originals.append(event)
        }
        try seed(originals, key: "events")
        let store = makeRulesStore(eventLimit: 3)
        XCTAssertEqual(try rows("events") as NSArray, Array(originals.prefix(3)) as NSArray)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent)))
        await store.evaluateNow()
        let saved = try rows("events")
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved[0]["outcome"] as? String, "logged")
        XCTAssertEqual(Array(saved.dropFirst()) as NSArray, Array(originals.prefix(2)) as NSArray)
    }

    /// A preset with a newer build's fields is read-only in this build: those
    /// fields may narrow what it is allowed to do. Load normalization, reordering
    /// and removing another preset still keep every unknown preset and job field.
    func testPresetNormalizationAndReorderingPreserveUnknownFieldsAndEditsAreRefused() throws {
        let first = WatchedAppPreset(displayName: " First ", mainProcessName: "First", helperProcessNames: ["First", "Helper"], protectedProcessNames: [], appPath: "/test/First.app", userLaunchAgentJobs: [
            UserLaunchAgentJob(label: "one", plistPath: "/tmp/one.plist"),
            UserLaunchAgentJob(label: "two", plistPath: "/tmp/two.plist")
        ])
        var raw = try object(first)
        raw["futurePreset"] = ["color": "blue"]
        var jobs = try XCTUnwrap(raw["userLaunchAgentJobs"] as? [[String: Any]])
        jobs[0]["futureJob"] = ["scope": "one"]
        jobs[1]["futureJob"] = ["scope": "two"]
        raw["userLaunchAgentJobs"] = jobs
        let second = WatchedAppPreset(displayName: "Second", mainProcessName: "Second", helperProcessNames: [], protectedProcessNames: [], appPath: "/test/Second.app")
        try seed([raw, object(second)], key: "presets")
        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        var saved = try rows("presets")
        XCTAssertEqual(saved[0]["displayName"] as? String, "First")
        XCTAssertEqual(saved[0]["helperProcessNames"] as? [String], ["Helper"])
        XCTAssertEqual(saved[0]["futurePreset"] as? NSDictionary, raw["futurePreset"] as? NSDictionary)
        XCTAssertEqual(saved[0]["userLaunchAgentJobs"] as? NSArray, jobs as NSArray)
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.presets[0].hasUnknownFields)
        XCTAssertFalse(store.presets[1].hasUnknownFields)
        var edited = store.presets[0]
        edited.notificationsEnabled = false
        edited.userLaunchAgentJobs.reverse()
        XCTAssertFalse(store.update(edited))
        XCTAssertEqual(store.validationError, WatchedAppsStore.newerBuildMessage)
        XCTAssertTrue(store.move(from: IndexSet(integer: 0), to: 2))
        saved = try rows("presets")
        XCTAssertEqual(saved[1]["futurePreset"] as? NSDictionary, raw["futurePreset"] as? NSDictionary)
        XCTAssertEqual(saved[1]["userLaunchAgentJobs"] as? NSArray, jobs as NSArray)
        XCTAssertEqual(saved[1]["notificationsEnabled"] as? Bool, true)
        XCTAssertTrue(store.remove(second))
        XCTAssertEqual(try rows("presets")[0]["futurePreset"] as? NSDictionary, raw["futurePreset"] as? NSDictionary)
    }

    func testSelectionRenamePreservesUnknownSelectionAndProcessFields() throws {
        let selection = SavedSelectionsStore.SavedSelection(name: "Workers", pids: [42], processes: [.init(process: process)])
        var raw = try object(selection)
        raw["futureSelection"] = ["value": 1]
        var processes = try XCTUnwrap(raw["processes"] as? [[String: Any]])
        processes[0]["futureProcess"] = ["arguments": ["one", "two"]]
        raw["processes"] = processes
        try seed([raw], key: "selections")
        let store = SavedSelectionsStore(userDefaults: defaults, key: "selections")
        XCTAssertTrue(store.rename(store.selections[0], to: "Renamed"))
        XCTAssertTrue(store.save(name: "Other", processes: [process]))
        let saved = try rows("selections")
        raw["name"] = "Renamed"
        XCTAssertEqual(saved[0] as NSDictionary, raw as NSDictionary)
    }

    func testLegacyMissingIDsAndRejectedElementsKeepUnknownFieldsWithTheirEntry() throws {
        let future: [String: Any] = ["processName": "Future", "runtimeMinutes": 1, "action": "silent", "futureScope": ["uid": 123]]
        try seed([["processName": false], future], key: "rules")
        let store = makeRulesStore()
        XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertTrue(store.rules[0].hasUnknownFields)
        store.resetRulesAfterCorruption()
        XCTAssertEqual(try rows("rules") as NSArray, [future] as NSArray)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt)))
        XCTAssertEqual(try rows("rules")[0] as NSDictionary, future as NSDictionary)
    }

    private var process: AppProcess {
        AppProcess(pid: 42, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: "Example", executablePath: "/test/Example", elapsedTime: "10:00", startTime: "start-42", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func makeRulesStore(eventLimit: Int = 200) -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events", inventory: ForwardCompatibilityInventory(processes: [process]), eventLimit: eventLimit)
    }

    private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func seed(_ objects: [[String: Any]], key: String) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: objects), forKey: key)
    }

    private func rows(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [[String: Any]])
    }
}

private struct ForwardCompatibilityInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
