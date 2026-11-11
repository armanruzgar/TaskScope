import XCTest
@testable import TaskScope

/// The store-level consequence the ledger adds: a confirmed stop in flight is
/// the user's answer, so a rule edit made while it runs does not prompt the
/// same process again.
@MainActor
final class AutoStopConfirmedStopEditTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopConfirmedStopEditTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEditingTheRuleWhileAConfirmedStopRunsDoesNotPromptAgain() async throws {
        for edit in ["save", "runtime", "toggle"] {
            defaults.removePersistentDomain(forName: suiteName)
            let process = AppProcess.fixture(
                pid: 4101, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1, command: "Example",
                executablePath: "/confirmed/Example", elapsedTime: "10:00", startTime: "start",
                netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
            )
            let inventory = ScriptedInventory(processes: [process])
            let store = AutoStopRulesStore(
                userDefaults: defaults, key: "rules", eventsKey: "events", inventory: inventory,
                now: { Date(timeIntervalSince1970: 1_000) }, currentUID: getuid(), currentPID: getpid()
            )
            let rule = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
            XCTAssertTrue(store.add(rule))
            let gate = ConfirmedStopGate()
            var attempts = 0
            store.start { _, _ in
                attempts += 1
                await gate.wait()
                return .requestedStillRunning
            }
            store.stop()
            await store.evaluateNow()
            let claimed = try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt)))
            let stop = Task { await store.finishStop(claimed) }
            for _ in 0..<1_000 where attempts == 0 { await Task.yield() }
            XCTAssertEqual(attempts, 1, "precondition: the confirmed stop is in flight")

            switch edit {
            case "runtime":
                var edited = rule
                edited.runtimeMinutes = 2
                XCTAssertTrue(store.update(edited))
            case "toggle":
                XCTAssertTrue(store.setEnabled(false, for: rule))
                XCTAssertTrue(store.setEnabled(true, for: store.rules[0]))
            default:
                XCTAssertTrue(store.update(rule))
            }
            await store.evaluateNow()
            XCTAssertTrue(store.pendingPrompts.isEmpty, "\(edit): the answered occurrence must not prompt while its stop runs")

            await gate.release()
            await stop.value
            await store.evaluateNow()
            XCTAssertTrue(store.pendingPrompts.isEmpty, edit)
            inventory.setProcesses([])
            await store.evaluateNow()
            XCTAssertEqual(attempts, 1, edit)
            XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested], edit)
            XCTAssertEqual(store.events.first?.detail, "Exited after the stop request.", edit)
        }
    }
}

private actor ConfirmedStopGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
