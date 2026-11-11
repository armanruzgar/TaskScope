import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L09-21: every key sorts both ways with missing values last, the direction
/// is saved, and the column titles and the Sort menu set it.
final class ProcessSortOrderTests: XCTestCase {
    private func process(
        _ pid: Int32,
        name: String,
        parent: Int32 = 1,
        uid: uid_t? = 501,
        cpu: Double = 0,
        memory: Double = 1,
        net: (Double, Double)? = nil,
        disk: (Double, Double)? = nil
    ) -> AppProcess {
        var row = AppProcess(
            pid: pid, parentPID: parent, uid: uid, cpu: cpu, memoryMB: memory,
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
            process(10, name: "Delta", parent: 7, uid: 0, cpu: 5, memory: 30, net: (1, 1), disk: (100, 0)),
            process(11, name: "alpha", parent: 3, uid: 501, cpu: 50, memory: 10, net: nil, disk: (5, 5)),
            process(12, name: "Charlie", parent: 9, uid: nil, cpu: 0, memory: 20, net: (10, 30), disk: nil),
            process(13, name: "Bravo", parent: 3, uid: 501, cpu: 0, memory: 20, net: (2, 0), disk: (0, 1))
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
        // Owners by account name: root before the 501 account; an unknown owner last.
        let rootFirst = ProcessOwnerNames.name(for: 0).localizedStandardCompare(ProcessOwnerNames.name(for: 501)) == .orderedAscending
        XCTAssertEqual(order(.user, .ascending), rootFirst ? [10, 11, 13, 12] : [11, 13, 10, 12])
        XCTAssertEqual(order(.user, .descending), rootFirst ? [11, 13, 10, 12] : [10, 11, 13, 12])
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
        let inventory = UIInventory(processes: rows)
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: UIRecordingSignaler(), lifecycle: UILifecycle(), settleAfterProcessChange: {},
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

/// L09-21: the column titles and the Sort menu.
@MainActor
final class ProcessSortControlTests: XCTestCase {
    func testEverySortableTitleIsABorderlessButtonThatSortsAndReverses() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let titles: [(String, ProcessSortKey)] = [
            ("PID", .pid), ("PPID", .parentPID), ("USER", .user), ("NET KB/S", .network),
            ("DISK MB/S", .disk), ("CPU", .cpu), ("MEM MB", .memory)
        ]
        for (title, key) in titles {
            let button = try Batch10.popover(fixture).inspect().find(button: title)
            XCTAssertTrue(try button.buttonStyle() is BorderlessButtonStyle, title)
            XCTAssertEqual(try button.accessibilityHint().string(), "Sorts the process list by this column", title)

            try button.tap()
            XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: key), title)
            XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: key), title)
            let active = try Batch10.popover(fixture).inspect().find(button: title)
            XCTAssertEqual(try active.accessibilityValue().string(), key.defaultDirection.accessibilityValue, title)
            XCTAssertEqual(try active.accessibilityHint().string(), "Reverses the sort order", title)
            let chevron = key.defaultDirection == .descending ? "chevron.down" : "chevron.up"
            XCTAssertNoThrow(try active.find(ViewType.Image.self) { try $0.actualImage().name() == chevron }, title)

            try active.tap()
            let reversed = ProcessSortOrder(key: key, direction: key.defaultDirection.reversed)
            XCTAssertEqual(fixture.stores.settings.sortOrder, reversed, title)
            XCTAssertEqual(fixture.manager.sortOrder, reversed, title)
            XCTAssertEqual(
                try Batch10.popover(fixture).inspect().find(button: title).accessibilityValue().string(),
                reversed.direction.accessibilityValue, title
            )
        }
        // Only the active column is marked.
        let inspected = try Batch10.popover(fixture).inspect()
        XCTAssertEqual(try inspected.find(button: "CPU").accessibilityValue().string(), "")
        XCTAssertEqual(
            try inspected.find(button: "CPU").help().string(),
            "Click to sort by CPU."
        )
        XCTAssertEqual(
            try inspected.find(button: "MEM MB").help().string(),
            "Sorted by Memory, ascending; click to reverse."
        )
    }

    func testCompactPopoverTitlesSortToo() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let popover = try Batch10.popover(fixture, style: .menuBarCompact).inspect()
        XCTAssertThrowsError(try popover.find(button: "PPID"), "the popover has no PPID column")
        try popover.find(button: "MEM MB").tap()
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .memory))
    }

    func testSortMenuOffersEveryKeyAndBothDirections() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        func menu() throws -> InspectableView<ViewType.Menu> {
            try Batch10.popover(fixture).inspect().find(ViewType.Menu.self) { try $0.accessibilityLabel().string() == "Sort" }
        }
        let keys = try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Sort By" }
        let directions = try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Order" }
        for key in ProcessSortKey.allCases { XCTAssertNoThrow(try keys.find(text: key.label)) }
        XCTAssertNoThrow(try directions.find(text: "Ascending"))
        XCTAssertNoThrow(try directions.find(text: "Descending"))
        XCTAssertEqual(try menu().labelView().text().string(), "CPU ↓")

        try keys.select(value: ProcessSortKey.user)
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .ascending))
        try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Order" }
            .select(value: ProcessSortDirection.descending)
        XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        // Choosing the current key again keeps its direction.
        try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Sort By" }
            .select(value: ProcessSortKey.user)
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        XCTAssertEqual(try menu().labelView().text().string(), "User ↓")
        XCTAssertEqual(try menu().accessibilityValue().string(), "User, descending")
    }

    func testOnlyAPopoverSortedByNetworkOrDiskReadsThoseCounters() {
        for key in ProcessSortKey.allCases {
            XCTAssertEqual(
                TaskScopePopoverView.needsSortMetrics(isExpandedWindow: false, isOnScreen: true, sortKey: key),
                key == .network || key == .disk, "\(key)"
            )
            XCTAssertFalse(TaskScopePopoverView.needsSortMetrics(isExpandedWindow: false, isOnScreen: false, sortKey: key))
            XCTAssertFalse(
                TaskScopePopoverView.needsSortMetrics(isExpandedWindow: true, isOnScreen: true, sortKey: key),
                "the window reads them whenever it is open"
            )
        }
    }
}
