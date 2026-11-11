import XCTest
@testable import TaskScope

@MainActor
final class ProcessTreeBuilderTests: XCTestCase {
    func testVisibleProcessesIncludesOnlyChildrenOfExpandedRows() {
        let root = process(pid: 1, command: "root")
        let child = process(pid: 2, command: "child")
        let grandchild = process(pid: 3, command: "grandchild")
        let tree = ProcessTreeBuilder.build(
            from: [root, child, grandchild],
            ppidMap: [1: 0, 2: 1, 3: 2]
        )

        XCTAssertEqual(
            ProcessTreeBuilder.visibleProcesses(in: tree, expandedPIDs: []).map(\.pid),
            [1]
        )
        XCTAssertEqual(
            ProcessTreeBuilder.visibleProcesses(in: tree, expandedPIDs: [1]).map(\.pid),
            [1, 2]
        )
        XCTAssertEqual(
            ProcessTreeBuilder.visibleProcesses(in: tree, expandedPIDs: [1, 2]).map(\.pid),
            [1, 2, 3]
        )
    }

    func testBuildNestsChildrenUnderVisibleParents() {
        let root = process(pid: 100, command: "/Applications/Root.app/Root")
        let child = process(pid: 101, command: "/usr/bin/child")
        let grandchild = process(pid: 102, command: "/usr/bin/grandchild")
        let orphan = process(pid: 200, command: "/usr/bin/orphan")

        let tree = ProcessTreeBuilder.build(
            from: [root, child, grandchild, orphan],
            ppidMap: [
                100: 1,
                101: 100,
                102: 101,
                200: 999
            ]
        )

        XCTAssertEqual(tree.map(\.id), [100, 200])
        XCTAssertEqual(tree[0].children.map(\.id), [101])
        XCTAssertEqual(tree[0].children[0].children.map(\.id), [102])
        XCTAssertEqual(tree[1].children, [])
    }

    func testFilteredTreePreservesAvailableAncestors() {
        let root = process(pid: 100, command: "root")
        let child = process(pid: 101, command: "child")
        let match = process(pid: 102, command: "match")

        let tree = ProcessTreeBuilder.build(
            from: [root, child, match],
            ppidMap: [100: 1, 101: 100, 102: 101],
            matchingPIDs: [102]
        )

        XCTAssertEqual(tree.map(\.id), [100])
        XCTAssertEqual(tree[0].children.map(\.id), [101])
        XCTAssertEqual(tree[0].children[0].children.map(\.id), [102])
    }

    func testSelfParentAndCyclesProduceFiniteDeterministicRoots() {
        let selfParent = process(pid: 10, command: "self")
        let first = process(pid: 20, command: "first")
        let second = process(pid: 21, command: "second")

        let tree = ProcessTreeBuilder.build(
            from: [selfParent, first, second],
            ppidMap: [10: 10, 20: 21, 21: 20]
        )

        XCTAssertEqual(tree.map(\.id), [10, 20])
        XCTAssertEqual(tree[1].children.map(\.id), [21])
    }

    func testDuplicatePIDRowsDoNotCrashTheBuilder() {
        let first = process(pid: 7, command: "first")
        let duplicate = process(pid: 7, command: "duplicate")

        let tree = ProcessTreeBuilder.build(from: [first, duplicate], ppidMap: [7: 0])

        XCTAssertEqual(tree.map(\.id), [7])
        XCTAssertEqual(tree[0].process.command, "first")
    }

    private func process(pid: Int32, command: String) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 0,
            cpu: 0,
            memoryMB: 0,
            command: command,
            elapsedTime: "",
            netInKB: 0,
            netOutKB: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
    }
}
