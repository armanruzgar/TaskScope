import ApplicationServices
import Foundation
import XCTest
@testable import TaskScope

final class Batch04AccessibilityFixTests: XCTestCase {
    func testDisconnectEntryFailsBeforeInspectingServicesWhenInventoryFails() async {
        let fake = LifecycleRuntimeHarness(existingPaths: [], commandResults: [])
        var lifecycle = fake.runtime
        lifecycle.loadProcessInventory = { .failure(.commandFailed("ps unavailable")) }
        let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: entryRuntime(lifecycle))
        XCTAssertEqual(result, .failed("The process list is unavailable. GlobalProtect's services were left running."))
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testDeniedAccessibilityNeverOpensOrDrivesVendorApp() async {
        let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: entryRuntime(runningRuntime()))
        guard case .failed(let detail) = result else { return XCTFail("Expected refusal") }
        XCTAssertTrue(detail.contains("Privacy & Security → Accessibility"))
    }

    func testMissingApplicationOrWrongKernelExecutableIsNeverDriven() async {
        for scenario in ["missing-app", "wrong-path", "missing-path"] {
            var lifecycle = runningRuntime()
            lifecycle.executablePathForPID = { pid in
                pid == 42 ? "/Applications/GlobalProtect.app/Contents/Resources/PanGPS" : (scenario == "wrong-path" ? "/tmp/GlobalProtect" : nil)
            }
            var runtime = entryRuntime(lifecycle)
            runtime.requestAccessibility = { true }
            runtime.application = { scenario == "missing-app" ? nil : (4343, true) }
            let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: runtime)
            XCTAssertEqual(result, .failed("GlobalProtect's interface could not be opened to disconnect. Its services were left running."))
        }
    }

    func testEntryForwardsVendorPIDAndColdLaunchFlag() async {
        var lifecycle = runningRuntime()
        lifecycle.executablePathForPID = { $0 == 42 ? "/Applications/GlobalProtect.app/Contents/Resources/PanGPS" : GlobalProtectAccessibilityDisconnect.executable }
        for launched in [true, false] {
            var runtime = entryRuntime(lifecycle)
            runtime.requestAccessibility = { true }
            runtime.application = { (4343, launched) }
            runtime.disconnect = { pid, cold in
                XCTAssertEqual(pid, 4343)
                XCTAssertEqual(cold, launched)
                return .disconnected
            }
            let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: runtime)
            XCTAssertEqual(result, .disconnected)
        }
    }

    func testAdapterReadsEveryEnglishStatus() async {
        XCTAssertEqual(GlobalProtectConnectionObservation(status: "Not Connected").state, .disconnected)
        for (status, expected) in [("Not Connected", GlobalProtectConnectionState.disconnected), ("Connected", .connected),
                                   ("Connecting...", .busy), ("Disconnecting...", .busy), ("Unexpected", .unavailable)] {
            let tree = Batch04AXTree(status: status)
            let state = await tree.runtime.connectionState(deadline: .init())
            XCTAssertEqual(state, expected)
            XCTAssertTrue(tree.item.timeouts.allSatisfy { $0 > 0 && $0 <= 1 })
        }
    }

    func testErrorRequiresCompleteIdleControlsInOneWindowAndStableStatus() async {
        for scenario in ["idle", "split", "disconnect", "disabled-connect", "changed"] {
            let tree = Batch04AXTree(status: "Error")
            let text = Batch04AXNode(role: kAXStaticTextRole, title: "Connection Failed")
            let connect = Batch04AXNode(role: kAXButtonRole, title: "Connect", enabled: scenario != "disabled-connect")
            let disconnect = Batch04AXNode(role: kAXButtonRole, title: "Disconnect")
            let window = Batch04AXNode(children: [text, connect] + (scenario == "disconnect" ? [disconnect] : []))
            tree.app.set(kAXWindowsAttribute, .elements(scenario == "split"
                ? [Batch04AXNode(children: [text]), Batch04AXNode(children: [connect])] : [window]))
            if scenario == "changed" { tree.item.setStatuses(["Error", "Connected"]) }
            let state = await tree.runtime.connectionState(deadline: .init())
            XCTAssertEqual(state, scenario == "idle" ? .disconnected : (scenario == "changed" ? .connected : .unavailable))
        }
    }

    func testTimeoutOrChangedExecutableCannotAuthorizeIdleObservation() async {
        for timeout in [true, false] {
            let tree = Batch04AXTree(status: "Not Connected")
            if timeout { tree.item.fail(kAXHelpAttribute, with: .cannotComplete) }
            else { tree.item.onRead = { [weak tree] attribute in if attribute == kAXHelpAttribute { tree?.changeIdentity() } } }
            let state = await tree.runtime.connectionState(deadline: .init())
            XCTAssertEqual(state, .unavailable)
        }
    }

    func testPopoverIsPolledUntilItAppears() async {
        let tree = Batch04AXTree(status: "Connected")
        let button = Batch04AXNode(role: kAXButtonRole, title: "Disconnect")
        tree.onPoll = { [weak tree] count in
            if count == 3 { tree?.app.set(kAXWindowsAttribute, .elements([Batch04AXNode(children: [button])])) }
        }
        let result = await tree.runtime.pressDisconnect(deadline: .init())
        XCTAssertEqual(result, .pressed)
        XCTAssertEqual(tree.polls, 3)
        XCTAssertEqual(tree.item.presses, 1)
        XCTAssertEqual(button.presses, 1)
    }

    func testTreeTraversalStopsAtDepthEightAndOneHundredElements() async {
        for limit in ["depth", "count"] {
            let tree = Batch04AXTree(status: "Connected")
            let disconnect = Batch04AXNode(role: kAXButtonRole, title: "Disconnect")
            if limit == "depth" {
                var root = disconnect
                for _ in 0..<9 { root = Batch04AXNode(children: [root]) }
                tree.app.set(kAXWindowsAttribute, .elements([root]))
            } else {
                // LIFO traversal inspects the last roots first.
                tree.app.set(kAXWindowsAttribute, .elements([disconnect] + (0..<100).map { _ in Batch04AXNode() }))
            }
            let result = await tree.runtime.pressDisconnect(deadline: .init())
            XCTAssertEqual(result, .notPressable)
            XCTAssertEqual(disconnect.presses, 0)
            XCTAssertEqual(tree.polls, 20)
        }
    }

    func testOnlyExactEnabledDisconnectIsPressedAndTimeoutIsUnconfirmed() async {
        for scenario in ["exact", "description", "disabled", "timeout"] {
            let tree = Batch04AXTree(status: "Connected")
            let decoy = Batch04AXNode(role: kAXButtonRole, title: "Disconnect All")
            let button = Batch04AXNode(role: kAXButtonRole, title: scenario == "description" ? "" : "Disconnect", enabled: scenario != "disabled")
            if scenario == "description" { button.set(kAXDescriptionAttribute, .string("Disconnect")) }
            if scenario == "timeout" { button.actionError = .cannotComplete }
            tree.app.set(kAXWindowsAttribute, .elements([Batch04AXNode(children: [button, decoy])]))
            let result = await tree.runtime.pressDisconnect(deadline: .init())
            XCTAssertEqual(result, scenario == "disabled" ? .notPressable : (scenario == "timeout" ? .unconfirmed : .pressed))
            XCTAssertEqual(button.presses, scenario == "disabled" ? 0 : 1)
            XCTAssertEqual(decoy.presses, 0)
        }
    }

    func testUnconfirmedPressContinuesUntilFiveIdleObservationsWithoutRepressing() async {
        let runtime = Batch04UnconfirmedDisconnect()
        let result = await GlobalProtectDisconnectController.disconnect(using: runtime)
        XCTAssertEqual(result, .disconnected)
        let counts = await runtime.counts()
        XCTAssertEqual(counts.0, 7)
        XCTAssertEqual(counts.1, 1)
    }

    private func entryRuntime(_ lifecycle: ProcessLifecycleRuntime) -> GlobalProtectAccessibilityDisconnect.Runtime {
        .init(lifecycle: lifecycle, requestAccessibility: { false },
              application: { XCTFail("Application lookup must not run"); return nil },
              disconnect: { _, _ in XCTFail("Disconnect must not run"); return .disconnected })
    }

    private func runningRuntime() -> ProcessLifecycleRuntime {
        let process = batch04Process(pid: 42, uid: 0, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
        let fake = LifecycleRuntimeHarness(existingPaths: [], commandResults: [], respond: { command in
            if command.arguments.contains(where: { $0.hasPrefix("gui/") }) { return batch04Result(launchctlPrintOutput(pid: 42)) }
            return batch04Result(error: "Could not find service \"com.paloaltonetworks.gp.pangpsd\" in domain", code: 113)
        }, inventory: [process])
        return fake.runtime
    }
}

private actor Batch04UnconfirmedDisconnect: GlobalProtectDisconnectRuntime {
    var reads = 0
    var presses = 0
    func connectionState(deadline: GlobalProtectDisconnectDeadline) -> GlobalProtectConnectionState {
        reads += 1
        return reads <= 2 ? .connected : .disconnected
    }
    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) -> GlobalProtectDisconnectPressResult {
        presses += 1
        return .unconfirmed
    }
    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) {}
    func counts() -> (Int, Int) { (reads, presses) }
}

/// Mutable element attributes and counters are protected so test assertions and
/// the adapter's serial worker can safely share a fixture.
private final class Batch04AXNode: GlobalProtectAXElement, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var attributes: [String: GlobalProtectAXValue]
    private var failures: [String: AXError] = [:]
    private var statuses: [String] = []
    private var recordedPresses = 0
    private var recordedTimeouts: [Float] = []
    var onRead: (@Sendable (String) -> Void)?
    var actionError: AXError = .success
    init(role: String = "AXGroup", title: String = "", enabled: Bool = true, children: [Batch04AXNode] = []) {
        attributes = [kAXRoleAttribute: .string(role), kAXTitleAttribute: .string(title), kAXEnabledAttribute: .boolean(enabled), kAXChildrenAttribute: .elements(children)]
    }
    var presses: Int { lock.withLock { recordedPresses } }
    var timeouts: [Float] { lock.withLock { recordedTimeouts } }
    func set(_ attribute: String, _ value: GlobalProtectAXValue) { lock.withLock { attributes[attribute] = value } }
    func setStatuses(_ values: [String]) { lock.withLock { statuses = values } }
    func fail(_ attribute: String, with error: AXError) { lock.withLock { failures[attribute] = error } }
    func copyAttribute(_ attribute: String) -> (AXError, GlobalProtectAXValue?) {
        lock.withLock {
            onRead?(attribute)
            if let error = failures[attribute] { return (error, nil) }
            if attribute == kAXHelpAttribute, let status = statuses.first {
                if statuses.count > 1 { statuses.removeFirst() }
                return (.success, .string(status))
            }
            return (.success, attributes[attribute])
        }
    }
    func perform(_ action: String) -> AXError { lock.withLock { recordedPresses += 1; return actionError } }
    func setFrontmost() -> AXError { .success }
    func setMessagingTimeout(_ seconds: Float) { lock.withLock { recordedTimeouts.append(seconds) } }
}

private final class Batch04AXTree: @unchecked Sendable {
    let app = Batch04AXNode()
    let item = Batch04AXNode(role: kAXMenuBarItemRole)
    private let lock = NSLock()
    private var vendorIdentity = true
    private var pollCount = 0
    var onPoll: (@Sendable (Int) -> Void)?
    init(status: String) {
        item.setStatuses([status])
        app.set(kAXExtrasMenuBarAttribute, .element(Batch04AXNode(children: [item])))
        app.set(kAXWindowsAttribute, .elements([]))
    }
    var polls: Int { lock.withLock { pollCount } }
    func changeIdentity() { lock.withLock { vendorIdentity = false } }
    var runtime: GlobalProtectAccessibilityRuntime {
        GlobalProtectAccessibilityRuntime(pid: 4343, environment: .init(
            executablePath: { [self] _ in lock.withLock { vendorIdentity ? GlobalProtectAccessibilityDisconnect.executable : "/tmp/reusedPID" } },
            application: { [self] _ in app },
            sleep: { [self] _ in
                let count = lock.withLock { pollCount += 1; return pollCount }
                onPoll?(count)
            }
        ))
    }
}
