import Foundation

/// Read-only inventory with derived lists cached for its lifetime. Replacing the
/// projection replaces every cache together, so no list can outlive its inventory.
struct ProcessListProjection {
    let inventory: [AppProcess]

    private struct DisplayListKey: Hashable {
        var query: ProcessListQuery
        var limit: Int
        var sortKey: ProcessSortKey
    }

    private var sortedInventoryCache: (sortKey: ProcessSortKey, processes: [AppProcess])?
    private var nameRanksCache: [String: Int]?
    /// A body pass needs one key per open presentation (flat and tree), so a
    /// few entries suffice. Without a cap, every search keystroke, slider step
    /// and filter kept its list until the next inventory replaced the caches.
    private static let maximumQueryCacheEntries = 8
    private var displayListCache: [DisplayListKey: DisplayList] = [:]
    private var treeRootsCache: [DisplayListKey: [ProcessTreeNode]] = [:]

    init(inventory: [AppProcess] = []) {
        self.inventory = inventory
    }

    var ppidMap: [Int32: Int32] {
        Dictionary(inventory.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { _, last in last })
    }

    mutating func displayProcesses(
        sortKey: ProcessSortKey,
        limit: Int,
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        Array(sortedInventory(by: sortKey).lazy.filter(predicate).prefix(max(0, limit)))
    }

    mutating func displayProcesses(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> [AppProcess] {
        displayList(for: query, sortKey: sortKey, limit: limit).processes
    }

    struct DisplayList {
        var processes: [AppProcess]
        var matchCount: Int
    }

    mutating func displayList(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> DisplayList {
        let key = DisplayListKey(query: query, limit: limit, sortKey: sortKey)
        if let cached = displayListCache[key] {
            return cached
        }
        let matches = sortedInventory(by: sortKey).filter(query.matches)
        let result = DisplayList(processes: Array(matches.prefix(max(0, limit))), matchCount: matches.count)
        if displayListCache.count >= Self.maximumQueryCacheEntries {
            displayListCache.removeAll(keepingCapacity: true)
        }
        displayListCache[key] = result
        return result
    }

    mutating func treeRoots(
        for query: ProcessListQuery,
        sortKey: ProcessSortKey,
        limit: Int
    ) -> [ProcessTreeNode] {
        let key = DisplayListKey(query: query, limit: limit, sortKey: sortKey)
        if let cached = treeRootsCache[key] {
            return cached
        }
        let matches = displayProcesses(for: query, sortKey: sortKey, limit: limit)
        let ranks = Dictionary(
            sortedInventory(by: sortKey).enumerated().map { ($0.element.pid, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let roots = ProcessTreeBuilder.build(
            from: inventory,
            ppidMap: ppidMap,
            matchingPIDs: Set(matches.map(\.pid)),
            sortRanks: ranks
        )
        if treeRootsCache.count >= Self.maximumQueryCacheEntries {
            treeRootsCache.removeAll(keepingCapacity: true)
        }
        treeRootsCache[key] = roots
        return roots
    }

    private mutating func sortedInventory(by sortKey: ProcessSortKey) -> [AppProcess] {
        if let cached = sortedInventoryCache, cached.sortKey == sortKey {
            return cached.processes
        }
        let processes: [AppProcess]
        if sortKey == .pid {
            processes = inventory.sorted { $0.pid < $1.pid }
        } else {
            // Most rows tie on CPU (0.0%), so ties are broken on each name's
            // natural-order rank, computed once per inventory, instead of running
            // localizedStandardCompare on every tied comparison. Rows with equal
            // names fall back to PID, as the Name sort always has, so the order
            // (and the tree built from it) never depends on `ps` output order.
            let ranks = nameRanks()
            processes = inventory
                .map { (process: $0, nameRank: ranks[$0.name] ?? 0) }
                .sorted { lhs, rhs in
                    switch sortKey {
                    case .cpu where lhs.process.cpu != rhs.process.cpu:
                        return lhs.process.cpu > rhs.process.cpu
                    case .memory where lhs.process.memoryMB != rhs.process.memoryMB:
                        return lhs.process.memoryMB > rhs.process.memoryMB
                    default:
                        return lhs.nameRank == rhs.nameRank
                            ? lhs.process.pid < rhs.process.pid
                            : lhs.nameRank < rhs.nameRank
                    }
                }
                .map(\.process)
        }
        sortedInventoryCache = (sortKey, processes)
        return processes
    }

    /// Natural (Finder-style) order of the inventory's distinct names as dense
    /// ranks; names that compare as equal share a rank.
    private mutating func nameRanks() -> [String: Int] {
        if let cached = nameRanksCache { return cached }
        let names = Set(inventory.map(\.name)).sorted {
            let comparison = $0.localizedStandardCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        var ranks: [String: Int] = [:]
        var rank = 0
        var previous: String?
        for name in names {
            if let previous, previous.localizedStandardCompare(name) != .orderedSame {
                rank += 1
            }
            ranks[name] = rank
            previous = name
        }
        nameRanksCache = ranks
        return ranks
    }
}
