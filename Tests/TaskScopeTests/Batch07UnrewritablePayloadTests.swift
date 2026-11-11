import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

// MARK: - Readable payloads that cannot be written back (A11-9)

@MainActor
final class Batch07UnrewritablePayloadTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07UnrewritablePayloadTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSettingsApplyReadOnlyWhenAnUnknownFieldCannotBeParsedBack() throws {
        let key = "batch07-settings"
        let payload = Data(#"{"schemaVersion":3,"refreshIntervalSeconds":22,"keepGlobalProtectOff":true,"futureLimit":1e400}"#.utf8)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: payload), "precondition: the raw snapshot cannot hold this payload")
        defaults.set(payload, forKey: key)

        let store = SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
        XCTAssertEqual(store.refreshIntervalSeconds, 22)
        XCTAssertTrue(store.keepGlobalProtectOff)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("\(key).corruptBackup") == true, store.recoveryMessage ?? "")
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), payload)
        store.processListLimit = 50
        XCTAssertEqual(defaults.data(forKey: key), payload)

        store.resetAfterCorruption()
        let reloaded = SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 22)
        XCTAssertEqual(reloaded.processListLimit, 50)
    }

    func testSavedSelectionsPresetsAndRulesApplyReadOnlyWhenAnUnknownFieldCannotBeParsedBack() throws {
        let selections = Data(#"[{"id":"00000000-0000-0000-0000-00000000B007","name":"Workers","pids":[42],"processes":[{"pid":42,"command":"node","executablePath":"/Batch07/bin/node","executableName":"node"}],"future":1e400}]"#.utf8)
        let presets = Data(#"[{"displayName":"Example","mainProcessName":"Example","appPath":"/Batch07Apps/Example.app","future":1e400}]"#.utf8)
        let rules = Data(#"[{"id":"00000000-0000-0000-0000-00000000B008","processName":"Example","runtimeMinutes":5,"action":"silent","future":1e400}]"#.utf8)
        for payload in [selections, presets, rules] {
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: payload))
        }
        defaults.set(selections, forKey: "selections")
        defaults.set(presets, forKey: "presets")
        defaults.set(rules, forKey: "rules")

        let selectionStore = SavedSelectionsStore(userDefaults: defaults, key: "selections")
        XCTAssertEqual(selectionStore.selections.map(\.name), ["Workers"])
        XCTAssertTrue(selectionStore.isReadOnlyAfterCorruption)
        XCTAssertTrue(selectionStore.recoveryMessage?.contains("were read") == true, selectionStore.recoveryMessage ?? "")
        XCTAssertFalse(selectionStore.rename(try XCTUnwrap(selectionStore.selections.first), to: "Renamed"))
        XCTAssertEqual(defaults.data(forKey: "selections"), selections)
        XCTAssertEqual(defaults.data(forKey: "selections.corruptBackup"), selections)

        let presetStore = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertEqual(presetStore.presets.map(\.displayName), ["Example"])
        XCTAssertTrue(presetStore.isReadOnlyAfterCorruption)
        XCTAssertTrue(presetStore.canExportPresets)
        XCTAssertTrue(presetStore.persistenceIssue?.contains("presets.corruptBackup") == true, presetStore.persistenceIssue ?? "")
        XCTAssertEqual(defaults.data(forKey: "presets"), presets)

        let ruleStore = AutoStopRulesStore(
            userDefaults: defaults,
            key: "rules",
            eventsKey: "events",
            inventory: ScriptedInventory(processes: []),
            eventLimit: 200,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        XCTAssertEqual(ruleStore.rules.map(\.processName), ["Example"])
        XCTAssertTrue(ruleStore.isRulesReadOnlyAfterRecovery)
        XCTAssertFalse(ruleStore.isEventsReadOnlyAfterRecovery)
        XCTAssertEqual(defaults.data(forKey: "rules.corruptBackup"), rules)
        XCTAssertEqual(defaults.data(forKey: "rules"), rules)
    }
}
