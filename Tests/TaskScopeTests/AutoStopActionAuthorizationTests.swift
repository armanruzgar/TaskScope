import Darwin
import XCTest
@testable import TaskScope

/// Drives the *production* auto-stop action handler
/// (`AutoStopActionHandlerFactory`) end to end: the closure the app installs,
/// the store's authority check, and `ProcessManager.terminate`.
@MainActor
final class AutoStopActionAuthorizationTests: XCTestCase {
    private let examplePath = "/Applications/Example.app/Contents/MacOS/Example"
    private let suiteName = "TaskScope.AutoStopActionAuthorizationTests.\(UUID().uuidString)"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Stop Now on a Prompt rule used to be authorized with the automatic-stop
    /// rule (`action == .kill`), so a confirmed prompt was always rejected and
    /// logged as failed. A confirmed prompt needs only an enabled rule.
    func testStopNowOnAPromptRuleIsAuthorizedThroughTheProductionHandler() async throws {
        let target = appProcess(pid: 41, elapsed: "10:00")
        let inventory = StubInventory(processes: [target])
        let signaler = RecordingSignaler(alivePids: [41], exitsOnTerminate: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)
        let store = makeStore(inventory: inventory)
        store.start(
            cadence: 3_600,
            perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store)
        )
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))

        await store.evaluateNow()
        let prompt = try XCTUnwrap(store.currentPrompt, "setup: a prompt is queued")
        let claimed = try XCTUnwrap(store.claimPrompt(prompt))
        await store.finishStop(claimed)

        XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM])
        XCTAssertEqual(store.events.first?.outcome, .stopped)
    }

    func testAutomaticStopStillRequiresAnEnabledAutoStopRule() async throws {
        let target = appProcess(pid: 41, elapsed: "10:00")
        let inventory = StubInventory(processes: [target])
        let signaler = RecordingSignaler(alivePids: [41], exitsOnTerminate: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        let promptRule = store.rules[0]
        let handler = AutoStopActionHandlerFactory.make(processManager: manager, rules: store)

        // A prompt rule invoked as if it were automatic is refused before kill(2).
        let automatic = await handler(promptRule, target, .automatic)
        XCTAssertEqual(automatic, .rejected)
        XCTAssertTrue(signaler.sent.isEmpty)

        XCTAssertTrue(store.authorizes(promptRule, kind: .confirmedPrompt))
        XCTAssertFalse(store.authorizes(promptRule, kind: .automatic))

        var disabled = promptRule
        disabled.isEnabled = false
        XCTAssertTrue(store.update(disabled))
        XCTAssertFalse(store.authorizes(promptRule, kind: .confirmedPrompt))
        XCTAssertFalse(store.authorizes(promptRule, kind: .automatic))
    }

    func testAutomaticStopIsAuthorizedForAnEnabledAutoStopRuleThroughTheProductionHandler() async throws {
        let target = appProcess(pid: 41, elapsed: "10:00")
        let inventory = StubInventory(processes: [target])
        let signaler = RecordingSignaler(alivePids: [41], exitsOnTerminate: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        )))

        store.start(
            cadence: 3_600,
            perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store)
        )
        await waitUntil { !store.events.isEmpty }
        store.stop()

        XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM])
        XCTAssertEqual(store.events.map(\.outcome), [.stopped])
    }

    /// Editing the rule while its automatic stop is between the identity check
    /// and the signal revokes the authority the stop started with: the queued
    /// action is cancelled and nothing is signalled under the old rule.
    func testRetargetingTheRuleWhileAStopIsInFlightCancelsItBeforeTheSignal() async throws {
        let target = appProcess(pid: 41, elapsed: "10:00")
        let verification = BlockingVerificationInventory(processes: [target])
        let signaler = RecordingSignaler(alivePids: [41], exitsOnTerminate: true)
        let manager = ProcessManager(
            processInventory: StubInventory(processes: [target]),
            verificationInventory: verification,
            processSignaler: signaler,
            lifecycle: AuthorizationLifecycle(),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        let store = makeStore(inventory: StubInventory(processes: [target]))
        XCTAssertTrue(store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 1,
            action: .kill
        )))
        let stored = store.rules[0]

        store.start(
            cadence: 3_600,
            perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store)
        )
        await verification.waitForFirstCall()

        var retargeted = stored
        retargeted.executablePath = "/Applications/Other.app/Contents/MacOS/Example"
        XCTAssertTrue(store.update(retargeted))
        XCTAssertFalse(store.authorizes(stored, kind: .automatic))

        await verification.finishFirstCall()
        await waitUntil { manager.operationState == .idle && !manager.isWorking }
        await settle()
        store.stop()

        XCTAssertTrue(signaler.sent.isEmpty, "a retargeted rule must not signal under its old path")
        XCTAssertTrue(store.events.isEmpty, "no outcome may be recorded against the retired rule value")
    }

    func testProductionHandlerDoesNotRetainStoreOrManagerAfterStop() async {
        let inventory = StubInventory(processes: [])
        let signaler = RecordingSignaler(alivePids: [], exitsOnTerminate: true)
        var manager: ProcessManager? = makeManager(inventory: inventory, signaler: signaler)
        var store: AutoStopRulesStore? = makeStore(inventory: inventory)
        weak let weakManager = manager
        weak let weakStore = store
        store?.start(perform: AutoStopActionHandlerFactory.make(processManager: manager!, rules: store!))
        store?.stop()
        store = nil
        manager = nil
        await settle()
        XCTAssertNil(weakStore)
        XCTAssertNil(weakManager)
    }

    func testRetainedProductionHandlerFailsClosedAfterStoreIsReleased() async {
        let inventory = StubInventory(processes: [appProcess(pid: 41, elapsed: "10:00")])
        let signaler = RecordingSignaler(alivePids: [41], exitsOnTerminate: true)
        let manager = makeManager(inventory: inventory, signaler: signaler)
        var store: AutoStopRulesStore? = makeStore(inventory: inventory)
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
        XCTAssertTrue(store!.add(rule))
        let handler = AutoStopActionHandlerFactory.make(processManager: manager, rules: store!)
        weak let weakStore = store
        store = nil
        XCTAssertNil(weakStore)
        let result = await handler(rule, appProcess(pid: 41, elapsed: "10:00"), .confirmedPrompt)
        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(signaler.sent.isEmpty)
    }

    // MARK: - Helpers

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        signaler: RecordingSignaler
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: signaler,
            lifecycle: AuthorizationLifecycle(),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    private func makeStore(inventory: any ProcessInventoryProviding) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: "rules",
            eventsKey: "events",
            inventory: inventory,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func appProcess(pid: Int32, elapsed: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: getuid(),
            cpu: 1,
            memoryMB: 1,
            command: examplePath,
            executablePath: examplePath,
            elapsedTime: elapsed,
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "condition was not met within \(timeout)s")
    }
}

private struct StubInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

/// Blocks the first read (the manager's pre-signal verification) until released.
private actor BlockingVerificationInventory: ProcessInventoryProviding {
    private let processes: [AppProcess]
    private var callCount = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    init(processes: [AppProcess]) {
        self.processes = processes
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        callCount += 1
        if callCount == 1 {
            firstCallWaiters.forEach { $0.resume() }
            firstCallWaiters.removeAll()
            await withCheckedContinuation { firstCallContinuation = $0 }
        }
        return .success(processes)
    }

    func waitForFirstCall() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func finishFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }
}

private final class RecordingSignaler: ProcessSignaling {
    struct SentSignal: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private var alivePids: Set<Int32>
    private let exitsOnTerminate: Bool
    private(set) var sent: [SentSignal] = []

    init(alivePids: Set<Int32>, exitsOnTerminate: Bool) {
        self.alivePids = alivePids
        self.exitsOnTerminate = exitsOnTerminate
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(SentSignal(signal: signal, pid: pid))
        if signal == SIGTERM, exitsOnTerminate {
            alivePids.remove(pid)
        }
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        alivePids.contains(pid)
    }
}

private struct AuthorizationLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { false }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .failed("Fake launch failed.") }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}
