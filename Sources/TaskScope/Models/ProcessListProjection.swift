import Foundation

enum ProcessSortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }

    var reversed: ProcessSortDirection {
        self == .ascending ? .descending : .ascending
    }

    /// What VoiceOver says for the active column title.
    var accessibilityValue: String {
        "sorted \(rawValue)"
    }
}

/// A sort key and its direction. Rows that tie on the key keep the ascending
/// name, then PID, order in either direction, and a row without a value for
/// the key sorts last in either direction.
struct ProcessSortOrder: Hashable, Sendable {
    var key: ProcessSortKey
    var direction: ProcessSortDirection

    /// Without a direction, the key's default one.
    init(key: ProcessSortKey, direction: ProcessSortDirection? = nil) {
        self.key = key
        self.direction = direction ?? key.defaultDirection
    }

    /// A click on a column title: the active column reverses, and another
    /// column starts in its default direction.
    func selectingColumn(_ column: ProcessSortKey) -> ProcessSortOrder {
        column == key
            ? ProcessSortOrder(key: key, direction: direction.reversed)
            : ProcessSortOrder(key: column)
    }
}

/// Read-only inventory with derived lists cached for its lifetime. Replacing the
/// projection replaces every cache together, so no list can outlive its inventory.
struct ProcessListProjection {
    let inventory: [AppProcess]
    private let readCommandLines: ([AppProcess]) -> CommandLineSearchIndex
    private var commandLineIndexCache: CommandLineSearchIndex?

    private struct DisplayListKey: Hashable {
        var query: ProcessListQuery
        var limit: Int
        var order: ProcessSortOrder
    }

    private var sortedInventoryCache: (order: ProcessSortOrder, processes: [AppProcess])?
    private var nameRanksCache: [String: Int]?
    private var ownerRanksCache: [String: Int]?
    /// A body pass needs one key per open presentation (flat and tree), so a
    /// few entries suffice. Without a cap, every search keystroke, slider step
    /// and filter kept its list until the next inventory replaced the caches.
    private static let maximumQueryCacheEntries = 8
    private var displayListCache: [DisplayListKey: DisplayList] = [:]
    private var treeRootsCache: [DisplayListKey: [ProcessTreeNode]] = [:]

    /// `readCommandLines` runs at most once per projection, and only for a
    /// search; the real one reads the kernel.
    init(
        inventory: [AppProcess] = [],
        readCommandLines: @escaping ([AppProcess]) -> CommandLineSearchIndex = { CommandLineSearchIndex.read(for: $0) }
    ) {
        self.inventory = inventory
        self.readCommandLines = readCommandLines
    }

    var ppidMap: [Int32: Int32] {
        Dictionary(inventory.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { _, last in last })
    }

    mutating func displayProcesses(
        order: ProcessSortOrder,
        limit: Int,
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        Array(sortedInventory(by: order).lazy.filter(predicate).prefix(max(0, limit)))
    }

    mutating func displayProcesses(
        for query: ProcessListQuery,
        order: ProcessSortOrder,
        limit: Int
    ) -> [AppProcess] {
        displayList(for: query, order: order, limit: limit).processes
    }

    struct DisplayList {
        var processes: [AppProcess]
        var matchCount: Int
        /// The displayed rows that match the search only in their command line.
        var commandLineMatches: Set<Int32> = []
    }

    /// The display limit applies after sorting, so it keeps the rows that rank
    /// first in the chosen order.
    mutating func displayList(
        for query: ProcessListQuery,
        order: ProcessSortOrder,
        limit: Int
    ) -> DisplayList {
        let key = DisplayListKey(query: query, limit: limit, order: order)
        if let cached = displayListCache[key] {
            return cached
        }
        let search = query.trimmedSearchText
        let commandLines = search.isEmpty ? nil : commandLineIndex()
        let commandLineQuery = CommandLineSearchIndex.Query(search)
        var commandLineOnly: Set<Int32> = []
        let matches = sortedInventory(by: order).filter { process in
            guard query.matchesFilter(process) else { return false }
            if query.matchesSearch(process) { return true }
            guard let commandLines, commandLines.contains(commandLineQuery, in: process.pid) else { return false }
            commandLineOnly.insert(process.pid)
            return true
        }
        let shown = Array(matches.prefix(max(0, limit)))
        let result = DisplayList(
            processes: shown,
            matchCount: matches.count,
            commandLineMatches: commandLineOnly.intersection(shown.map(\.pid))
        )
        if displayListCache.count >= Self.maximumQueryCacheEntries {
            displayListCache.removeAll(keepingCapacity: true)
        }
        displayListCache[key] = result
        return result
    }

    mutating func treeRoots(
        for query: ProcessListQuery,
        order: ProcessSortOrder,
        limit: Int
    ) -> [ProcessTreeNode] {
        let key = DisplayListKey(query: query, limit: limit, order: order)
        if let cached = treeRootsCache[key] {
            return cached
        }
        let matches = displayProcesses(for: query, order: order, limit: limit)
        let ranks = Dictionary(
            sortedInventory(by: order).enumerated().map { ($0.element.pid, $0.offset) },
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

    private mutating func commandLineIndex() -> CommandLineSearchIndex {
        if let cached = commandLineIndexCache { return cached }
        let index = readCommandLines(inventory)
        commandLineIndexCache = index
        return index
    }

    // The same reads in a key's default direction.

    mutating func displayProcesses(
        sortKey: ProcessSortKey,
        limit: Int,
        matching predicate: (AppProcess) -> Bool = { _ in true }
    ) -> [AppProcess] {
        displayProcesses(order: ProcessSortOrder(key: sortKey), limit: limit, matching: predicate)
    }

    mutating func displayProcesses(for query: ProcessListQuery, sortKey: ProcessSortKey, limit: Int) -> [AppProcess] {
        displayProcesses(for: query, order: ProcessSortOrder(key: sortKey), limit: limit)
    }

    mutating func displayList(for query: ProcessListQuery, sortKey: ProcessSortKey, limit: Int) -> DisplayList {
        displayList(for: query, order: ProcessSortOrder(key: sortKey), limit: limit)
    }

    mutating func treeRoots(for query: ProcessListQuery, sortKey: ProcessSortKey, limit: Int) -> [ProcessTreeNode] {
        treeRoots(for: query, order: ProcessSortOrder(key: sortKey), limit: limit)
    }

    private struct SortEntry {
        var process: AppProcess
        var nameRank: Int
        var ownerRank: Int?
    }

    private mutating func sortedInventory(by order: ProcessSortOrder) -> [AppProcess] {
        if let cached = sortedInventoryCache, cached.order == order {
            return cached.processes
        }
        // Most rows tie on CPU (0.0%), so ties are broken on each name's
        // natural-order rank, computed once per inventory, instead of running
        // localizedStandardCompare on every tied comparison. Rows with equal
        // names fall back to PID, as the Name sort always has, so the order
        // (and the tree built from it) never depends on `ps` output order.
        let names = nameRanks()
        let owners = order.key == .user ? ownerRanks() : [:]
        let processes = inventory
            .map { process in
                SortEntry(
                    process: process,
                    nameRank: names[process.name] ?? 0,
                    ownerRank: process.ownerName.flatMap { owners[$0] }
                )
            }
            .sorted { lhs, rhs in
                if let ordered = Self.keyOrder(lhs, rhs, order) { return ordered }
                return lhs.nameRank == rhs.nameRank
                    ? lhs.process.pid < rhs.process.pid
                    : lhs.nameRank < rhs.nameRank
            }
            .map(\.process)
        sortedInventoryCache = (order, processes)
        return processes
    }

    /// Whether `lhs` comes first on the order's key, or nil when they tie.
    private static func keyOrder(_ lhs: SortEntry, _ rhs: SortEntry, _ order: ProcessSortOrder) -> Bool? {
        let direction = order.direction
        switch order.key {
        case .cpu: return compare(lhs.process.cpu, rhs.process.cpu, direction)
        case .memory: return compare(lhs.process.memoryMB, rhs.process.memoryMB, direction)
        case .name: return compare(lhs.nameRank, rhs.nameRank, direction)
        case .pid: return compare(lhs.process.pid, rhs.process.pid, direction)
        case .parentPID: return compare(lhs.process.parentPID, rhs.process.parentPID, direction)
        case .user: return compare(lhs.ownerRank, rhs.ownerRank, direction)
        case .network: return compare(lhs.process.networkSortValue, rhs.process.networkSortValue, direction)
        case .disk: return compare(lhs.process.diskSortValue, rhs.process.diskSortValue, direction)
        }
    }

    /// A missing value sorts last in either direction.
    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        _ direction: ProcessSortDirection
    ) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (lhs?, rhs?):
            guard lhs != rhs else { return nil }
            return direction == .ascending ? lhs < rhs : lhs > rhs
        }
    }

    /// Natural order of the rows' owner names as ranks. The names come with
    /// the rows, so sorting looks nothing up.
    private mutating func ownerRanks() -> [String: Int] {
        if let cached = ownerRanksCache { return cached }
        let names = Set(inventory.compactMap(\.ownerName)).sorted {
            let comparison = $0.localizedStandardCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        let ranks = Dictionary(
            names.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        ownerRanksCache = ranks
        return ranks
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
