import Combine

/// Keeps the report the user is reading on screen even if another action
/// (the menu-bar popover, Shortcuts, Keep Off enforcement) replaces or clears
/// the manager's latest report. A newer report waits until Done.
@MainActor
final class ProcessReportPresentationState: ObservableObject {
    private(set) var lifecycle: LifecycleReport?
    private(set) var batch: ProcessBatchActionReport?

    /// Read while rendering, so it never publishes: only the first report seen
    /// is kept until it is dismissed.
    func retain(_ report: LifecycleReport?) -> LifecycleReport? {
        if lifecycle == nil { lifecycle = report }
        return lifecycle
    }

    func retain(_ report: ProcessBatchActionReport?) -> ProcessBatchActionReport? {
        if batch == nil { batch = report }
        return batch
    }

    /// The view stopped owning report presentation, so nothing it kept is on
    /// screen any more. Read while rendering; does not publish.
    func forgetUnpresented() {
        lifecycle = nil
        batch = nil
    }

    func dismissLifecycle() {
        objectWillChange.send()
        lifecycle = nil
    }

    func dismissBatch() {
        objectWillChange.send()
        batch = nil
    }
}
