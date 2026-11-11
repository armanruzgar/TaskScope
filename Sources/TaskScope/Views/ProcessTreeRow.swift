import SwiftUI

struct ProcessTreeRow<ContextMenuContent: View>: View {
    var node: ProcessTreeNode
    var depth: Int
    var settings: SettingsStore
    @ObservedObject var processManager: ProcessManager
    @Binding var keyboardSelectedPid: Int32?
    @Binding var pendingTermination: AppProcess?
    @Binding var expandedPids: Set<Int32>
    var showsExpandedMetrics: Bool
    /// The displayed matches. Any other row is an ancestor shown only for
    /// hierarchy context. Nil when every row counts as a match.
    var matchedPIDs: Set<Int32>? = nil
    var requestListFocus: () -> Void = {}
    @ViewBuilder var contextMenuContent: (AppProcess) -> ContextMenuContent
    /// The row's context-menu actions for VoiceOver's Actions rotor.
    var accessibilityActionsContent: ((AppProcess) -> AnyView)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                ProcessRow(
                    process: node.process,
                    isCurrentProcess: processManager.isCurrentProcess(node.process),
                    isSelected: processManager.selectedPids.contains(node.process.pid),
                    isKeyboardSelected: keyboardSelectedPid == node.process.pid,
                    isHighlightedCPU: node.process.cpu >= settings.cpuHighlightThreshold,
                    isHighlightedMEM: node.process.memoryMB >= settings.memHighlightThresholdMB,
                    showsExpandedMetrics: showsExpandedMetrics,
                    leadingInset: 20 + CGFloat(depth) * 16,
                    treeLevel: depth + 1,
                    isContextOnly: matchedPIDs.map { !$0.contains(node.process.pid) } ?? false,
                    stopAction: { pendingTermination = node.process },
                    toggleSelection: { processManager.toggleSelection(node.process.pid) }
                )

                if !node.children.isEmpty {
                    Button {
                        if isExpanded {
                            expandedPids.remove(node.process.pid)
                        } else {
                            expandedPids.insert(node.process.pid)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
                    .layoutPriority(1)
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse children of \(node.process.name), PID \(String(node.process.pid))"
                            : "Expand children of \(node.process.name), PID \(String(node.process.pid))"
                    )
                    .padding(.leading, 4 + CGFloat(depth) * 16)
                } else {
                    // An invisible spacer that keeps leaf rows aligned; it is not
                    // a control and must not be announced.
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.clear)
                        .accessibilityHidden(true)
                        .frame(width: 20, height: 28)
                        .padding(.leading, 4 + CGFloat(depth) * 16)
                }
            }
            .background(
                keyboardSelectedPid == node.process.pid
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                keyboardSelectedPid = node.process.pid
                requestListFocus()
            }
            .id(node.process.pid)
            .contextMenu {
                contextMenuContent(node.process)
            }
            .accessibilityActions {
                if let accessibilityActionsContent {
                    accessibilityActionsContent(node.process)
                }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    ProcessTreeRow(
                        node: child,
                        depth: depth + 1,
                        settings: settings,
                        processManager: processManager,
                        keyboardSelectedPid: $keyboardSelectedPid,
                        pendingTermination: $pendingTermination,
                        expandedPids: $expandedPids,
                        showsExpandedMetrics: showsExpandedMetrics,
                        matchedPIDs: matchedPIDs,
                        requestListFocus: requestListFocus,
                        contextMenuContent: contextMenuContent,
                        accessibilityActionsContent: accessibilityActionsContent
                    )
                }
            }
        }
    }

    private var isExpanded: Bool {
        expandedPids.contains(node.process.pid)
    }
}
