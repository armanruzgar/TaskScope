import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class Batch06ListModelTests: XCTestCase {
    /// A05-3: the tree follows the Sort setting at every level.
    func testTreeRootsAndSiblingsFollowEverySortKeyWithAncestorContext() {
        let parent = batch06Process(pid: 100, name: "Bravo", cpu: 1, memory: 30)
        let children = [
            batch06Process(pid: 101, parent: 100, name: "Zulu", cpu: 5, memory: 20),
            batch06Process(pid: 102, parent: 100, name: "Alpha", cpu: 95, memory: 40),
            batch06Process(pid: 103, parent: 100, name: "Echo", cpu: 10, memory: 10)
        ]
        let other = batch06Process(pid: 200, name: "Charlie", cpu: 60, memory: 5)
        let last = batch06Process(pid: 300, name: "Delta", cpu: 3, memory: 100)
        var projection = ProcessListProjection(inventory: children.reversed() + [last, parent, other])
        let expectations: [(ProcessSortKey, [Int32], [Int32])] = [
            (.cpu, [200, 300, 100], [102, 103, 101]),
            (.memory, [300, 100, 200], [102, 101, 103]),
            (.name, [100, 200, 300], [102, 103, 101]),
            (.pid, [100, 200, 300], [101, 102, 103])
        ]
        for (key, roots, siblings) in expectations {
            let tree = projection.treeRoots(for: batch06Query(), sortKey: key, limit: 80)
            XCTAssertEqual(tree.map(\.id), roots, "\(key)")
            XCTAssertEqual(tree.first { $0.id == 100 }?.children.map(\.id), siblings, "\(key)")
        }
        // With the limit truncating the matches, the ancestor kept for context
        // is placed by its own rank, after the busier root.
        let limited = projection.treeRoots(for: batch06Query(), sortKey: .cpu, limit: 2)
        XCTAssertEqual(limited.map(\.id), [200, 100])
        XCTAssertEqual(limited.last?.children.map(\.id), [102])
    }

    /// T07-6: one parent with many children always lists them in a stable order.
    func testManySiblingsHaveStablePIDOrderAcrossInputPermutations() {
        let parent = batch06Process(pid: 100, name: "Parent")
        let children = (101...140).map { batch06Process(pid: Int32($0), parent: 100, name: "Worker") }
        let expected = children.map(\.pid)
        for offset in 0..<20 {
            let permuted = Array(children.dropFirst(offset)) + Array(children.prefix(offset))
            let inventory = [parent] + permuted.reversed()
            let parents = Dictionary(uniqueKeysWithValues: inventory.map { ($0.pid, $0.parentPID) })
            let tree = ProcessTreeBuilder.build(from: inventory, ppidMap: parents)
            XCTAssertEqual(tree.first?.children.map(\.id), expected)
            var projection = ProcessListProjection(inventory: inventory)
            for sortKey in [ProcessSortKey.cpu, .memory, .name, .pid] {
                let projected = projection.treeRoots(for: batch06Query(), sortKey: sortKey, limit: 80)
                XCTAssertEqual(projected.first?.children.map(\.id), expected, "\(sortKey)")
            }
        }
    }

    /// T07-6: ranked rows come first in rank order; equal and missing ranks
    /// fall back to PID order.
    func testBuilderOrdersSiblingsByRankThenPID() {
        let parent = batch06Process(pid: 1_000, name: "Parent")
        let children = [105, 101, 104, 102, 103].map {
            batch06Process(pid: Int32($0), parent: 1_000, name: "Child")
        }
        let inventory = [parent] + children
        let parents = Dictionary(uniqueKeysWithValues: inventory.map { ($0.pid, $0.parentPID) })
        let tree = ProcessTreeBuilder.build(
            from: inventory,
            ppidMap: parents,
            sortRanks: [1_000: 0, 104: 1, 102: 2, 105: 2]
        )
        XCTAssertEqual(tree.map(\.id), [1_000])
        XCTAssertEqual(tree.first?.children.map(\.id), [104, 102, 105, 101, 103])
    }

    /// L04-1: the per-query memo caches stay bounded while the inventory lives.
    func testQueryCachesStayBoundedWithoutReplacingInventory() throws {
        let parent = batch06Process(pid: 100, name: "Parent")
        let child = batch06Process(pid: 101, parent: 100, name: "Worker", cpu: 90)
        var projection = ProcessListProjection(inventory: [parent, child])
        for index in 0..<100 {
            var query = batch06Query()
            query.searchText = String(repeating: " ", count: index)
            query.cpuHighlightThreshold = Double(index)
            XCTAssertEqual(projection.displayList(for: query, sortKey: .cpu, limit: 1).processes, [child])
            XCTAssertEqual(projection.treeRoots(for: query, sortKey: .cpu, limit: 1).first?.children.map(\.id), [101])
            for label in ["displayListCache", "treeRootsCache"] {
                let cache = try XCTUnwrap(Mirror(reflecting: projection).children.first { $0.label == label })
                XCTAssertLessThanOrEqual(Mirror(reflecting: cache.value).children.count, 8, label)
            }
        }
        // Eviction must preserve match counts, limits, and ancestor reconstruction.
        let list = projection.displayList(for: batch06Query(), sortKey: .cpu, limit: 1)
        XCTAssertEqual(list.processes, [child])
        XCTAssertEqual(list.matchCount, 2)
        XCTAssertEqual(projection.treeRoots(for: batch06Query(), sortKey: .cpu, limit: 1).first?.process, parent)
    }

    /// L08-11: the ranked tie-break gives the order a direct natural-name
    /// comparison gives, and the names are ranked once per inventory.
    func testRankedTieBreakKeepsTheNaturalNameOrder() throws {
        let names = [
            "Worker10", "Worker2", "worker2", "Worker 2", "WORKER1", "Éclair", "Eclair", "eclair",
            "com.apple.WebKit.WebContent", "com.apple.WebKit.Networking", "Google Chrome Helper (Renderer)",
            "Google Chrome Helper", "zsh", "Zsh", "a10b2", "a2b10", "a2b9", "-dash", "_under", "123"
        ]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let inventory: [AppProcess] = (0..<300).map { index in
            batch06Process(
                pid: Int32(10_000 - index * 7),
                name: index < names.count ? names[index] : names[next(names.count)],
                cpu: next(10) < 8 ? 0 : Double(next(4)),
                memory: Double(next(3))
            )
        }
        var projection = ProcessListProjection(inventory: inventory)
        for key in [ProcessSortKey.cpu, .memory, .name, .pid, .cpu] {
            let expected = inventory.sorted { lhs, rhs in
                switch key {
                case .cpu where lhs.cpu != rhs.cpu: return lhs.cpu > rhs.cpu
                case .memory where lhs.memoryMB != rhs.memoryMB: return lhs.memoryMB > rhs.memoryMB
                case .pid: return lhs.pid < rhs.pid
                default:
                    let comparison = lhs.name.localizedStandardCompare(rhs.name)
                    return comparison == .orderedSame ? lhs.pid < rhs.pid : comparison == .orderedAscending
                }
            }
            XCTAssertEqual(projection.displayProcesses(sortKey: key, limit: 500).map(\.pid), expected.map(\.pid), "\(key)")
        }
        let cache = try XCTUnwrap(Mirror(reflecting: projection).children.first { $0.label == "nameRanksCache" })
        let ranks = try XCTUnwrap(Mirror(reflecting: cache.value).children.first?.value as? [String: Int])
        XCTAssertEqual(ranks.count, Set(inventory.map(\.name)).count, "One rank per distinct name, computed once")
        XCTAssertLessThan(try XCTUnwrap(ranks["Worker2"]), try XCTUnwrap(ranks["Worker10"]))
    }
}
