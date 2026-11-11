import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

// MARK: - Settings

@MainActor
final class Batch07SettingsTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    private let key = "batch07-settings"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07SettingsTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // T06-9
    func testAutoRefreshProcessListIsSaved() {
        let store = makeStore()
        XCTAssertFalse(store.autoRefreshProcessList)
        store.autoRefreshProcessList = true
        XCTAssertTrue(makeStore().autoRefreshProcessList)
        store.autoRefreshProcessList = false
        XCTAssertFalse(makeStore().autoRefreshProcessList)
    }

    // T06-9
    func testSearchTextIsCappedAt500CharactersInMemoryStoredAndLoaded() throws {
        let store = makeStore()
        store.searchText = String(repeating: "a", count: 600)
        XCTAssertEqual(store.searchText, String(repeating: "a", count: 500))
        store.flushPendingWrites()
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        XCTAssertEqual((stored["searchText"] as? String)?.count, 500)
        XCTAssertEqual(makeStore().searchText.count, 500)

        let long: [String: Any] = ["schemaVersion": 3, "searchText": String(repeating: "b", count: 700)]
        defaults.set(try JSONSerialization.data(withJSONObject: long), forKey: key)
        XCTAssertEqual(makeStore().searchText, String(repeating: "b", count: 500))
    }

    // A11-8: a payload replaced after launch is never overwritten by a save.
    func testSaveKeepsSettingsThatBecameUnreadableAfterLaunch() throws {
        let store = makeStore()
        store.refreshIntervalSeconds = 22
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        let foreign = Data(#"{"schemaVersion":3,"refreshIntervalSeconds":{"seconds":22}}"#.utf8)
        defaults.set(foreign, forKey: key)

        store.keepGlobalProtectOff = true
        XCTAssertEqual(defaults.data(forKey: key), foreign)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), foreign)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("\(key).corruptBackup") == true, store.recoveryMessage ?? "")
        store.searchText = "later"
        store.flushPendingWrites()
        store.processListLimit = 50
        XCTAssertEqual(defaults.data(forKey: key), foreign)

        store.resetAfterCorruption()
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertTrue(reloaded.keepGlobalProtectOff)
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 22)
        XCTAssertEqual(reloaded.processListLimit, 50)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), foreign)
    }

    // L11-6: every process can be shown.
    func testShowAllProcessesLiftsTheDisplayLimitAndIsKept() {
        let store = makeStore()
        XCTAssertFalse(store.showsAllProcesses)
        store.showsAllProcesses = true
        XCTAssertEqual(store.processListLimit, SettingsStore.allProcessesLimit)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.showsAllProcesses)
        reloaded.showsAllProcesses = false
        XCTAssertEqual(reloaded.processListLimit, 80)
        reloaded.processListLimit = 5_000
        XCTAssertEqual(reloaded.processListLimit, 200, "other values keep the ordinary range")

        let inventory = (1...250).map { batch07Process(pid: Int32($0), command: "tool\($0)", executablePath: nil) }
        var projection = ProcessListProjection(inventory: inventory)
        let query = ProcessListQuery(
            searchText: "", filterMode: .all, watchedScopes: [],
            cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1024
        )
        XCTAssertEqual(projection.displayList(for: query, sortKey: .pid, limit: SettingsStore.allProcessesLimit).processes.count, 250)
        XCTAssertEqual(projection.displayList(for: query, sortKey: .pid, limit: 200).processes.count, 200)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
    }
}
