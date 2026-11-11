import SwiftUI

/// The process list's keyboard focus, filter, tree mode and disclosure state,
/// and the decisions its key handlers make, kept out of the view so they can
/// be tested directly (ViewInspector cannot send key presses).
@MainActor
final class ProcessListInteractionState: ObservableObject {
    @Published var keyboardSelectedPid: Int32?
    /// The identity of the focused row, so a recycled PID cannot inherit focus
    /// and turn Return into a stop request for a different process.
    @Published var keyboardSelectedIdentity: ProcessIdentity?
    @Published var filterMode: ProcessFilterMode = .all
    @Published var treeMode = false
    @Published var expandedTreePids: Set<Int32> = []
    /// Displayed matches already seen in tree view; only matches that are new
    /// since the last update have their ancestors expanded.
    private(set) var knownMatches: Set<ProcessIdentity> = []

    /// The row an arrow key moves the focus to. Without focus, either arrow
    /// starts at the first row.
    static func nextFocus(current: Int32?, delta: Int, processes: [AppProcess]) -> AppProcess? {
        guard !processes.isEmpty else { return nil }
        let index = processes.firstIndex(where: { $0.pid == current }) ?? -1
        return processes[max(0, min(processes.count - 1, index + delta))]
    }

    /// What Select All may add: the displayed matches, and in tree view only
    /// those that are visible (never an ancestor shown for context).
    static func selectable(matches: [AppProcess], visible: [AppProcess]?) -> [AppProcess] {
        guard let visible else { return matches }
        let identities = Set(matches.map(\.identity))
        return visible.filter { identities.contains($0.identity) }
    }

    /// Expands the ancestors of displayed matches that are new since the last
    /// update, with or without a search, so every match is reachable. A branch
    /// the user collapsed stays collapsed until it gains a new match.
    func updateTree(matches: [AppProcess], roots: [ProcessTreeNode]) {
        let identities = Set(matches.map(\.identity))
        let added = identities.subtracting(knownMatches)
        knownMatches = identities
        guard !added.isEmpty else { return }
        func visit(_ node: ProcessTreeNode) -> Bool {
            let containsAdded = node.children.map(visit).contains(true)
            if containsAdded { expandedTreePids.insert(node.process.pid) }
            return containsAdded || added.contains(node.process.identity)
        }
        for root in roots { _ = visit(root) }
    }

    /// Drops the focus when its process exited or its PID now belongs to a
    /// different process.
    func retainLiveFocus(in processes: [AppProcess]) {
        guard let pid = keyboardSelectedPid else { return }
        guard let live = processes.first(where: { $0.pid == pid }),
              keyboardSelectedIdentity == nil || keyboardSelectedIdentity == live.identity else {
            keyboardSelectedPid = nil
            keyboardSelectedIdentity = nil
            return
        }
    }
}
