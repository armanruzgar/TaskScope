import Darwin
import XCTest
import ViewInspector
@testable import TaskScope

@MainActor
final class ReviewCoreRegressionTests: XCTestCase {
    nonisolated(unsafe) private var suites: [(name: String, defaults: UserDefaults)] = []

    override func tearDown() {
        for suite in suites { suite.defaults.removePersistentDomain(forName: suite.name) }
        suites.removeAll()
        super.tearDown()
    }

    func testWatchedBannerTracksLatestWatchedReadWithDateWithoutChangingListTime() async throws {
        for loadList in [false, true] {
            let inventory = Inventory([row()])
            var now = Date(timeIntervalSince1970: 100)
            let manager = manager(inventory, now: { now })
            if loadList { await manager.loadProcessList() }
            now = Date(timeIntervalSince1970: 100_000)
            await manager.refreshWatchedStatus()
            inventory.result = .failure(.commandFailed("read failed"))
            await manager.refreshWatchedStatus()
            let defaults = defaults()
            let view = PresetsSectionView(
                processManager: manager, loginItemManager: LoginItemManager(service: LoginService()),
                settings: SettingsStore(userDefaults: defaults), watchedApps: WatchedAppsStore(userDefaults: defaults),
                confirmationState: ProcessConfirmationState()
            )
            let expected = "Last successful inventory: \(now.formatted(date: .abbreviated, time: .standard))"
            XCTAssertNoThrow(try view.inspect().find(text: expected))
            XCTAssertEqual(manager.lastSuccessfulInventoryAt, loadList ? Date(timeIntervalSince1970: 100) : nil)
        }
    }

    func testStaleAndChangedSingleStopsKeepExtendedMetrics() async {
        for changed in [false, true] {
            let captured = row()
            let bystander = row(pid: 43)
            let inventory = Inventory([captured, bystander])
            let manager = manager(inventory)
            await manager.beginExtendedMetrics()
            await manager.loadProcessList()
            var moved = captured
            moved.executablePath = "/Applications/Moved.app/Contents/MacOS/Example"
            inventory.result = .success(changed ? [moved, bystander] : [bystander])
            let result = await manager.terminate(captured, forceKill: changed)
            XCTAssertEqual(result, changed ? .identityChanged : .stale)
            let displayed = manager.displayProcesses().first { $0.pid == bystander.pid }
            XCTAssertEqual(displayed?.netInKB, 12)
            XCTAssertEqual(displayed?.netOutKB, 13)
            XCTAssertEqual(displayed?.diskReadBytes, 14)
            XCTAssertEqual(displayed?.diskWriteBytes, 15)
        }
    }

    func testZombieSingleAndBatchStopsAreEndedWhileMovedPathsStayChanged() async throws {
        let captured = row()
        var moved = captured
        moved.executablePath = "/Applications/Moved.app/Contents/MacOS/Example"
        for replacement in [try zombie(), moved] {
            let inventory = Inventory([replacement])
            let signaler = Signaler()
            let manager = manager(inventory, signaler: signaler)
            let isZombie = replacement.command == "<defunct>"
            for force in [false, true] {
                let result = await manager.terminate(captured, forceKill: force)
                XCTAssertEqual(result, isZombie ? .stale : .identityChanged)
                await manager.batchTerminate([captured.identity], forceKill: force)
                XCTAssertEqual(manager.batchActionReport?.targets.first?.state, isZombie ? .stale : .identityChanged)
            }
            XCTAssertTrue(signaler.sent.isEmpty)
        }
    }

    func testZombiePendingStopsAndPromptsAreRecordedAsEnded() async throws {
        for action in [AutoStopRule.Action.kill, .prompt] {
            let inventory = Inventory([row()])
            let store = store(inventory)
            store.start { _, _, _ in .requestedStillRunning }
            store.stop()
            XCTAssertTrue(store.add(rule(action)))
            await store.evaluateNow()
            inventory.result = .success([try zombie()])
            await store.evaluateNow()
            XCTAssertEqual(store.events.first?.outcome, action == .kill ? .stopped : .processEnded)
            XCTAssertFalse(store.events.contains { $0.outcome == .failed })
            XCTAssertTrue(store.pendingPrompts.isEmpty)
        }
    }

    func testZombieAutomaticAndConfirmedPromptVerificationAreRecordedAsEnded() async throws {
        for action in [AutoStopRule.Action.kill, .prompt] {
            let inventory = Inventory([row()])
            let verification = Inventory([try zombie()])
            let signaler = Signaler()
            let manager = manager(inventory, verification: verification, signaler: signaler)
            let store = store(inventory)
            store.start(perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store))
            store.stop()
            XCTAssertTrue(store.add(rule(action)))
            await store.evaluateNow()
            if action == .prompt { await store.stopCurrentPrompt() }
            XCTAssertEqual(store.events.first?.outcome, .processEnded)
            XCTAssertFalse(store.events.contains { $0.outcome == .failed })
            XCTAssertTrue(signaler.sent.isEmpty)
        }
    }

    func testStillMatchingEditCancelsUnsignalledAutomaticStopWithoutFailure() async {
        let inventory = Inventory([row()])
        let verification = BlockingInventory(row())
        let signaler = Signaler()
        let manager = manager(inventory, verification: verification, signaler: signaler)
        let store = store(inventory)
        store.start(perform: AutoStopActionHandlerFactory.make(processManager: manager, rules: store))
        store.stop()
        var rule = rule(.kill)
        XCTAssertTrue(store.add(rule))
        let evaluation = Task { await store.evaluateNow() }
        await verification.waitUntilEntered()
        rule.runtimeMinutes = 2
        XCTAssertTrue(store.update(rule))
        await verification.release()
        await evaluation.value
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertTrue(store.events.isEmpty, "An edited, never-signalled stop is not a failure")
        await store.evaluateNow()
        XCTAssertEqual(signaler.sent, [row().pid])
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])
    }

    func testUnansweredNameOnlyPromptFollowsMovedExecutableButDismissStaysDismissed() async {
        for dismissed in [false, true] {
            let inventory = Inventory([row()])
            let store = store(inventory)
            XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
            await store.evaluateNow()
            if dismissed { store.dismissCurrentPrompt() }
            var moved = row()
            moved.executablePath = "/Applications/Moved.app/Contents/MacOS/Example"
            inventory.result = .success([moved])
            for _ in 0..<2 {
                await store.evaluateNow()
                XCTAssertEqual(store.pendingPrompts.count, dismissed ? 0 : 1)
                if !dismissed { XCTAssertEqual(store.currentPrompt?.process.identity, moved.identity) }
            }
        }
    }

    /// A10-3 (lead): a prompt that follows its moved executable is still the
    /// same, unanswered prompt. It records no "identity changed" failure and
    /// keeps its place in the queue.
    func testPromptThatFollowsAMovedExecutableRecordsNoFailureAndKeepsItsPlace() async {
        let first = row(pid: 42)
        let second = row(pid: 43)
        let inventory = Inventory([first, second])
        let store = store(inventory)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [42, 43])

        var moved = first
        moved.executablePath = "/Applications/Moved.app/Contents/MacOS/Example"
        inventory.result = .success([moved, second])
        await store.evaluateNow()

        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [42, 43], "the moved process keeps its place")
        XCTAssertEqual(store.currentPrompt?.process.identity, moved.identity)
        XCTAssertEqual(store.events.map(\.detail), [], "nothing failed or ended")

        // A path-bound rule no longer matches the moved process: its prompt
        // ends, and that is recorded as an identity change.
        let pathInventory = Inventory([first])
        let pathStore = self.store(pathInventory)
        XCTAssertTrue(pathStore.add(rule(.prompt)))
        await pathStore.evaluateNow()
        XCTAssertEqual(pathStore.pendingPrompts.count, 1)
        pathInventory.result = .success([moved])
        await pathStore.evaluateNow()
        XCTAssertEqual(pathStore.pendingPrompts.count, 0)
        XCTAssertEqual(pathStore.events.map(\.detail),
                       ["Process identity changed before the prompt was handled; nothing was stopped."])
    }

    func testDefinitiveBootoutRefusalInspectsOnceForUnloadAndDisable() async {
        for keepOff in [false, true] {
            for code: Int32 in [1, 5, 150] {
                let commands = Commands(bootoutCode: code)
                var preset = WatchedAppPreset(displayName: "Example", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Example.app")
                preset.userLaunchAgentJobs = [UserLaunchAgentJob(label: "example.agent", plistPath: "/fake/agent.plist")]
                let result = keepOff
                    ? await ProcessLifecycleController.disableUserLaunchAgents(for: preset, runtime: commands.runtime)
                    : await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: commands.runtime)
                XCTAssertFalse(result.succeeded)
                let prints = await commands.prints
                let pollingSleeps = await commands.pollingSleeps
                XCTAssertEqual(prints, 2, "One initial inspection and one after definitive refusal")
                XCTAssertEqual(pollingSleeps, 0, "A definitive refusal must not hold the gate for 30 seconds")
            }
        }
    }

    func testLoadedJobsWithoutPIDAllowDisconnectAndKeepOffVerdict() async {
        let commands = Commands()
        let runtime = commands.runtime
        let result = await GlobalProtectAccessibilityDisconnect.disconnectIfNeeded(runtime: .init(
            lifecycle: runtime,
            requestAccessibility: { XCTFail("No running service requires Accessibility"); return false },
            application: { XCTFail("No application should open"); return nil },
            disconnect: { _, _ in XCTFail("No disconnect should run"); return .disconnected }
        ))
        XCTAssertEqual(result, .disconnected)
        let manager = manager(Inventory([]))
        manager.dependencies.watchedPresets = { [.globalProtect] }
        manager.dependencies.globalProtectServiceObservation = { await GlobalProtectServiceObservation.read(runtime: runtime) }
        let keepOff = await manager.keepOff(.globalProtect)
        XCTAssertEqual(keepOff.status, .completed)
    }

    func testUnreadableJobOutputAndUnattributedPIDRemainUnknown() async {
        for output in ["", "unrecognized", "service = {\n\tstate = waiting\n\tpid = invalid\n}", "service = {\n\tstate = running\n\tpid = 42\n}", "service = {\n\tstate = waiting\n", "service = {\n\tstate = waiting\n\tpid = 42\n\tpid = 43\n}"] {
            let commands = Commands(output: output)
            let state = await GlobalProtectServiceObservation.read(runtime: commands.runtime)
            XCTAssertEqual(state.session, .unknown)
            XCTAssertEqual(state.system, .unknown)
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "TaskScope.ReviewCore.\(UUID())"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        suites.append((suite, defaults))
        return defaults
    }

    private func store(_ inventory: any ProcessInventoryProviding) -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: defaults(), inventory: inventory,
                           pollingController: ProcessPollingController(sleep: { _ in false }))
    }

    private func rule(_ action: AutoStopRule.Action) -> AutoStopRule {
        AutoStopRule(processName: "Example", executablePath: row().executablePath, runtimeMinutes: 1, action: action)
    }

    private func manager(_ inventory: any ProcessInventoryProviding,
                         verification: (any ProcessInventoryProviding)? = nil,
                         signaler: Signaler = Signaler(), now: @escaping () -> Date = Date.init) -> ProcessManager {
        let manager = ProcessManager(processInventory: inventory, verificationInventory: verification ?? inventory,
                                     processSignaler: signaler, lifecycle: Lifecycle(), settleAfterProcessChange: {},
                                     currentPID: 99999, now: now, dependencies: .inert)
        manager.enableNotifications = false
        return manager
    }

    private func row(pid: Int32 = 42) -> AppProcess {
        AppProcess(pid: pid, parentPID: 2, uid: getuid(), cpu: 0, memoryMB: 1, command: "Example",
                   executablePath: "/Applications/Example.app/Contents/MacOS/Example", elapsedTime: "10:00",
                   startTime: "Sat Oct 17 05:26:42 2026", netInKB: 12, netOutKB: 13, diskReadBytes: 14, diskWriteBytes: 15)
    }

    private func zombie() throws -> AppProcess {
        try XCTUnwrap(ProcessListReader.parseProcessLine("42 2 \(getuid()) 0.0 0 Sat Oct 17 05:26:42 2026 10:00 <defunct>"))
    }
}

private final class Inventory: ProcessInventoryProviding, @unchecked Sendable {
    var result: Result<[AppProcess], ProcessInventoryError>
    init(_ rows: [AppProcess]) { result = .success(rows) }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        result.map { rows in rows.map { row in
            var row = row
            if !fetchExtendedStats {
                row.netInKB = nil; row.netOutKB = nil; row.diskReadBytes = nil; row.diskWriteBytes = nil
            }
            return row
        } }
    }
}

private actor BlockingInventory: ProcessInventoryProviding {
    let row: AppProcess
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(_ row: AppProcess) { self.row = row }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if !released {
            entered = true
            entryWaiter?.resume(); entryWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return .success([row])
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() {
        released = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
}

private final class Signaler: ProcessSignaling {
    var sent: [Int32] = []
    func send(_ signal: Int32, to pid: Int32) -> Bool { sent.append(pid); return true }
    func isAlive(_ pid: Int32) -> Bool { true }
}

private struct Lifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .failed("Fake launch failed.") }
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult { .disconnected }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}

private struct LoginService: LoginItemServicing {
    var state: LoginItemState { .notRegistered }
    func register() throws { XCTFail("Unexpected registration") }
    func unregister() throws { XCTFail("Unexpected unregistration") }
    func openSystemSettings() { XCTFail("Unexpected settings request") }
}

private actor Commands {
    let bootoutCode: Int32
    let output: String
    var prints = 0
    var pollingSleeps = 0
    init(bootoutCode: Int32 = 0, output: String = "service = {\n\tstate = waiting\n}") {
        self.bootoutCode = bootoutCode; self.output = output
    }
    nonisolated var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(userID: 501, fileExists: { _ in true }, launchAgentLabel: { _ in "example.agent" },
                                runCommand: { await self.run($0, $1) }, loadProcessInventory: { .success([]) },
                                executablePathForPID: { _ in nil },
                                sendSignal: { _, _ in XCTFail("Unexpected signal"); return false },
                                isProcessAlive: { _ in false }, sleep: { await self.sleep($0) }, systemUptime: { 0 }, isAppBundle: { _ in false })
    }
    func run(_ command: ExternalCommand, _ timeout: TimeInterval) -> ShellCommandResult {
        if command.isLaunchctl("print") { prints += 1 }
        let bootout = command.isLaunchctl("bootout")
        return ShellCommandResult(command: command, stdout: bootout ? "" : output,
                                  stderr: bootout && bootoutCode != 0 ? "Operation not permitted" : "",
                                  exitCode: bootout ? bootoutCode : 0)
    }
    func sleep(_ nanoseconds: UInt64) { if nanoseconds == 500_000_000 { pollingSleeps += 1 } }
}
