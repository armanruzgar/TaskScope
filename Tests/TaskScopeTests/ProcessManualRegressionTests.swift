import Darwin
import XCTest
@testable import TaskScope

@MainActor
final class ProcessManualRegressionTests: XCTestCase {
    nonisolated(unsafe) private var defaultsSuites: [(name: String, defaults: UserDefaults)] = []

    override func tearDown() {
        for suite in defaultsSuites {
            suite.defaults.removePersistentDomain(forName: suite.name)
        }
        defaultsSuites.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TaskScope.ProcessManual.\(UUID())"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defaultsSuites.append((suite, defaults))
        return defaults
    }

    func testAppPathOnlyEditRebaselinesNotificationsInBothDirections() async {
        let inventory = ManualInventory([row(path: "/Users/test/Applications/Example.app/Contents/MacOS/Example")])
        let manager = manager(inventory)
        manager.enableNotifications = true
        var preset = examplePreset()
        manager.watchedAppsProvider = { [preset] }
        var primes: [Set<String>] = []
        var diffs: [Set<String>] = []
        manager.primeNotificationBaseline = { primes.append(Set($0.flatMap(\.runningNames))) }
        manager.notifyTransitions = { diffs.append(Set($0.flatMap(\.runningNames))) }
        await manager.refreshWatchedStatus()
        preset.appPath = "/Users/test/Applications/Example.app"
        await manager.refreshWatchedStatus()
        preset.appPath = "/Applications/Example.app"
        await manager.loadProcessList()
        XCTAssertEqual(primes, [[], ["Example"], []])
        XCTAssertTrue(diffs.isEmpty, "App-path edits must rebaseline, never announce a transition")
    }

    func testMovingHelperBetweenPresetsRebaselinesEvenWithSameFlatNames() async {
        let manager = manager(ManualInventory([]))
        manager.enableNotifications = true
        var first = examplePreset()
        var second = examplePreset()
        second.appPath = "/Applications/Other.app"
        first.helperProcessNames = ["Helper"]
        manager.watchedAppsProvider = { [first, second] }
        var calls: [String] = []
        manager.primeNotificationBaseline = { _ in calls.append("prime") }
        manager.notifyTransitions = { _ in calls.append("diff") }
        await manager.refreshWatchedStatus()
        first.helperProcessNames = []
        second.helperProcessNames = ["Helper"]
        await manager.refreshWatchedStatus()
        XCTAssertEqual(calls, ["prime", "prime"])
    }

    func testChangedOrMissingExecutableAndReusedPIDAreNotReportedAbsent() async {
        let captured = row()
        var reused = captured
        reused.startTime = "different-start"
        var missingPath = captured
        missingPath.executablePath = nil
        for replacement in [row(path: "/Applications/Moved.app/Contents/MacOS/Example"), reused, missingPath] {
            let inventory = ManualInventory([replacement])
            let signaler = ManualSignaler()
            let manager = manager(inventory, signaler: signaler)
            let result = await manager.terminate(captured)
            XCTAssertEqual(result, .identityChanged, "A present PID with a changed identity is not absent")
            XCTAssertTrue(manager.message.contains("identity changed"))
            XCTAssertTrue(signaler.sent.isEmpty)
            await manager.batchTerminate([captured.identity])
            XCTAssertEqual(manager.batchActionReport?.targets.first?.state.label, "Identity changed")
            XCTAssertTrue(signaler.sent.isEmpty)
        }
    }

    func testAbsentSingleStopPublishesVerifiedInventory() async {
        let captured = row()
        let inventory = ManualInventory([captured])
        let manager = manager(inventory)
        await manager.loadProcessList()
        manager.toggleSelection(captured.pid)
        inventory.result = .success([])
        let result = await manager.terminate(captured)
        XCTAssertEqual(result, .stale)
        XCTAssertTrue(manager.displayProcesses().isEmpty, "A proven absent row must leave the displayed list")
        XCTAssertTrue(manager.selectedPids.isEmpty)
    }

    func testStaleListTimestampTracksDisplayedRowsNotWatchedPolls() async {
        let inventory = ManualInventory([row()])
        var clock = Date(timeIntervalSince1970: 100)
        let manager = manager(inventory, now: { clock })
        await manager.loadProcessList()
        let listTime = clock
        clock = Date(timeIntervalSince1970: 200)
        await manager.refreshWatchedStatus()
        inventory.result = .failure(.commandFailed("read failed"))
        await manager.loadProcessList()
        XCTAssertEqual(manager.lastSuccessfulInventoryAt, listTime)
        XCTAssertNotNil(manager.processLoadError)
    }

    func testExplicitListRefreshJoiningActiveSilentReadPublishesSuccessAndFailure() async {
        let results: [Result<[AppProcess], ProcessInventoryError>] = [.success([row()]), .failure(.commandFailed("read failed"))]
        for result in results {
            let blocked = ManualBlockingInventory(result: result)
            let manager = manager(blocked)
            manager.setMessage("old status")
            let silent = Task { await manager.loadProcessList(showMessage: false) }
            await blocked.waitUntilEntered()
            let explicit = Task { await manager.loadProcessList() }
            await waitUntil { manager.operationState == .coalesced }
            await blocked.release()
            _ = await silent.value
            _ = await explicit.value
            switch result {
            case .success:
                XCTAssertEqual(manager.message, "Loaded 1 of 1 processes.")
            case .failure:
                XCTAssertTrue(manager.message.hasPrefix("Could not load processes:"))
            }
            let count = await blocked.count
            XCTAssertEqual(count, 1)
        }
    }

    func testExplicitListRefreshJoiningQueuedSilentReadPublishesResult() async {
        let verification = ManualBlockingInventory(result: .success([]))
        let manager = manager(ManualInventory([row()]), verification: verification)
        let mutation = Task { await manager.terminate(self.row()) }
        await verification.waitUntilEntered()
        let silent = Task { await manager.loadProcessList(showMessage: false) }
        await waitUntil { manager.operationState == .queued }
        let explicit = Task { await manager.loadProcessList() }
        await waitUntil { manager.operationState == .coalesced }
        await verification.release()
        _ = await mutation.value
        _ = await silent.value
        _ = await explicit.value
        XCTAssertEqual(manager.message, "Loaded 1 of 1 processes.")
    }

    func testCancelledBusRefreshWaitingBehindMutationIsRejectedWithoutFailureMessage() async {
        let verification = ManualBlockingInventory(result: .success([]))
        let manager = manager(ManualInventory([]), verification: verification)
        manager.setMessage("existing status")
        let coordinator = AppCommandCoordinator(processManager: manager, presets: { [] })
        let bus = AppCommandBus()
        bus.install { await coordinator.perform($0) }
        let mutation = Task { await manager.terminate(self.row()) }
        await verification.waitUntilEntered()
        let refresh = Task { await bus.submit(.refresh) }
        await waitUntil { manager.operationState == .queued }
        refresh.cancel()
        let result = await refresh.value
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("cancelled"))
        XCTAssertEqual(manager.message, "existing status")
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: nil).isEmpty)
        await verification.release()
        _ = await mutation.value
    }

    func testCancelledManualVerificationIsNotAnInventoryFailure() async {
        let verification = ManualBlockingInventory(result: .success([row()]), honorsCancellation: true)
        let signaler = ManualSignaler()
        let manager = manager(ManualInventory([]), verification: verification, signaler: signaler)
        let stop = Task { await manager.terminate(self.row()) }
        await verification.waitUntilEntered()
        stop.cancel()
        await verification.release()
        let result = await stop.value
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(manager.message, "Stop for Example was cancelled.")
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertNil(manager.processLoadError)
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: nil).isEmpty)
    }

    func testCancelledBatchVerificationDoesNotPublishInventoryFailure() async {
        let captured = row()
        let verification = ManualBlockingInventory(result: .success([captured]), honorsCancellation: true)
        let signaler = ManualSignaler()
        let manager = manager(ManualInventory([]), verification: verification, signaler: signaler)
        manager.setMessage("existing status")
        let stop = Task { await manager.batchTerminate([captured.identity]) }
        await verification.waitUntilEntered()
        stop.cancel()
        await verification.release()
        await stop.value
        XCTAssertEqual(manager.message, "existing status")
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertNil(manager.processLoadError)
        XCTAssertNil(manager.batchActionReport)
    }

    func testCancelledOpenVerificationIsRejectedWithoutDiagnostics() async {
        let verification = ManualBlockingInventory(result: .success([]), honorsCancellation: true)
        let manager = manager(ManualInventory([]), verification: verification)
        manager.setMessage("existing status")
        let preset = examplePreset()
        let open = Task { await manager.openApp(preset) }
        await verification.waitUntilEntered()
        open.cancel()
        await verification.release()
        let result = await open.value
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("cancelled"))
        XCTAssertEqual(manager.message, "existing status")
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
    }

    func testAdmittedBusStopFinishesAfterCallerCancellation() async {
        let blocked = ManualBlockingInventory(result: .success([]), honorsCancellation: true)
        let cancellation = ManualCancellationLog()
        let main = row()
        var helper = row(pid: 43)
        helper.command = "/Applications/Example.app/Contents/MacOS/Helper"
        helper.executablePath = helper.command
        let rows = [main, helper]
        let signals = ManualSignalLog()
        // The production service on a fake runtime: every signal it sends
        // records whether the stop had inherited the caller's cancellation.
        let lifecycle = SystemProcessLifecycleService(runtime: ProcessLifecycleRuntime(
            userID: getuid(), fileExists: { _ in false }, launchAgentLabel: { _ in nil },
            runCommand: { _, _ in XCTFail("Unexpected command"); return ShellCommandResult(command: "fake", stdout: "", stderr: "", exitCode: 1) },
            loadProcessInventory: { Task.isCancelled ? .failure(.cancelled) : .success(rows) },
            executablePathForPID: { pid in rows.first { $0.pid == pid }?.executablePath },
            sendSignal: { signal, pid in
                if Task.isCancelled { cancellation.record() }
                signals.append(signal, pid)
                return true
            },
            isProcessAlive: { _ in true },
            sleep: { _ in _ = await blocked.load(fetchExtendedStats: false) }, systemUptime: { 0 },
            isAppBundle: { _ in false }
        ))
        let inventory = ManualInventory(rows)
        let manager = manager(inventory, lifecycle: lifecycle)
        var preset = examplePreset()
        preset.helperProcessNames = ["Helper"]
        manager.watchedAppsProvider = { [preset] }
        let coordinator = AppCommandCoordinator(processManager: manager, presets: { [preset] })
        let bus = AppCommandBus()
        bus.install { await coordinator.perform($0) }
        let stop = Task { await bus.submit(.stopPresetEntity(.init(id: preset.id, displayName: preset.displayName))) }
        await blocked.waitUntilEntered()
        stop.cancel()
        inventory.result = .success([])
        await blocked.release()
        let result = await stop.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.message, "Example and helpers quit.")
        XCTAssertFalse(cancellation.sawCancellation, "An admitted Stop must complete without inheriting caller cancellation")
        XCTAssertEqual(signals.pids, [main.pid, main.pid, helper.pid, helper.pid])
        XCTAssertEqual(signals.signals, [SIGTERM, SIGKILL, SIGTERM, SIGKILL])
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
    }

    func testCancelledBusStopWaitingForGateDoesNotStartLifecycleWork() async {
        let verification = ManualBlockingInventory(result: .success([]))
        let lifecycle = ManualLifecycle()
        let manager = manager(ManualInventory([]), verification: verification, lifecycle: lifecycle)
        let preset = examplePreset()
        let coordinator = AppCommandCoordinator(processManager: manager, presets: { [preset] })
        let bus = AppCommandBus()
        bus.install { await coordinator.perform($0) }
        let mutation = Task { await manager.terminate(self.row()) }
        await verification.waitUntilEntered()
        let stop = Task { await bus.submit(.stopPresetEntity(.init(id: preset.id, displayName: preset.displayName))) }
        await waitUntil { manager.operationState == .queued }
        stop.cancel()
        let result = await stop.value
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("cancelled"))
        XCTAssertTrue(lifecycle.terminatedNames.isEmpty)
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
        await verification.release()
        _ = await mutation.value
    }

    func testCancelledStopVerificationDoesNotRecordInventoryFailure() async {
        let inventory = ManualInventory([])
        inventory.result = .failure(.cancelled)
        let manager = manager(inventory)
        let preset = examplePreset()
        manager.setMessage("existing status")
        let result = await manager.quitAllKillable(preset)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("cancelled"))
        XCTAssertEqual(manager.message, "existing status")
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
    }

    func testOpenReadinessRemainsCancellableWithoutFailureDiagnostics() async {
        let blocked = ManualBlockingInventory(result: .success([]), honorsCancellation: true)
        let lifecycle = ManualLifecycle()
        lifecycle.onWait = {
            _ = await blocked.load(fetchExtendedStats: false)
            return !Task.isCancelled
        }
        let manager = manager(ManualInventory([]), lifecycle: lifecycle)
        let preset = examplePreset()
        let open = Task { await manager.openApp(preset) }
        await blocked.waitUntilEntered()
        open.cancel()
        await blocked.release()
        let result = await open.value
        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("was cancelled"))
        XCTAssertTrue(result.message.contains("may already have changed"))
        XCTAssertEqual(lifecycle.openRequests, 1)
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
    }

    func testSelfPIDRefusedForStopForceStopAndAutoStopHandler() async {
        let own = row(pid: 4242)
        let inventory = ManualInventory([own])
        let signaler = ManualSignaler()
        let manager = manager(inventory, signaler: signaler, currentPID: own.pid)
        for force in [false, true] {
            let result = await manager.terminate(own, forceKill: force)
            XCTAssertEqual(result, .refused)
        }
        let defaults = makeDefaults()
        let rules = AutoStopRulesStore(userDefaults: defaults, inventory: inventory)
        let rule = AutoStopRule(processName: own.name, executablePath: own.executablePath, runtimeMinutes: 1, action: .kill)
        XCTAssertTrue(rules.add(rule))
        let handler = AutoStopActionHandlerFactory.make(processManager: manager, rules: rules)
        for kind in [AutoStopActionKind.automatic, .confirmedPrompt] {
            let result = await handler(rule, own, kind)
            XCTAssertEqual(result, .refused)
        }
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(inventory.count, 0)
    }

    func testLifecycleControllerExcludesSelfForBothPoliciesAndEscalation() async {
        let own = row(pid: 4242)
        let other = row(pid: 4243)
        for rows in [[own], [own, other]] {
            let signals = ManualSignalLog()
            let runtime = ProcessLifecycleRuntime(
                userID: getuid(), fileExists: { _ in false }, launchAgentLabel: { _ in nil },
                runCommand: { _, _ in XCTFail("Unexpected command"); return ShellCommandResult(command: "fake", stdout: "", stderr: "", exitCode: 1) },
                loadProcessInventory: { .success(rows) },
                executablePathForPID: { pid in rows.first { $0.pid == pid }?.executablePath },
                sendSignal: { signal, pid in signals.append(signal, pid); return true },
                isProcessAlive: { _ in true }, sleep: { _ in }, systemUptime: { 0 },
                isAppBundle: { _ in false }
            )
            let result = await ProcessLifecycleController.terminateProcess(
                named: own.name, policy: .gracefulThenForce,
                expectedExecutableDirectory: examplePreset().mainExecutableDirectory,
                currentPID: own.pid, runtime: runtime
            )
            XCTAssertEqual(result, rows.count == 1 ? .noMatchingProcesses : .signalled)
            XCTAssertEqual(signals.pids, rows.count == 1 ? [] : [other.pid, other.pid])
            XCTAssertEqual(signals.signals, rows.count == 1 ? [] : [SIGTERM, SIGKILL])
            if rows.count == 1 {
                let graceful = await ProcessLifecycleController.terminateProcess(
                    named: own.name, forceIfStillRunning: false,
                    expectedExecutableDirectory: examplePreset().mainExecutableDirectory,
                    currentPID: own.pid, runtime: runtime
                )
                XCTAssertEqual(graceful, .noMatchingProcesses)
                XCTAssertTrue(signals.pids.isEmpty)
            }
        }
    }

    func testChangedIdentityFromStopHandlerIsNeverRecordedAsEnded() async {
        for action in [AutoStopRule.Action.prompt, .kill] {
            let captured = row()
            let inventory = ManualInventory([captured])
            let verification = ManualInventory([row(path: "/Applications/Moved.app/Contents/MacOS/Example")])
            let manager = manager(inventory, verification: verification)
            let defaults = makeDefaults()
            let store = AutoStopRulesStore(userDefaults: defaults, inventory: inventory,
                                          pollingController: ProcessPollingController(sleep: { _ in false }))
            store.start(perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store))
            store.stop()
            store.add(AutoStopRule(processName: captured.name, executablePath: captured.executablePath,
                                   runtimeMinutes: 1, action: action))
            await store.evaluateNow()
            if action == .prompt { await store.stopCurrentPrompt() }
            XCTAssertFalse(store.events.contains { $0.outcome == .stopped || $0.outcome == .processEnded })
            XCTAssertTrue(store.events.first?.detail.contains("identity changed") == true)
        }
    }

    func testMovedExecutableDoesNotRecordPendingStopAsExited() async {
        let captured = row()
        let inventory = ManualInventory([captured])
        let defaults = makeDefaults()
        let store = AutoStopRulesStore(userDefaults: defaults, inventory: inventory,
                                      pollingController: ProcessPollingController(sleep: { _ in false }))
        store.add(AutoStopRule(processName: captured.name, executablePath: captured.executablePath,
                               runtimeMinutes: 1, action: .kill))
        store.start { _, _ in .requestedStillRunning }
        await store.evaluateNow()
        store.stop()
        inventory.result = .success([row(path: "/Applications/Moved.app/Contents/MacOS/Example")])
        await store.evaluateNow()
        XCTAssertFalse(store.events.contains { $0.outcome == .stopped || $0.outcome == .processEnded },
                       "The same PID and start time still run after the bundle moves")
        XCTAssertTrue(store.events.first?.detail.contains("identity changed") == true)
    }

    func testMovedExecutableRetiresPromptWithoutClaimingItEnded() async {
        let captured = row()
        let inventory = ManualInventory([captured])
        let defaults = makeDefaults()
        let store = AutoStopRulesStore(userDefaults: defaults, inventory: inventory)
        store.add(AutoStopRule(processName: captured.name, executablePath: captured.executablePath,
                               runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1)
        var changed = captured
        changed.executablePath = nil
        inventory.result = .success([changed])
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty)
        XCTAssertFalse(store.events.contains { $0.outcome == .processEnded })
        XCTAssertTrue(store.events.first?.detail.contains("identity changed") == true)
    }

    func testDismissedNameOnlyPromptDoesNotReturnAfterExecutableMoves() async {
        let inventory = ManualInventory([row()])
        let defaults = makeDefaults()
        let store = AutoStopRulesStore(userDefaults: defaults, inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        store.dismissCurrentPrompt()
        inventory.result = .success([row(path: "/Applications/Moved.app/Contents/MacOS/Example")])
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty, "Moving a still-running executable must not undo Dismiss")
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty)
    }

    private func manager(
        _ inventory: any ProcessInventoryProviding,
        verification: (any ProcessInventoryProviding)? = nil,
        signaler: ManualSignaler = ManualSignaler(),
        lifecycle: any ProcessLifecycleServicing = ManualLifecycle(),
        currentPID: Int32 = 99999,
        now: @escaping () -> Date = Date.init
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: verification ?? inventory,
            processSignaler: signaler, lifecycle: lifecycle, settleAfterProcessChange: {},
            currentPID: currentPID, now: now
        )
        manager.enableNotifications = false
        return manager
    }

    private func examplePreset() -> WatchedAppPreset {
        WatchedAppPreset(displayName: "Example", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Example.app")
    }

    private func row(pid: Int32 = 42, path: String = "/Applications/Example.app/Contents/MacOS/Example") -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1,
                   command: "/Applications/Example.app/Contents/MacOS/Example", executablePath: path,
                   elapsedTime: "10:00", startTime: "same-start", netInKB: nil, netOutKB: nil,
                   diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Condition did not become true")
    }
}

private final class ManualInventory: ProcessInventoryProviding, @unchecked Sendable {
    var result: Result<[AppProcess], ProcessInventoryError>
    private(set) var count = 0
    init(_ rows: [AppProcess]) { result = .success(rows) }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        return result
    }
}

private actor ManualBlockingInventory: ProcessInventoryProviding {
    let result: Result<[AppProcess], ProcessInventoryError>
    let honorsCancellation: Bool
    private(set) var count = 0
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(result: Result<[AppProcess], ProcessInventoryError>, honorsCancellation: Bool = false) {
        self.result = result
        self.honorsCancellation = honorsCancellation
    }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        if !released {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { continuation = $0 }
        }
        return honorsCancellation && Task.isCancelled ? .failure(.cancelled) : result
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ManualSignaler: ProcessSignaling {
    var sent: [Int32] = []
    func send(_ signal: Int32, to pid: Int32) -> Bool { sent.append(pid); return true }
    func isAlive(_ pid: Int32) -> Bool { true }
}

private final class ManualSignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int32, Int32)] = []
    var pids: [Int32] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.1 } }
    var signals: [Int32] { lock.lock(); defer { lock.unlock() }; return entries.map { $0.0 } }
    func append(_ signal: Int32, _ pid: Int32) { lock.lock(); defer { lock.unlock() }; entries.append((signal, pid)) }
}

private final class ManualCancellationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var sawCancellation: Bool { lock.withLock { cancelled } }
    func record() { lock.withLock { cancelled = true } }
}

private final class ManualLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    var onWait: (@Sendable () async -> Bool)?
    private(set) var openRequests = 0
    private(set) var terminatedNames: [String] = []
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        terminatedNames.append(preset.mainProcessName)
        return .signalled
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        terminatedNames.append(name)
        return .signalled
    }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { await onWait?() ?? true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { openRequests += 1; return .opened }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await onWait?() ?? true }

}
