import ApplicationServices
import AppKit
import Darwin
import Foundation

@MainActor
protocol ActivityMonitorAccessibilityRuntime {
    func isProcessTrusted(prompt: Bool) -> Bool
    func activityMonitorProcessIdentifier() -> pid_t?
    func selectProcessRow(
        applicationPID: pid_t,
        targetPID: Int32,
        timeout: TimeInterval
    ) async -> ActivityMonitorSelectionAttempt
    func restorePreparedState()
}

extension ActivityMonitorAccessibilityRuntime {
    func restorePreparedState() {}
}

@MainActor
struct SystemActivityMonitorProcessSelector: ActivityMonitorProcessSelecting {
    private let runtime: any ActivityMonitorAccessibilityRuntime

    init() {
        runtime = SystemActivityMonitorAccessibilityRuntime()
    }

    init(runtime: any ActivityMonitorAccessibilityRuntime) {
        self.runtime = runtime
    }

    func restorePreparedState() {
        runtime.restorePreparedState()
    }

    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        guard runtime.isProcessTrusted(prompt: true) else {
            return .accessibilityDenied(
                "macOS has not granted TaskScope permission to select another app's interface."
            )
        }

        guard let applicationPID = runtime.activityMonitorProcessIdentifier() else {
            return .notReady
        }

        return await runtime.selectProcessRow(
            applicationPID: applicationPID,
            targetPID: pid,
            timeout: timeout
        )
    }
}

/// Activity Monitor table state a handoff changed. Owned by the worker's serial
/// queue across attempts and restoration. `AXUIElement` is
/// a CF type without a Sendable annotation; every element here is used only on
/// the worker's serial queue.
struct ActivityMonitorPreparedTableState: @unchecked Sendable {
    var searchField: AXUIElement?
    var searchValue = ""
    /// The search text TaskScope typed; restoration is skipped when the field
    /// no longer holds it, because the user has moved on.
    var searchValueSet = ""
    var allProcessesItem: AXUIElement?
    var previousProcessScopeItem: AXUIElement?
    var processScopeChanged = false
    var processIDItem: AXUIElement?
    var processIDWasVisible = true
    var processIDWasShown = false
    var searchWasChanged = false
    /// True when the latest attempt selected the row. Restoration then keeps
    /// the search text and process scope that made the row visible, because
    /// putting them back would hide the row TaskScope reported as selected.
    var keepsSelectionVisible = false

    /// Types the process name into the search field. Without a name, an
    /// existing search is cleared instead, so it cannot keep hiding the row.
    mutating func updateSearch(processName: String?, setValue: (String) -> Bool) {
        let searchText = processName ?? ""
        guard (searchWasChanged ? searchValueSet : searchValue) != searchText,
              setValue(searchText) else { return }
        searchValueSet = searchText
        searchWasChanged = true
    }

    var hasChanges: Bool {
        processScopeChanged || processIDWasShown || searchWasChanged
    }
}

@MainActor
final class SystemActivityMonitorAccessibilityRuntime: ActivityMonitorAccessibilityRuntime {
    private static let activityMonitorBundleIdentifier = "com.apple.ActivityMonitor"
    static let applicationPath = "/System/Applications/Utilities/Activity Monitor.app"
    static let executablePath = applicationPath + "/Contents/MacOS/Activity Monitor"

    /// A running app that reports Activity Monitor's bundle identifier.
    struct ApplicationCandidate: Equatable {
        let pid: pid_t
        let bundlePath: String?
        let isTerminated: Bool
    }

    private let worker: ActivityMonitorAccessibilityWorker
    private let restorationDelayNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var restorationTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0

    init(
        worker: ActivityMonitorAccessibilityWorker = ActivityMonitorAccessibilityWorker(),
        restorationDelayNanoseconds: UInt64 = 4_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.worker = worker
        self.restorationDelayNanoseconds = restorationDelayNanoseconds
        self.sleep = sleep
    }

    func isProcessTrusted(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }

        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func activityMonitorProcessIdentifier() -> pid_t? {
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.activityMonitorBundleIdentifier
        ).map {
            ApplicationCandidate(
                pid: $0.processIdentifier,
                bundlePath: $0.bundleURL?.standardizedFileURL.path,
                isTerminated: $0.isTerminated
            )
        }
        return Self.systemActivityMonitorPID(
            in: candidates,
            executablePath: ProcessListReader.executablePath(for:)
        )
    }

    /// Any app can declare Activity Monitor's bundle identifier. Only the
    /// copy in /System, running its own executable, may be driven.
    static func systemActivityMonitorPID(
        in candidates: [ApplicationCandidate],
        executablePath: (pid_t) -> String?
    ) -> pid_t? {
        candidates.first { candidate in
            !candidate.isTerminated
                && candidate.bundlePath == applicationPath
                && executablePath(candidate.pid) == Self.executablePath
        }?.pid
    }

    /// State is captured and updated on the same queue as the AX calls, so
    /// overlapping attempts cannot overwrite the original table settings.
    func selectProcessRow(
        applicationPID: pid_t,
        targetPID: Int32,
        timeout: TimeInterval
    ) async -> ActivityMonitorSelectionAttempt {
        requestGeneration &+= 1
        let request = requestGeneration
        restorationTask?.cancel()
        restorationTask = nil
        let processName = Self.processName(for: targetPID)
        let outcome = await worker.selectOrPrepare(
            applicationPID: applicationPID,
            targetPID: targetPID,
            processName: processName,
            timeout: timeout
        )
        if request == requestGeneration, outcome.preparedState != nil {
            scheduleProcessTableRestoration(generation: outcome.generation)
        }
        return outcome.attempt
    }

    /// Restores immediately (app termination) instead of after the delay.
    func restorePreparedState() {
        requestGeneration &+= 1
        restorationTask?.cancel()
        restorationTask = nil
        worker.restoreNow()
    }

    private func scheduleProcessTableRestoration(generation: UInt64) {
        restorationTask?.cancel()
        let delay = restorationDelayNanoseconds
        let sleep = sleep
        restorationTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.restorationTask = nil
            await self.worker.restore(generation: generation)
        }
    }

    private static func processName(for pid: Int32) -> String? {
        searchName(
            localizedName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            kernelName: kernelProcessName(for: pid),
            executablePath: { ProcessListReader.executablePath(for: pid) }
        )
    }

    /// The name typed into Activity Monitor's search field. proc_name is
    /// refused for root-owned and other users' processes, but their kernel
    /// executable path stays readable, and Activity Monitor lists such
    /// processes under that file name.
    static func searchName(
        localizedName: String?,
        kernelName: String?,
        executablePath: () -> String?
    ) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        return nonEmpty(localizedName)
            ?? nonEmpty(kernelName)
            ?? nonEmpty(executablePath().map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    private static func kernelProcessName(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let byteCount = proc_name(pid, &buffer, UInt32(buffer.count))
        guard byteCount > 0 else {
            return nil
        }
        let bytes = buffer
            .prefix(Int(byteCount))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Identifies Activity Monitor menu items by title rather than by position, so a
/// menu that gained or lost an item cannot make TaskScope press the wrong one.
/// Failure to match means the corresponding table change is simply not made.
enum ActivityMonitorMenuMatcher {
    static let allProcessesTitles: Set<String> = ["all processes"]
    static let pidColumnTitles: Set<String> = ["pid", "process id"]

    static func allProcessesIndex(titles: [String?]) -> Int? {
        titles.firstIndex { allProcessesTitles.contains(normalized($0)) }
    }

    static func pidColumnIndex(titles: [String?]) -> Int? {
        titles.firstIndex { pidColumnTitles.contains(normalized($0)) }
    }

    /// The contiguous run of titled items around `index`, bounded by menu
    /// separators (items with no title). The process-scope radio group lives in
    /// exactly one such run.
    static func scopeGroupRange(titles: [String?], around index: Int) -> Range<Int> {
        guard titles.indices.contains(index) else { return index..<index }
        var lower = index
        while lower > 0, !isSeparator(titles[lower - 1]) {
            lower -= 1
        }
        var upper = index + 1
        while upper < titles.count, !isSeparator(titles[upper]) {
            upper += 1
        }
        return lower..<upper
    }

    private static func normalized(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isSeparator(_ title: String?) -> Bool {
        normalized(title).isEmpty
    }
}

/// The Accessibility calls the worker makes. Tests supply an in-memory element
/// tree; production forwards to the AX C functions. Every call is made on the
/// worker's queue.
protocol ActivityMonitorAXTransport: Sendable {
    func applicationElement(pid: pid_t) -> AXUIElement
    func setTimeout(_ element: AXUIElement, seconds: Float)
    func copyAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?) -> AXError
    func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError
    func performAction(_ element: AXUIElement, _ action: CFString) -> AXError
}

struct SystemActivityMonitorAXTransport: ActivityMonitorAXTransport {
    func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func setTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    func copyAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?) -> AXError {
        AXUIElementCopyAttributeValue(element, attribute, &value)
    }

    func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute, value)
    }

    func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        AXUIElementPerformAction(element, action)
    }
}

/// Runs all Accessibility traffic on one serial queue. AX calls are synchronous
/// IPC into Activity Monitor; performed on the main actor for every row and
/// cell, up to eight attempts, they froze TaskScope's own UI.
final class ActivityMonitorAccessibilityWorker: @unchecked Sendable {
    struct Outcome: @unchecked Sendable {
        var attempt: ActivityMonitorSelectionAttempt
        var preparedState: ActivityMonitorPreparedTableState?
        var generation: UInt64 = 0
    }

    typealias Selection = @Sendable (pid_t, Int32, String?, ActivityMonitorPreparedTableState?) -> Outcome
    typealias Restoration = @Sendable (ActivityMonitorPreparedTableState) -> Void

    /// Upper bound for one Accessibility request; a request never gets more
    /// than what is left of its attempt's deadline either.
    static let requestTimeout: TimeInterval = 1
    static let restorationTimeout: TimeInterval = 2

    private let selection: Selection?
    private let restoration: Restoration?
    private let transport: any ActivityMonitorAXTransport
    // Accessed exclusively on queue, including synchronous shutdown.
    private var preparedState: ActivityMonitorPreparedTableState?
    /// The Activity Monitor process whose elements `preparedState` holds.
    private var preparedApplicationPID: pid_t?
    private var generation: UInt64 = 0
    private var deadline = TimeInterval.infinity
    private var stoppedResponding = false
    private static let maximumTreeDepth = 12
    private let queue = DispatchQueue(
        label: "TaskScope.ActivityMonitorAccessibility",
        qos: .userInitiated
    )

    init(
        selection: Selection? = nil,
        restoration: Restoration? = nil,
        transport: any ActivityMonitorAXTransport = SystemActivityMonitorAXTransport()
    ) {
        self.selection = selection
        self.restoration = restoration
        self.transport = transport
    }

    @MainActor
    func selectOrPrepare(
        applicationPID: pid_t,
        targetPID: Int32,
        processName: String?,
        timeout: TimeInterval = 5
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                // State captured from an Activity Monitor that has quit holds
                // dead elements and must not be carried into a new instance:
                // the new instance is captured afresh.
                if self.preparedApplicationPID != applicationPID {
                    self.preparedState = nil
                }
                self.beginRequests(timeout: timeout)
                var outcome: Outcome
                if let selection = self.selection {
                    outcome = selection(applicationPID, targetPID, processName, self.preparedState)
                } else {
                    outcome = self.performSelectOrPrepare(
                        applicationPID: applicationPID,
                        targetPID: targetPID,
                        processName: processName,
                        existingState: self.preparedState
                    )
                }
                if self.stoppedResponding, outcome.attempt == .notReady {
                    outcome.attempt = .unresponsive
                }
                outcome.preparedState?.keepsSelectionVisible = outcome.attempt == .selected
                self.preparedState = outcome.preparedState
                self.preparedApplicationPID = applicationPID
                self.generation &+= 1
                outcome.generation = self.generation
                continuation.resume(returning: outcome)
            }
        }
    }

    @MainActor
    func restore(generation: UInt64) async {
        await withCheckedContinuation { continuation in
            queue.async {
                // A timer from an earlier handoff must not undo a newer one.
                if generation == self.generation {
                    self.restoreOnQueue()
                }
                continuation.resume()
            }
        }
    }

    /// Synchronous variant for application termination, where an async hop
    /// would never complete. The wait is bounded: a handoff still walking an
    /// unresponsive Activity Monitor must not hang TaskScope's quit.
    func restoreNow(timeout: TimeInterval = 3) {
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            restoreOnQueue()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)
    }

    private func restoreOnQueue() {
        guard var state = preparedState else { return }
        preparedState = nil
        preparedApplicationPID = nil
        beginRequests(timeout: Self.restorationTimeout)
        if state.keepsSelectionVisible {
            // The search and scope are what made the selected row visible.
            // Only the PID column, which never hides a row, is hidden again.
            state.searchWasChanged = false
            state.processScopeChanged = false
        }
        if let restoration {
            restoration(state)
        } else {
            performRestore(state)
        }
    }

    private func beginRequests(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        stoppedResponding = false
    }

    /// Bounds the next request by `requestTimeout` and the attempt's deadline.
    /// After one request times out, the rest of the attempt is skipped instead
    /// of every remaining request waiting out its own timeout.
    private func prepareRequest(_ element: AXUIElement) -> Bool {
        guard !stoppedResponding else { return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        transport.setTimeout(element, seconds: Float(min(Self.requestTimeout, remaining)))
        return true
    }

    private func recordResult(_ error: AXError) -> AXError {
        if error == .cannotComplete {
            stoppedResponding = true
        }
        return error
    }

    private func setAttribute(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        guard prepareRequest(element) else { return .cannotComplete }
        return recordResult(transport.setAttribute(element, attribute as CFString, value))
    }

    private func performAction(_ element: AXUIElement, _ action: String) -> AXError {
        guard prepareRequest(element) else { return .cannotComplete }
        return recordResult(transport.performAction(element, action as CFString))
    }

    private func performSelectOrPrepare(
        applicationPID: pid_t,
        targetPID: Int32,
        processName: String?,
        existingState: ActivityMonitorPreparedTableState?
    ) -> Outcome {
        let application = transport.applicationElement(pid: applicationPID)

        if let rowSelection = selectVisibleRow(in: application, targetPID: targetPID) {
            return Outcome(attempt: rowSelection, preparedState: existingState)
        }

        // A user's existing search or process-scope choice can hide an otherwise
        // valid PID. Normalize only the state needed for a visible handoff, then
        // let the coordinator retry after Activity Monitor refreshes its table.
        let state = prepareProcessTable(
            in: application,
            processName: processName,
            existingState: existingState
        )
        return Outcome(attempt: .notReady, preparedState: state.hasChanges ? state : nil)
    }

    private func selectVisibleRow(
        in application: AXUIElement,
        targetPID: Int32
    ) -> ActivityMonitorSelectionAttempt? {
        guard let windows = elements(application, attribute: kAXWindowsAttribute) else {
            return nil
        }

        for window in windows {
            guard let outline = firstDescendant(
                of: window,
                role: kAXOutlineRole,
                remainingDepth: Self.maximumTreeDepth
            ),
            let columns = elements(outline, attribute: kAXColumnsAttribute),
            // Resolved once per outline, not once per row.
            let pidColumnIndex = ActivityMonitorPIDCellMatcher.pidColumnIndex(
                in: columns.map { string($0, attribute: kAXIdentifierAttribute) }
            ),
            let rows = elements(outline, attribute: kAXRowsAttribute) else {
                continue
            }

            for row in rows {
                guard let cells = elements(row, attribute: kAXChildrenAttribute),
                      let pidCell = pidCell(in: cells, pidColumnIndex: pidColumnIndex) else {
                    continue
                }

                let pidValueMatches = ActivityMonitorPIDCellMatcher.matches(
                    value: value(pidCell, attribute: kAXValueAttribute),
                    targetPID: targetPID
                )
                let childValueMatches = pidValueMatches ? false : (elements(
                    pidCell,
                    attribute: kAXChildrenAttribute
                )?.contains(where: {
                    ActivityMonitorPIDCellMatcher.matches(
                        value: value($0, attribute: kAXValueAttribute),
                        targetPID: targetPID
                    )
                }) ?? false)
                guard pidValueMatches || childValueMatches else {
                    continue
                }

                let selectionError = setAttribute(
                    outline,
                    kAXSelectedRowsAttribute,
                    [row] as CFArray
                )
                if selectionError != .success {
                    let rowSelectionError = setAttribute(
                        row,
                        kAXSelectedAttribute,
                        kCFBooleanTrue
                    )
                    guard rowSelectionError == .success else {
                        return selectionAttempt(for: rowSelectionError)
                    }
                }

                return .selected
            }
        }

        return nil
    }

    /// Reads only the PID cell of a row. The cell at the column's index is
    /// checked against its own column range first; only when the row omits
    /// empty cells does this fall back to scanning every cell's range.
    private func pidCell(in cells: [AXUIElement], pidColumnIndex: Int) -> AXUIElement? {
        if cells.indices.contains(pidColumnIndex),
           let range = indexRange(cells[pidColumnIndex], attribute: kAXColumnIndexRangeAttribute),
           ActivityMonitorPIDCellMatcher.cellIndex(columnRanges: [range], containing: pidColumnIndex) == 0 {
            return cells[pidColumnIndex]
        }
        guard let index = ActivityMonitorPIDCellMatcher.cellIndex(
            columnRanges: cells.map { indexRange($0, attribute: kAXColumnIndexRangeAttribute) },
            containing: pidColumnIndex
        ) else {
            return nil
        }
        return cells[index]
    }

    private func prepareProcessTable(
        in application: AXUIElement,
        processName: String?,
        existingState: ActivityMonitorPreparedTableState?
    ) -> ActivityMonitorPreparedTableState {
        var state = existingState ?? captureProcessTableState(in: application)

        // Each change is recorded only after the menu confirms it took effect,
        // so restoration never presses an item that was not actually toggled.
        if !state.processScopeChanged,
           let allProcessesItem = state.allProcessesItem,
           let previousProcessScopeItem = state.previousProcessScopeItem,
           performAction(allProcessesItem, kAXPressAction) == .success,
           isMarked(allProcessesItem) {
            state.previousProcessScopeItem = previousProcessScopeItem
            state.processScopeChanged = true
        }

        if !state.processIDWasVisible,
           !state.processIDWasShown,
           let processIDItem = state.processIDItem,
           performAction(processIDItem, kAXPressAction) == .success,
           isMarked(processIDItem) {
            state.processIDWasShown = true
        }

        let searchField = state.searchField
        state.updateSearch(processName: processName) { name in
            guard let searchField,
                  setAttribute(searchField, kAXValueAttribute, name as CFString) == .success else { return false }
            _ = performAction(searchField, kAXConfirmAction)
            return true
        }

        return state
    }

    private func captureProcessTableState(
        in application: AXUIElement
    ) -> ActivityMonitorPreparedTableState {
        var state = ActivityMonitorPreparedTableState()

        if let searchField = processTableSearchField(in: application) {
            state.searchField = searchField
            state.searchValue = string(searchField, attribute: kAXValueAttribute) ?? ""
        }

        guard let viewMenuItems = activityMonitorViewMenuItems(in: application) else {
            return state
        }

        let viewTitles = viewMenuItems.map { string($0, attribute: kAXTitleAttribute) }
        if let allProcessesIndex = ActivityMonitorMenuMatcher.allProcessesIndex(titles: viewTitles) {
            let allProcessesItem = viewMenuItems[allProcessesIndex]
            state.allProcessesItem = allProcessesItem
            if !isMarked(allProcessesItem) {
                let group = ActivityMonitorMenuMatcher.scopeGroupRange(
                    titles: viewTitles,
                    around: allProcessesIndex
                )
                state.previousProcessScopeItem = viewMenuItems[group].first(where: isMarked)
            }
        }

        if let columnsMenu = viewMenuItems.first,
           let submenu = elements(columnsMenu, attribute: kAXChildrenAttribute)?.first,
           let columnItems = elements(submenu, attribute: kAXChildrenAttribute) {
            let columnTitles = columnItems.map { string($0, attribute: kAXTitleAttribute) }
            if let pidIndex = ActivityMonitorMenuMatcher.pidColumnIndex(titles: columnTitles) {
                state.processIDItem = columnItems[pidIndex]
                state.processIDWasVisible = isMarked(columnItems[pidIndex])
            }
        }

        return state
    }

    /// Finds the search field of the window that shows the process table.
    /// Activity Monitor's History, CPU Usage and Inspector windows have no
    /// search field and can be first in the window list, so windows are tried
    /// in the order chosen by ActivityMonitorWindowOrder.
    private func processTableSearchField(in application: AXUIElement) -> AXUIElement? {
        guard let windows = elements(application, attribute: kAXWindowsAttribute),
              !windows.isEmpty else {
            return nil
        }
        let mainWindow = element(application, attribute: kAXMainWindowAttribute)
        let ordered = ActivityMonitorWindowOrder.searchFieldCandidates(
            windows,
            holdsProcessOutline: { window in
                firstDescendant(
                    of: window,
                    role: kAXOutlineRole,
                    remainingDepth: Self.maximumTreeDepth
                ) != nil
            },
            isMainWindow: { window in
                mainWindow.map { CFEqual($0, window) } ?? false
            }
        )
        for window in ordered {
            if let searchField = firstDescendant(
                of: window,
                subrole: kAXSearchFieldSubrole,
                remainingDepth: Self.maximumTreeDepth
            ) {
                return searchField
            }
        }
        return nil
    }

    /// Each field is put back only when it still holds the value TaskScope set.
    /// If the user changed the search, the scope, or the column since the
    /// handoff, their choice wins and that field is left alone.
    private func performRestore(_ state: ActivityMonitorPreparedTableState) {
        if state.searchWasChanged,
           let searchField = state.searchField,
           string(searchField, attribute: kAXValueAttribute) ?? "" == state.searchValueSet {
            if setAttribute(searchField, kAXValueAttribute, state.searchValue as CFString) == .success {
                _ = performAction(searchField, kAXConfirmAction)
            }
        }
        if state.processScopeChanged,
           let allProcessesItem = state.allProcessesItem,
           isMarked(allProcessesItem),
           let item = state.previousProcessScopeItem {
            _ = performAction(item, kAXPressAction)
        }
        if state.processIDWasShown,
           let item = state.processIDItem,
           isMarked(item) {
            _ = performAction(item, kAXPressAction)
        }
    }

    private func isMarked(_ element: AXUIElement) -> Bool {
        guard let mark = string(element, attribute: kAXMenuItemMarkCharAttribute) else {
            return false
        }
        return !mark.isEmpty
    }

    private func activityMonitorViewMenuItems(in application: AXUIElement) -> [AXUIElement]? {
        guard let menuBar = element(application, attribute: kAXMenuBarAttribute),
              let menuBarItems = elements(menuBar, attribute: kAXChildrenAttribute) else {
            return nil
        }

        // The View menu is identified structurally, without localized labels:
        // its first item is the Columns submenu, whose first child contains the
        // long list of selectable process columns. Individual items inside it
        // are then matched by title.
        for menuBarItem in menuBarItems {
            guard let menu = elements(menuBarItem, attribute: kAXChildrenAttribute)?.first,
                  let items = elements(menu, attribute: kAXChildrenAttribute),
                  let firstItem = items.first,
                  let columnsSubmenu = elements(
                      firstItem,
                      attribute: kAXChildrenAttribute
                  )?.first,
                  let columnItems = elements(
                      columnsSubmenu,
                      attribute: kAXChildrenAttribute
                  ),
                  columnItems.count >= 20 else {
                continue
            }
            return items
        }

        return nil
    }

    private func firstDescendant(
        of element: AXUIElement,
        role: String,
        remainingDepth: Int
    ) -> AXUIElement? {
        if string(element, attribute: kAXRoleAttribute) == role {
            return element
        }
        guard remainingDepth > 0,
              let children = elements(element, attribute: kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            if let match = firstDescendant(
                of: child,
                role: role,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private func firstDescendant(
        of element: AXUIElement,
        subrole: String,
        remainingDepth: Int
    ) -> AXUIElement? {
        if string(element, attribute: kAXSubroleAttribute) == subrole {
            return element
        }
        guard remainingDepth > 0,
              let children = elements(element, attribute: kAXChildrenAttribute) else {
            return nil
        }
        for child in children {
            if let match = firstDescendant(
                of: child,
                subrole: subrole,
                remainingDepth: remainingDepth - 1
            ) {
                return match
            }
        }
        return nil
    }

    private func selectionAttempt(for error: AXError) -> ActivityMonitorSelectionAttempt {
        switch error {
        case .apiDisabled:
            return .accessibilityDenied("macOS rejected the Accessibility operation.")
        case .cannotComplete, .invalidUIElement:
            return .notReady
        default:
            return .failed("Activity Monitor Accessibility operation failed (\(error.rawValue)).")
        }
    }

    private func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let rawValue = value(element, attribute: attribute),
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        value(element, attribute: attribute) as? [AXUIElement]
    }

    private func string(_ element: AXUIElement, attribute: String) -> String? {
        value(element, attribute: attribute) as? String
    }

    private func indexRange(_ element: AXUIElement, attribute: String) -> CFRange? {
        guard let rawValue = value(element, attribute: attribute),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func value(_ element: AXUIElement, attribute: String) -> AnyObject? {
        guard prepareRequest(element) else { return nil }
        var value: CFTypeRef?
        guard recordResult(transport.copyAttribute(element, attribute as CFString, &value)) == .success else {
            return nil
        }
        return value
    }
}

enum ActivityMonitorWindowOrder {
    /// Orders windows for the search field lookup: windows holding the process
    /// outline first, then the main window, then every other window. The
    /// original front-to-back order is kept within each group.
    static func searchFieldCandidates<Window>(
        _ windows: [Window],
        holdsProcessOutline: (Window) -> Bool,
        isMainWindow: (Window) -> Bool
    ) -> [Window] {
        let ranked = windows.enumerated().map { offset, window -> (rank: Int, offset: Int, window: Window) in
            let rank = holdsProcessOutline(window) ? 0 : (isMainWindow(window) ? 1 : 2)
            return (rank, offset, window)
        }
        return ranked
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.window)
    }
}

enum ActivityMonitorPIDCellMatcher {
    static func pidColumnIndex(in identifiers: [String?]) -> Int? {
        identifiers.firstIndex(where: { $0 == "PID" })
    }

    static func cellIndex(
        columnRanges: [CFRange?],
        containing columnIndex: Int
    ) -> Int? {
        guard columnIndex >= 0 else {
            return nil
        }
        let requestedIndex = CFIndex(columnIndex)

        return columnRanges.firstIndex(where: { optionalRange in
            guard let range = optionalRange,
                  range.location >= 0,
                  range.length > 0 else {
                return false
            }
            return requestedIndex >= range.location
                && requestedIndex - range.location < range.length
        })
    }

    static func matches(value: AnyObject?, targetPID: Int32) -> Bool {
        if let string = value as? String {
            return string == String(targetPID)
        }
        if let number = value as? NSNumber {
            return number.stringValue == String(targetPID)
        }
        return false
    }
}
