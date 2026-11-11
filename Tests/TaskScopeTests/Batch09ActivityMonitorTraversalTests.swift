import ApplicationServices
import XCTest
@testable import TaskScope

/// The worker's Accessibility traversal against an in-memory Activity Monitor.
@MainActor
final class Batch09ActivityMonitorTraversalTests: XCTestCase {
    private let target = Batch09FakeActivityMonitor.Process(pid: 1, name: "launchd", mine: false)
    private let mine = Batch09FakeActivityMonitor.Process(pid: 4321, name: "Safari", mine: true)

    func testVisibleRowIsSelectedWithoutChangingTheTable() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")

        XCTAssertEqual(outcome.attempt, .selected)
        XCTAssertNil(outcome.preparedState)
        XCTAssertEqual(monitor.selectedPID, 1)
        XCTAssertTrue(monitor.requestTimeouts.allSatisfy { $0 > 0 && $0 <= 1 }, "\(monitor.requestTimeouts)")
    }

    // A03-3: the handoff widened the scope, showed the PID column and replaced
    // the search. After it selected the row, restoration hides the PID column
    // again but keeps the scope and search, so the row stays listed.
    func testRestorationAfterASelectionKeepsTheRowListed() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let prepared = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(prepared.attempt, .notReady)
        XCTAssertEqual(monitor.scope, .all)
        XCTAssertTrue(monitor.pidColumnVisible)
        XCTAssertEqual(monitor.search, "launchd")

        let selected = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(selected.attempt, .selected)
        XCTAssertEqual(monitor.selectedPID, 1)

        worker.restoreNow()

        XCTAssertFalse(monitor.pidColumnVisible, "the PID column is hidden again")
        XCTAssertEqual(monitor.scope, .all, "My Processes would hide the selected root-owned row")
        XCTAssertEqual(monitor.search, "launchd", "the old search would hide the selected row")
        XCTAssertTrue(monitor.listedPIDs.contains(1))
    }

    func testRestorationAfterAFailedHandoffPutsEverythingBack() async {
        let absent = Batch09FakeActivityMonitor.Process(pid: 77, name: "ghost", mine: false)
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let first = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)
        let second = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)
        XCTAssertEqual(first.attempt, .notReady)
        XCTAssertEqual(second.attempt, .notReady)

        worker.restoreNow()

        XCTAssertEqual(monitor.scope, .mine)
        XCTAssertFalse(monitor.pidColumnVisible)
        XCTAssertEqual(monitor.search, "chrome")
    }

    func testRestorationLeavesASearchTheUserChangedAfterTheHandoff() async {
        let absent = Batch09FakeActivityMonitor.Process(pid: 77, name: "ghost", mine: false)
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: false, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)
        _ = await worker.selectOrPrepare(applicationPID: 900, targetPID: absent.pid, processName: absent.name)

        monitor.userTypesSearch("mail")
        worker.restoreNow()

        XCTAssertEqual(monitor.search, "mail", "the user's own search wins")
        XCTAssertEqual(monitor.scope, .mine, "fields the user did not touch are still restored")
        XCTAssertFalse(monitor.pidColumnVisible)
    }

    // A03-6: without any name for the target, a stale search is cleared
    // instead of being left to hide the row.
    func testUnknownNameClearsAStaleSearch() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .all, pidColumnVisible: true, search: "chrome"
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let prepared = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: nil)
        XCTAssertEqual(prepared.attempt, .notReady)
        XCTAssertEqual(monitor.search, "")

        let selected = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: nil)
        XCTAssertEqual(selected.attempt, .selected)
        XCTAssertEqual(monitor.selectedPID, 1)
    }

    // A03-7: a request that cannot complete ends the attempt at once instead
    // of every further request waiting out its own timeout, and the attempt
    // reports that Activity Monitor is not responding.
    func testUnresponsiveActivityMonitorEndsTheAttemptAfterOneRequest() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        monitor.isResponding = false
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")

        XCTAssertEqual(outcome.attempt, .unresponsive)
        XCTAssertEqual(monitor.requestCount, 1)
        XCTAssertEqual(monitor.requestTimeouts, [1])
    }

    func testAnUnresponsiveAttemptKeepsStateFromEarlierAttempts() async {
        let monitor = Batch09FakeActivityMonitor(
            processes: [mine, target], scope: .mine, pidColumnVisible: true, search: ""
        )
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)
        _ = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(monitor.scope, .all)

        monitor.isResponding = false
        let stalled = await worker.selectOrPrepare(applicationPID: 900, targetPID: 1, processName: "launchd")
        XCTAssertEqual(stalled.attempt, .unresponsive)
        XCTAssertNotNil(stalled.preparedState, "what the handoff changed must still be restorable")

        monitor.isResponding = true
        worker.restoreNow()
        XCTAssertEqual(monitor.scope, .mine)
        XCTAssertEqual(monitor.search, "")
    }

    func testTheAttemptDeadlineBoundsEveryRequest() async {
        let monitor = Batch09FakeActivityMonitor(processes: [mine, target], scope: .all, pidColumnVisible: true)
        let worker = ActivityMonitorAccessibilityWorker(transport: monitor)

        let outcome = await worker.selectOrPrepare(
            applicationPID: 900, targetPID: 1, processName: "launchd", timeout: 0.25
        )

        XCTAssertEqual(outcome.attempt, .selected)
        XCTAssertFalse(monitor.requestTimeouts.isEmpty)
        XCTAssertTrue(monitor.requestTimeouts.allSatisfy { $0 > 0 && $0 <= 0.25 }, "\(monitor.requestTimeouts)")

        let expired = await worker.selectOrPrepare(
            applicationPID: 900, targetPID: 1, processName: "launchd", timeout: 0
        )
        XCTAssertEqual(expired.attempt, .notReady, "an exhausted budget makes no requests")
    }
}

/// An in-memory Activity Monitor: a window with a search field and a process
/// outline, and a View menu with the Columns submenu and the process scopes.
/// Elements are application elements for made-up PIDs, used only as tokens:
/// no request ever reaches the Accessibility API.
final class Batch09FakeActivityMonitor: ActivityMonitorAXTransport, @unchecked Sendable {
    struct Process: Equatable {
        let pid: Int32
        let name: String
        let mine: Bool
    }

    enum Scope { case mine, all }

    private enum Node: Hashable {
        case application, window, searchField, outline
        case column(Int), row(Int32), cell(Int32, Int)
        case menuBar, fileMenuBarItem, fileMenu, fileFirstItem
        case viewMenuBarItem, viewMenu, columnsItem, columnsSubmenu, columnItem(Int)
        case separator(Int), myProcessesItem, allProcessesItem
    }

    private let lock = NSLock()
    private let processes: [Process]
    private var _scope: Scope
    private var _pidColumnVisible: Bool
    private var _search: String
    private var _selectedPID: Int32?
    private var _isResponding = true
    private var _windowsReady = true
    private var _requestCount = 0
    private var _requestTimeouts: [Float] = []
    private var nodes: [pid_t: Node] = [:]
    private var tokens: [Node: pid_t] = [:]
    private static let columnTitles = ["Process Name", "% CPU", "CPU Time", "Threads", "Idle Wake Ups", "Kind",
                                       "% GPU", "GPU Time", "PID", "User", "Ports", "Memory", "Real Memory",
                                       "Purgeable Memory", "Compressed Memory", "Sudden Termination", "Sandbox",
                                       "Restricted", "Preventing Sleep", "App Nap"]

    init(processes: [Process], scope: Scope, pidColumnVisible: Bool, search: String = "") {
        self.processes = processes
        _scope = scope
        _pidColumnVisible = pidColumnVisible
        _search = search
    }

    var scope: Scope { lock.withLock { _scope } }
    var pidColumnVisible: Bool { lock.withLock { _pidColumnVisible } }
    var search: String { lock.withLock { _search } }
    var selectedPID: Int32? { lock.withLock { _selectedPID } }
    var requestCount: Int { lock.withLock { _requestCount } }
    var requestTimeouts: [Float] { lock.withLock { _requestTimeouts } }
    var listedPIDs: [Int32] { lock.withLock { visibleProcesses().map(\.pid) } }
    var isResponding: Bool {
        get { lock.withLock { _isResponding } }
        set { lock.withLock { _isResponding = newValue } }
    }
    /// False models a cold launch whose menus exist before its window does.
    var windowsReady: Bool {
        get { lock.withLock { _windowsReady } }
        set { lock.withLock { _windowsReady = newValue } }
    }

    func userTypesSearch(_ text: String) {
        lock.withLock { _search = text }
    }

    // MARK: ActivityMonitorAXTransport

    func applicationElement(pid: pid_t) -> AXUIElement {
        lock.withLock { element(.application) }
    }

    func setTimeout(_ element: AXUIElement, seconds: Float) {
        lock.withLock { _requestTimeouts.append(seconds) }
    }

    func copyAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: inout CFTypeRef?) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            guard let node = node(for: element),
                  let result = attributeValue(node, attribute as String) else { return .noValue }
            value = result
            return .success
        }
    }

    func setAttribute(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            switch (node(for: element), attribute as String) {
            case (.searchField?, kAXValueAttribute):
                _search = (value as? String) ?? ""
                return .success
            case (.outline?, kAXSelectedRowsAttribute):
                guard let rows = value as? [AXUIElement], rows.count == 1,
                      case .row(let pid)? = node(for: rows[0]) else { return .illegalArgument }
                _selectedPID = pid
                return .success
            default:
                return .attributeUnsupported
            }
        }
    }

    func performAction(_ element: AXUIElement, _ action: CFString) -> AXError {
        lock.withLock {
            _requestCount += 1
            guard _isResponding else { return .cannotComplete }
            switch (node(for: element), action as String) {
            case (.allProcessesItem?, kAXPressAction):
                _scope = .all
            case (.myProcessesItem?, kAXPressAction):
                _scope = .mine
            case (.columnItem(let index)?, kAXPressAction) where Self.columnTitles[index] == "PID":
                _pidColumnVisible.toggle()
            case (.searchField?, kAXConfirmAction):
                break
            default:
                return .actionUnsupported
            }
            return .success
        }
    }

    // MARK: Model (called with the lock held)

    private func visibleProcesses() -> [Process] {
        processes.filter { process in
            (_scope == .all || process.mine)
                && (_search.isEmpty || process.name.localizedCaseInsensitiveContains(_search))
        }
    }

    private var visibleColumns: [String] {
        _pidColumnVisible ? ["Command", "PID"] : ["Command"]
    }

    private func attributeValue(_ node: Node, _ attribute: String) -> CFTypeRef? {
        switch (node, attribute) {
        case (.application, kAXWindowsAttribute): return elements(_windowsReady ? [.window] : [])
        case (.application, kAXMainWindowAttribute): return _windowsReady ? element(.window) : nil
        case (.application, kAXMenuBarAttribute): return element(.menuBar)
        case (.window, kAXRoleAttribute): return kAXWindowRole as CFString
        case (.window, kAXChildrenAttribute): return elements([.searchField, .outline])
        case (.searchField, kAXRoleAttribute): return kAXTextFieldRole as CFString
        case (.searchField, kAXSubroleAttribute): return kAXSearchFieldSubrole as CFString
        case (.searchField, kAXValueAttribute): return _search as CFString
        case (.outline, kAXRoleAttribute): return kAXOutlineRole as CFString
        case (.outline, kAXColumnsAttribute): return elements(visibleColumns.indices.map { .column($0) })
        case (.outline, kAXRowsAttribute): return elements(visibleProcesses().map { .row($0.pid) })
        case (.column(let index), kAXIdentifierAttribute): return visibleColumns[index] as CFString
        case (.row(let pid), kAXChildrenAttribute): return elements(visibleColumns.indices.map { .cell(pid, $0) })
        case (.cell(_, let column), kAXColumnIndexRangeAttribute):
            var range = CFRange(location: column, length: 1)
            return AXValueCreate(.cfRange, &range)
        case (.cell(let pid, let column), kAXValueAttribute):
            guard visibleColumns.indices.contains(column),
                  let process = processes.first(where: { $0.pid == pid }) else { return nil }
            return (visibleColumns[column] == "PID" ? String(pid) : process.name) as CFString
        case (.menuBar, kAXChildrenAttribute): return elements([.fileMenuBarItem, .viewMenuBarItem])
        case (.fileMenuBarItem, kAXChildrenAttribute): return elements([.fileMenu])
        case (.fileMenu, kAXChildrenAttribute): return elements([.fileFirstItem])
        case (.viewMenuBarItem, kAXChildrenAttribute): return elements([.viewMenu])
        case (.viewMenu, kAXChildrenAttribute):
            return elements([.columnsItem, .separator(0), .myProcessesItem, .allProcessesItem, .separator(1)])
        case (.columnsItem, kAXChildrenAttribute): return elements([.columnsSubmenu])
        case (.columnsSubmenu, kAXChildrenAttribute):
            return elements(Self.columnTitles.indices.map { .columnItem($0) })
        case (.columnsItem, kAXTitleAttribute): return "Columns" as CFString
        case (.separator, kAXTitleAttribute): return "" as CFString
        case (.myProcessesItem, kAXTitleAttribute): return "My Processes" as CFString
        case (.allProcessesItem, kAXTitleAttribute): return "All Processes" as CFString
        case (.columnItem(let index), kAXTitleAttribute): return Self.columnTitles[index] as CFString
        case (.myProcessesItem, kAXMenuItemMarkCharAttribute): return _scope == .mine ? "✓" as CFString : nil
        case (.allProcessesItem, kAXMenuItemMarkCharAttribute): return _scope == .all ? "✓" as CFString : nil
        case (.columnItem(let index), kAXMenuItemMarkCharAttribute):
            let marked = Self.columnTitles[index] == "PID" ? _pidColumnVisible : index == 0
            return marked ? "✓" as CFString : nil
        default:
            return nil
        }
    }

    private func element(_ node: Node) -> AXUIElement {
        if let token = tokens[node] {
            return AXUIElementCreateApplication(token)
        }
        let token = pid_t(800_000 + tokens.count)
        tokens[node] = token
        nodes[token] = node
        return AXUIElementCreateApplication(token)
    }

    private func elements(_ list: [Node]) -> CFArray {
        list.map { element($0) } as CFArray
    }

    private func node(for element: AXUIElement) -> Node? {
        var token: pid_t = 0
        guard AXUIElementGetPid(element, &token) == .success else { return nil }
        return nodes[token]
    }
}
