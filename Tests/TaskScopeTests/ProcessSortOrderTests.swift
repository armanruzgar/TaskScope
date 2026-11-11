import SwiftUI
import XCTest
@testable import TaskScope

/// L09-21: every key sorts both ways with missing values last, the direction
/// is saved, and the column titles and the Sort menu set it.
final class ProcessSortOrderTests: XCTestCase {
    private func process(
        _ pid: Int32,
        name: String,
        parent: Int32 = 1,
        owner: String? = "alex",
        cpu: Double = 0,
        memory: Double = 1,
        net: (Double, Double)? = nil,
        disk: (Double, Double)? = nil
    ) -> AppProcess {
        var row = AppProcess.fixture(
            pid: pid, parentPID: parent, uid: 501, ownerName: owner, cpu: cpu, memoryMB: memory,
            command: name, elapsedTime: "00:01", startTime: "Wed Oct 7 17:04:47 2026",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
        // The Network and Disk columns sort by their per-second rates.
        row.netInRateKBps = net?.0
        row.netOutRateKBps = net?.1
        row.diskReadRateBytesPerSecond = disk?.0
        row.diskWriteRateBytesPerSecond = disk?.1
        return row
    }

    private func query(_ search: String = "") -> ProcessListQuery {
        ProcessListQuery(searchText: search, filterMode: .all, watchedScopes: [],
                         cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1_024)
    }

    func testDefaultDirectionsKeepTheBusiestProcessesVisible() {
        XCTAssertEqual(ProcessSortKey.allCases.map(\.defaultDirection), [
            .descending, .descending, .ascending, .ascending, .ascending, .ascending, .descending, .descending
        ])
        XCTAssertEqual(ProcessSortKey.allCases.map(\.rawValue), [
            "cpu", "memory", "name", "pid", "ppid", "user", "network", "disk"
        ], "raw values are stored in settings")
        XCTAssertEqual(ProcessSortOrder(key: .network), ProcessSortOrder(key: .network, direction: .descending))
        XCTAssertEqual(ProcessSortOrder(key: .parentPID).direction, .ascending)
        XCTAssertEqual(ProcessSortKey.allCases.filter(\.needsExtendedStats), [.network, .disk])
    }

    func testClickingTheActiveColumnReversesItAndAnotherColumnStartsInItsDefault() {
        let cpu = ProcessSortOrder(key: .cpu)
        XCTAssertEqual(cpu.selectingColumn(.cpu), ProcessSortOrder(key: .cpu, direction: .ascending))
        XCTAssertEqual(cpu.selectingColumn(.cpu).selectingColumn(.cpu), cpu)
        XCTAssertEqual(
            ProcessSortOrder(key: .cpu, direction: .ascending).selectingColumn(.pid),
            ProcessSortOrder(key: .pid, direction: .ascending)
        )
        XCTAssertEqual(
            ProcessSortOrder(key: .name, direction: .descending).selectingColumn(.disk),
            ProcessSortOrder(key: .disk, direction: .descending)
        )
        XCTAssertEqual(ProcessSortDirection.descending.accessibilityValue, "sorted descending")
        XCTAssertEqual(ProcessSortDirection.ascending.accessibilityValue, "sorted ascending")
    }

    func testEveryKeySortsBothWaysWithMissingValuesLastAndStableTies() {
        let rows = [
            process(10, name: "Delta", parent: 7, owner: "root", cpu: 5, memory: 30, net: (1, 1), disk: (100, 0)),
            process(11, name: "alpha", parent: 3, owner: "alex", cpu: 50, memory: 10, net: nil, disk: (5, 5)),
            process(12, name: "Charlie", parent: 9, owner: nil, cpu: 0, memory: 20, net: (10, 30), disk: nil),
            process(13, name: "Bravo", parent: 3, owner: "alex", cpu: 0, memory: 20, net: (2, 0), disk: (0, 1))
        ]
        var projection = ProcessListProjection(inventory: rows.shuffled())
        func order(_ key: ProcessSortKey, _ direction: ProcessSortDirection) -> [Int32] {
            projection.displayProcesses(order: ProcessSortOrder(key: key, direction: direction), limit: 10).map(\.pid)
        }
        // Ties (CPU 0, memory 20, PPID 3) keep the ascending name order either way.
        XCTAssertEqual(order(.cpu, .descending), [11, 10, 13, 12])
        XCTAssertEqual(order(.cpu, .ascending), [13, 12, 10, 11])
        XCTAssertEqual(order(.memory, .descending), [10, 13, 12, 11])
        XCTAssertEqual(order(.memory, .ascending), [11, 13, 12, 10])
        XCTAssertEqual(order(.name, .ascending), [11, 13, 12, 10])
        XCTAssertEqual(order(.name, .descending), [10, 12, 13, 11])
        XCTAssertEqual(order(.pid, .ascending), [10, 11, 12, 13])
        XCTAssertEqual(order(.pid, .descending), [13, 12, 11, 10])
        XCTAssertEqual(order(.parentPID, .ascending), [11, 13, 10, 12])
        XCTAssertEqual(order(.parentPID, .descending), [12, 10, 11, 13])
        // Network: 40, 2, 2 and no value; disk: 100, 10, 1 and no value.
        XCTAssertEqual(order(.network, .descending), [12, 13, 10, 11])
        XCTAssertEqual(order(.network, .ascending), [13, 10, 12, 11], "missing values stay last")
        XCTAssertEqual(order(.disk, .descending), [10, 11, 13, 12])
        XCTAssertEqual(order(.disk, .ascending), [13, 11, 10, 12], "missing values stay last")
        // Owners by the rows' account names, alex before root; an unknown owner last.
        XCTAssertEqual(order(.user, .ascending), [11, 13, 10, 12])
        XCTAssertEqual(order(.user, .descending), [10, 11, 13, 12])
    }

    /// The limit applies after sorting, and the cached lists, matches and tree
    /// are kept per direction.
    func testDirectionIsPartOfEveryCachedListAndTheLimitAppliesAfterSorting() {
        let parent = process(100, name: "Parent", cpu: 1)
        var rows: [AppProcess] = [parent]
        for pid in Int32(101)...110 {
            let written: Double = pid == 103 ? 9_000_000 : Double(pid)
            rows.append(process(pid, name: "Worker\(pid)", parent: 100, cpu: Double(pid - 100), disk: (0, written)))
        }
        var projection = ProcessListProjection(inventory: rows)
        let busiest = projection.displayList(for: query(), order: ProcessSortOrder(key: .cpu), limit: 3)
        XCTAssertEqual(busiest.processes.map(\.pid), [110, 109, 108])
        let idlest = projection.displayList(for: query(), order: ProcessSortOrder(key: .cpu, direction: .ascending), limit: 3)
        XCTAssertEqual(idlest.processes.map(\.pid), [100, 101, 102])
        XCTAssertEqual(idlest.matchCount, 11)
        XCTAssertEqual(projection.displayList(for: query(), order: ProcessSortOrder(key: .disk), limit: 1).processes.map(\.pid), [103],
                       "a disk-heavy process is shown when sorted by Disk, whatever its CPU")
        XCTAssertEqual(projection.displayProcesses(for: query(), order: ProcessSortOrder(key: .cpu), limit: 3).map(\.pid), [110, 109, 108])

        let descendingTree = projection.treeRoots(for: query(), order: ProcessSortOrder(key: .pid, direction: .descending), limit: 20)
        XCTAssertEqual(descendingTree.first?.children.map(\.id), Array((101...110).reversed()))
        let ascendingTree = projection.treeRoots(for: query(), order: ProcessSortOrder(key: .pid), limit: 20)
        XCTAssertEqual(ascendingTree.first?.children.map(\.id), Array(101...110))

        // The key-only reads keep their old meaning: the key's default direction.
        XCTAssertEqual(projection.displayList(for: query(), sortKey: .cpu, limit: 3).processes.map(\.pid), [110, 109, 108])
    }

    func testOwnerNamesComeFromTheAccountDatabase() {
        XCTAssertEqual(ProcessOwnerNames.name(for: 0), "root")
        XCTAssertEqual(ProcessOwnerNames.name(for: getuid()), String(cString: getpwuid(getuid())!.pointee.pw_name))
        XCTAssertEqual(ProcessOwnerNames.name(for: 4_000_000_000), "4000000000", "an id with no account shows its number")
    }

    // MARK: Settings

    @MainActor
    func testDirectionIsSavedAndOlderPayloadsUseTheKeysDefault() {
        let key = "TaskScope.settings.v1"
        func store(_ payload: String) -> SettingsStore {
            let defaults = InMemoryUserDefaults(suiteName: "TaskScope.SortOrder.\(UUID().uuidString)")!
            defaults.set(Data(payload.utf8), forKey: key)
            return SettingsStore(userDefaults: defaults)
        }
        XCTAssertEqual(store(#"{"schemaVersion":3,"sortKeyRaw":"memory"}"#).sortOrder, ProcessSortOrder(key: .memory, direction: .descending))
        XCTAssertEqual(store(#"{"schemaVersion":3,"sortKeyRaw":"name"}"#).sortOrder, ProcessSortOrder(key: .name, direction: .ascending))
        XCTAssertEqual(
            store(#"{"schemaVersion":3,"sortKeyRaw":"cpu","sortDirectionRaw":"ascending"}"#).sortOrder,
            ProcessSortOrder(key: .cpu, direction: .ascending)
        )
        XCTAssertEqual(
            store(#"{"schemaVersion":3,"sortKeyRaw":"pid","sortDirectionRaw":"sideways"}"#).sortOrder,
            ProcessSortOrder(key: .pid, direction: .ascending)
        )
        let unknownKey = store(#"{"schemaVersion":3,"sortKeyRaw":"threads","sortDirectionRaw":"ascending"}"#)
        XCTAssertEqual(unknownKey.sortOrder, ProcessSortOrder(key: .cpu, direction: .descending),
                       "a direction chosen for a key this build does not know does not carry over")
        XCTAssertFalse(unknownKey.isReadOnlyAfterCorruption)

        let defaults = InMemoryUserDefaults(suiteName: "TaskScope.SortOrder.\(UUID().uuidString)")!
        let settings = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(settings.sortOrder, ProcessSortOrder(key: .cpu, direction: .descending))
        settings.setSortOrder(ProcessSortOrder(key: .disk, direction: .ascending))
        XCTAssertEqual(SettingsStore(userDefaults: defaults).sortOrder, ProcessSortOrder(key: .disk, direction: .ascending))
        let stored = try? JSONSerialization.jsonObject(with: defaults.data(forKey: key) ?? Data()) as? [String: Any]
        XCTAssertEqual(stored?["sortKeyRaw"] as? String, "disk")
        XCTAssertEqual(stored?["sortDirectionRaw"] as? String, "ascending")
    }

    /// A build without directions keeps the field when it saves its own
    /// settings, and this build keeps a newer build's unknown fields.
    @MainActor
    func testDirectionSurvivesASaveThatDoesNotKnowIt() throws {
        let key = "TaskScope.settings.v1"
        let defaults = InMemoryUserDefaults(suiteName: "TaskScope.SortOrder.\(UUID().uuidString)")!
        defaults.set(Data(#"{"schemaVersion":3,"sortKeyRaw":"memory","sortDirectionRaw":"ascending","futureField":7}"#.utf8), forKey: key)
        let settings = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(settings.sortOrder, ProcessSortOrder(key: .memory, direction: .ascending))
        settings.refreshIntervalSeconds = 20
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        XCTAssertEqual(stored["sortDirectionRaw"] as? String, "ascending")
        XCTAssertEqual(stored["futureField"] as? Int, 7)
    }

    @MainActor
    func testManagerSortsByItsOrderAndAKeyAloneUsesTheDefaultDirection() async {
        let rows = [process(20, name: "B", cpu: 1), process(21, name: "A", cpu: 9), process(22, name: "C", cpu: 5)]
        let inventory = ScriptedInventory(processes: rows)
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: FakeSignaler(), lifecycle: FakeLifecycle.forViewTests(), settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        await manager.loadProcessList(showMessage: false)
        XCTAssertEqual(manager.displayProcesses(for: query()).map(\.pid), [21, 22, 20])
        manager.sortOrder = ProcessSortOrder(key: .cpu, direction: .ascending)
        XCTAssertEqual(manager.displayProcesses(for: query()).map(\.pid), [20, 22, 21])
        manager.sortKey = .name
        XCTAssertEqual(manager.sortOrder, ProcessSortOrder(key: .name, direction: .ascending))
        XCTAssertEqual(manager.displayProcesses(for: query()).map(\.pid), [21, 20, 22])
    }
}
