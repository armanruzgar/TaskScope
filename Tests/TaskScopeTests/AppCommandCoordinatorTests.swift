import XCTest
@testable import TaskScope

@MainActor
final class AppCommandCoordinatorTests: XCTestCase {
    func testURLContractOnlyParsesNonDestructiveRefresh() throws {
        XCTAssertEqual(
            try TaskScopeURLParser.command(from: XCTUnwrap(URL(string: "taskscope://refresh"))).get(),
            .refresh
        )
        for action in ["open", "stop", "quit"] {
            let url = try XCTUnwrap(URL(string: "taskscope://\(action)/GlobalProtect"))
            XCTAssertEqual(
                TaskScopeURLParser.command(from: url),
                .failure(.unsupportedAction(action))
            )
        }
    }

    func testURLContractRejectsUnsupportedRoutes() throws {
        let unsupported = try XCTUnwrap(URL(string: "taskscope://destroy/everything"))
        XCTAssertEqual(
            TaskScopeURLParser.command(from: unsupported),
            .failure(.unsupportedAction("destroy"))
        )
    }

    func testRefreshURLRejectsCredentialsPortPathQueryAndFragment() throws {
        let invalidURLs = [
            "taskscope://user@refresh",
            "taskscope://refresh:1234",
            "taskscope://refresh/path",
            "taskscope://refresh?source=test",
            "taskscope://refresh?",
            "taskscope://refresh#section",
            "taskscope://refresh#"
        ]

        for value in invalidURLs {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(
                TaskScopeURLParser.command(from: url),
                .failure(.invalidRefreshURL),
                value
            )
        }

        XCTAssertEqual(
            TaskScopeURLParser.command(
                from: try XCTUnwrap(URL(string: "taskscope://refresh/"))
            ),
            .failure(.invalidRefreshURL)
        )
        XCTAssertEqual(
            TaskScopeURLParser.command(
                from: try XCTUnwrap(URL(string: "taskscope://Refresh"))
            ),
            .failure(.unsupportedAction("Refresh"))
        )
    }

    func testLoggingSubsystemUsesConfiguredBundleIdentifier() {
        XCTAssertEqual(
            TaskScopeLogging.subsystem(bundleIdentifier: "com.example.TaskScope"),
            "com.example.TaskScope"
        )
        XCTAssertEqual(TaskScopeLogging.subsystem(bundleIdentifier: nil), "TaskScope")
    }

    func testColdLaunchCommandIsDeliveredExactlyOnceAfterInstall() async {
        let bus = AppCommandBus()
        let pending = Task { await bus.submit(.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "Example"))) }
        await Task.yield()
        var received: [TaskScopeCommand] = []

        bus.install { command in
            received.append(command)
            return TaskScopeCommandResult(status: .completed, message: "done")
        }

        let result = await pending.value
        XCTAssertEqual(received, [.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "Example"))])
        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "done"))
    }

    func testColdLaunchCommandsDrainInSubmissionOrder() async {
        let bus = AppCommandBus()
        let first = Task { await bus.submit(.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "First"))) }
        await Task.yield()
        let second = Task { await bus.submit(.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "Second"))) }
        await Task.yield()
        var received: [TaskScopeCommand] = []

        bus.install { command in
            received.append(command)
            await Task.yield()
            return TaskScopeCommandResult(status: .completed, message: "done")
        }

        _ = await first.value
        _ = await second.value
        XCTAssertEqual(received, [.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "First")), .openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "Second"))])
    }

    func testCoordinatorReturnsMeaningfulMissingPresetResult() async {
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [] }
        )

        let missing = await coordinator.perform(.openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "Missing")))

        XCTAssertEqual(missing.status, .rejected)
        XCTAssertTrue(missing.message.contains("Missing"))
    }

    func testExplicitRefreshPublishesJoinedSilentRefreshResult() async {
        let inventory = CoordinatorBlockingInventory()
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [] }
        )

        let silentRefresh = Task {
            await manager.refreshWatchedStatus(showMessage: false)
        }
        await inventory.waitForLoad()
        let explicitRefresh = Task { await coordinator.perform(.refresh) }
        await Task.yield()

        XCTAssertEqual(manager.message, "Idle.")
        await inventory.finish()
        _ = await silentRefresh.value
        let result = await explicitRefresh.value

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.message, manager.message)
        XCTAssertNotEqual(result.message, "Idle.")
    }

    /// A successful watched read reports its own outcome and clears the old
    /// inventory failure so the Processes tab does not keep showing an error.
    func testRefreshReportsSuccessAndClearsAStaleProcessListError() async {
        let inventory = ScriptedInventory(results: [
            .failure(.commandFailed("ps timed out")),
            .success([])
        ])
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        let coordinator = AppCommandCoordinator(processManager: manager, presets: { [] })

        await manager.loadProcessList(showMessage: false)
        XCTAssertEqual(manager.processLoadError, "ps timed out", "precondition: a stale-list error is recorded")

        let result = await coordinator.perform(.refresh)

        XCTAssertEqual(result.status, .completed, result.message)
        XCTAssertEqual(result.message, "No watched processes")
        XCTAssertNil(manager.processLoadError, "a successful inventory read clears the stale failure")
        XCTAssertEqual(manager.processListLoadError, "ps timed out", "the list itself was not reloaded")
    }

    func testRefreshReportsFailureWhenItsOwnReadFails() async {
        let inventory = ScriptedInventory(results: [.failure(.commandFailed("ps timed out"))])
        let manager = ProcessManager(
            processInventory: inventory,
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        let coordinator = AppCommandCoordinator(processManager: manager, presets: { [] })

        let result = await coordinator.perform(.refresh)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("ps timed out"), result.message)
    }

    func testEntityCommandRejectsReplacementPresetWithSameDisplayName() async {
        let selectedID = UUID()
        let replacement = WatchedAppPreset(
            id: UUID(),
            displayName: "Example",
            mainProcessName: "ReplacementProcess",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Replacement.app"
        )
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [replacement] }
        )

        let result = await coordinator.perform(
            .stopPresetEntity(
                WatchedPresetCommandTarget(id: selectedID, displayName: "Example")
            )
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("Example"))
        XCTAssertNil(manager.lifecycleReport)
    }

    func testStartupVerificationRejectsAllExplicitCommands() async {
        let manager = ProcessManager(
            processInventory: EmptyInventory(),
            processSignaler: NoopSignaler(),
            lifecycle: NoopLifecycle(),
            settleAfterProcessChange: {}
        )
        let coordinator = AppCommandCoordinator(
            processManager: manager,
            presets: { [.globalProtect] },
            allowsCommands: { false }
        )

        for command in [
            TaskScopeCommand.refresh,
            .statusPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "GlobalProtect")),
            .openPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "GlobalProtect")),
            .stopPresetEntity(.init(id: WatchedAppPreset.globalProtectID, displayName: "GlobalProtect"))
        ] {
            let result = await coordinator.perform(command)
            XCTAssertEqual(result.status, .rejected)
            XCTAssertTrue(result.message.contains("startup verification"))
        }
    }

    func testURLHandlerNotifiesLaunchPolicyBeforeDispatchingCommand() async throws {
        var events: [String] = []
        let handler = URLSchemeHandler(
            submitCommand: { command in
                events.append("dispatch:\(command)")
                return TaskScopeCommandResult(status: .completed, message: "done")
            },
            willHandleCommand: { command in
                events.append("prepare:\(command)")
            }
        )

        let result = await handler.handle(
            try XCTUnwrap(URL(string: "taskscope://refresh"))
        )

        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "done"))
        XCTAssertEqual(events, ["prepare:refresh", "dispatch:refresh"])
    }
}

private final class ScriptedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            guard !results.isEmpty else { return .failure(.commandFailed("exhausted")) }
            return results.count == 1 ? results[0] : results.removeFirst()
        }
    }
}

private struct EmptyInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success([])
    }
}

private actor CoordinatorBlockingInventory: ProcessInventoryProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        didStart = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return .success([])
    }

    func waitForLoad() async {
        guard !didStart else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private struct NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct NoopLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .opened }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}
