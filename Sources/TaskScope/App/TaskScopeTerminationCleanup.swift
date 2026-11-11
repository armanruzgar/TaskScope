import Foundation

/// Work that must happen when TaskScope terminates: put back Activity Monitor
/// changes from a handoff whose restoration delay has not elapsed. (Saving
/// pending settings is TaskScopeRuntime.stop's job.) A separate type so the
/// app's termination wiring is testable.
@MainActor
struct TaskScopeTerminationCleanup {
    let activityMonitor: any ActivityMonitorCoordinating

    func perform() {
        activityMonitor.restoreActivityMonitorState()
    }
}
