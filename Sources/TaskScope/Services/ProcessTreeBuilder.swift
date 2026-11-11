import Foundation

struct ProcessTreeNode: Identifiable, Equatable {
    var process: AppProcess
    var children: [ProcessTreeNode]
    var id: Int32 { process.pid }
}

enum ProcessTreeBuilder {
    static func visibleProcesses(
        in roots: [ProcessTreeNode],
        expandedPIDs: Set<Int32>
    ) -> [AppProcess] {
        roots.flatMap { node in
            var visible = [node.process]
            if expandedPIDs.contains(node.process.pid) {
                visible.append(contentsOf: visibleProcesses(
                    in: node.children,
                    expandedPIDs: expandedPIDs
                ))
            }
            return visible
        }
    }

    /// Builds a stable tree and, when `matchingPIDs` is supplied, retains every
    /// available ancestor needed to give matching rows hierarchy context. Roots
    /// and each parent's children are ordered by `sortRanks` (the list's sort
    /// order, lowest first), with PID as the tie-break and for unranked rows.
    static func build(
        from processes: [AppProcess],
        ppidMap: [Int32: Int32],
        matchingPIDs: Set<Int32>? = nil,
        sortRanks: [Int32: Int] = [:]
    ) -> [ProcessTreeNode] {
        // A repeated pid cannot come from the parser, which rejects it, but a
        // duplicate must never crash the view; the first row wins.
        let allByID = Dictionary(
            processes.map { ($0.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let includedIDs = includedProcessIDs(
            allIDs: Set(allByID.keys),
            ppidMap: ppidMap,
            matchingPIDs: matchingPIDs
        )
        let nodesByID = allByID.filter { includedIDs.contains($0.key) }
        var effectiveParent: [Int32: Int32] = [:]

        for pid in includedIDs {
            guard let parent = ppidMap[pid],
                  parent != 0,
                  includedIDs.contains(parent) else {
                continue
            }
            effectiveParent[pid] = parent
        }

        breakCycles(in: &effectiveParent, includedIDs: includedIDs)

        var childPIDsByParent: [Int32: [Int32]] = [:]
        for (child, parent) in effectiveParent {
            childPIDsByParent[parent, default: []].append(child)
        }
        func precedes(_ lhs: Int32, _ rhs: Int32) -> Bool {
            let left = sortRanks[lhs, default: Int.max]
            let right = sortRanks[rhs, default: Int.max]
            return left == right ? lhs < rhs : left < right
        }
        for parent in childPIDsByParent.keys {
            childPIDsByParent[parent]?.sort(by: precedes)
        }

        let rootPIDs = includedIDs
            .filter { effectiveParent[$0] == nil }
            .sorted(by: precedes)

        func buildNode(_ pid: Int32, ancestors: Set<Int32>) -> ProcessTreeNode? {
            guard let process = nodesByID[pid], !ancestors.contains(pid) else { return nil }
            var nextAncestors = ancestors
            nextAncestors.insert(pid)
            let children = (childPIDsByParent[pid] ?? []).compactMap {
                buildNode($0, ancestors: nextAncestors)
            }
            return ProcessTreeNode(process: process, children: children)
        }

        return rootPIDs.compactMap { buildNode($0, ancestors: []) }
    }

    private static func includedProcessIDs(
        allIDs: Set<Int32>,
        ppidMap: [Int32: Int32],
        matchingPIDs: Set<Int32>?
    ) -> Set<Int32> {
        guard let matchingPIDs else { return allIDs }
        var included = matchingPIDs.intersection(allIDs)

        for match in matchingPIDs {
            var current = match
            var visited: Set<Int32> = []
            while visited.insert(current).inserted,
                  let parent = ppidMap[current],
                  parent != 0,
                  allIDs.contains(parent) {
                included.insert(parent)
                current = parent
            }
        }
        return included
    }

    private static func breakCycles(
        in parents: inout [Int32: Int32],
        includedIDs: Set<Int32>
    ) {
        var globallyVisited: Set<Int32> = []

        for start in includedIDs.sorted() where !globallyVisited.contains(start) {
            var path: [Int32] = []
            var position: [Int32: Int] = [:]
            var current: Int32? = start

            while let pid = current, includedIDs.contains(pid) {
                if let cycleStart = position[pid] {
                    let cycle = Array(path[cycleStart...])
                    if let deterministicRoot = cycle.min() {
                        parents.removeValue(forKey: deterministicRoot)
                    }
                    break
                }
                if globallyVisited.contains(pid) { break }
                position[pid] = path.count
                path.append(pid)
                current = parents[pid]
            }
            globallyVisited.formUnion(path)
        }
    }
}
