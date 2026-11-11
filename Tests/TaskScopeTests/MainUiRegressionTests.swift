import XCTest
@testable import TaskScope

final class MainUiRegressionTests: XCTestCase {
    func testDisplayListKeepsUnlimitedMatchCountsWithTheLimitedRows() {
        let parent = process(pid: 10, name: "Parent", cpu: 1)
        let first = process(pid: 11, parentPID: 10, name: "WorkerA", cpu: 90)
        let second = process(pid: 12, parentPID: 10, name: "WorkerB", cpu: 80)
        var projection = ProcessListProjection(inventory: [parent, first, second])
        var query = ProcessListQuery(searchText: "", filterMode: .all, watchedScopes: [],
                                     cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1_024)
        for sortKey in ProcessSortKey.allCases {
            for limit in [-1, 0, 1, 2, 3, 4] {
                let result = projection.displayList(for: query, sortKey: sortKey, limit: limit)
                XCTAssertEqual(result.matchCount, 3)
                XCTAssertEqual(result.processes.count, min(max(0, limit), 3))
                XCTAssertEqual(result.processes, projection.displayProcesses(for: query, sortKey: sortKey, limit: limit))
                XCTAssertEqual(projection.displayList(for: query, sortKey: sortKey, limit: limit).matchCount, 3)
            }
        }
        query.searchText = "Worker"
        let searched = projection.displayList(for: query, sortKey: .cpu, limit: 1)
        XCTAssertEqual(searched.processes, [first])
        XCTAssertEqual(searched.matchCount, 2)
        let roots = projection.treeRoots(for: query, sortKey: .cpu, limit: 1)
        XCTAssertEqual(roots.map(\.process), [parent])
        XCTAssertEqual(roots.first?.children.map(\.process), [first])
        // Ancestor context does not inflate the matching-process count.
        XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).matchCount, 2)

        query.searchText = ""
        query.filterMode = .highlighted
        XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).matchCount, 2)
        query.filterMode = .watched
        query.watchedScopes = [WatchedProcessScope(preset: WatchedAppPreset(
            displayName: "Workers", mainProcessName: "WorkerA", helperProcessNames: ["WorkerB"],
            protectedProcessNames: [], appPath: "/Applications/Workers.app"
        ))]
        XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).matchCount, 2)
        query.searchText = "missing"
        XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).matchCount, 0)
    }

    private func process(pid: Int32, parentPID: Int32 = 1, name: String, cpu: Double) -> AppProcess {
        AppProcess.fixture(pid: pid, parentPID: parentPID, uid: getuid(), cpu: cpu, memoryMB: 1,
                   command: name, executablePath: "/Applications/Workers.app/Contents/MacOS/\(name)",
                   elapsedTime: "00:10", startTime: "start", netInKB: nil, netOutKB: nil,
                   diskReadBytes: nil, diskWriteBytes: nil)
    }
}
