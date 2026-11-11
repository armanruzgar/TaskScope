import SwiftUI

/// What the menu-bar commands (Refresh, Find, Tree View, sections, Show Detail,
/// Copy and Export Visible Rows, Stop and Force Stop) act on: the TaskScope
/// view in the key window. Each
/// action goes through the same path as the matching control in that view, so
/// a stop from the menu still asks for confirmation.
struct TaskScopeViewCommands {
    var refresh: () -> Void
    var find: () -> Void
    var isTreeMode: Bool
    var setTreeMode: (Bool) -> Void
    var showSection: (TaskScopeSection) -> Void
    var hasKeyboardProcess: Bool
    var showDetail: () -> Void
    var hasVisibleRows: Bool = false
    var copyVisibleRows: () -> Void = {}
    var exportVisibleRows: () -> Void = {}
    var canStop: Bool
    var stop: (ProcessConfirmationState.TerminationMode) -> Void
}

private struct TaskScopeViewCommandsKey: FocusedValueKey {
    typealias Value = TaskScopeViewCommands
}

extension FocusedValues {
    var taskScopeCommands: TaskScopeViewCommands? {
        get { self[TaskScopeViewCommandsKey.self] }
        set { self[TaskScopeViewCommandsKey.self] = newValue }
    }
}
