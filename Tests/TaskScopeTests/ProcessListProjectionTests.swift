import XCTest
@testable import TaskScope

final class ProcessListProjectionTests: XCTestCase {
    func testDisplayAndTreeFollowQuerySortAndLimitChanges() {
        let parent = process(pid: 10, name: "Parent")
        let child = process(pid: 11, parentPID: 10, cpu: 90, memory: 5, name: "Child")
        let other = process(pid: 20, cpu: 10, memory: 100, name: "Other")
        var projection = ProcessListProjection(inventory: [parent, child, other])
        var query = ProcessListQuery(
            searchText: "", filterMode: .all, watchedScopes: [],
            cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1_024
        )

        XCTAssertEqual(projection.displayProcesses(for: query, sortKey: .cpu, limit: 1), [child])
        let roots = projection.treeRoots(for: query, sortKey: .cpu, limit: 1)
        XCTAssertEqual(roots.map(\.process), [parent])
        XCTAssertEqual(roots.first?.children.map(\.process), [child])
        XCTAssertEqual(projection.displayProcesses(for: query, sortKey: .memory, limit: 1), [other])
        XCTAssertEqual(projection.treeRoots(for: query, sortKey: .memory, limit: 1).map(\.id), [20])

        query.searchText = "Child"
        XCTAssertEqual(projection.displayProcesses(for: query, sortKey: .memory, limit: 1), [child])
        XCTAssertEqual(projection.treeRoots(for: query, sortKey: .memory, limit: 1), roots)
        query.searchText = ""
        XCTAssertEqual(projection.displayProcesses(for: query, sortKey: .memory, limit: 2), [other, child])
        XCTAssertEqual(projection.treeRoots(for: query, sortKey: .memory, limit: 2).map(\.id), [20, 10])

        for limit in [0, -1] {
            XCTAssertTrue(projection.displayProcesses(for: query, sortKey: .memory, limit: limit).isEmpty)
            XCTAssertTrue(projection.treeRoots(for: query, sortKey: .memory, limit: limit).isEmpty)
        }
        // Returning to an earlier query/sort/limit must still return that list.
        XCTAssertEqual(projection.displayProcesses(for: query, sortKey: .cpu, limit: 1), [child])
        XCTAssertEqual(projection.treeRoots(for: query, sortKey: .cpu, limit: 1), roots)
    }

    func testMetricTiesUseNaturalNameOrderAndNameTiesUsePID() {
        let laterName = process(pid: 10, cpu: 5, memory: 10, name: "Worker10")
        let earlierName = process(pid: 20, cpu: 5, memory: 10, name: "Worker2")
        var projection = ProcessListProjection(inventory: [laterName, earlierName])
        for sortKey in [ProcessSortKey.cpu, .memory, .name] {
            XCTAssertEqual(projection.displayProcesses(sortKey: sortKey, limit: 2), [earlierName, laterName])
        }
        XCTAssertEqual(projection.displayProcesses(sortKey: .pid, limit: 2), [laterName, earlierName])

        let sameName = process(pid: 5, name: "Worker2")
        projection = ProcessListProjection(inventory: [earlierName, laterName, sameName])
        XCTAssertEqual(projection.displayProcesses(sortKey: .name, limit: 3).map(\.pid), [5, 20, 10])
    }

    private func process(
        pid: Int32, parentPID: Int32 = 1, cpu: Double = 0, memory: Double = 0, name: String
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid, parentPID: parentPID, cpu: cpu, memoryMB: memory,
            command: name, elapsedTime: "00:10", startTime: "start",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }
}
