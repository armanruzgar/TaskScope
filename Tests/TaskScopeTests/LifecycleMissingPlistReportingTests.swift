import XCTest
@testable import TaskScope

/// P7 — "a missing launch-agent plist makes EVERY stop on the default preset report failure".
///
/// These tests compose the REAL `ProcessLifecycleController` (driven by a fake
/// `ProcessLifecycleRuntime`, following the conventions of
/// `ProcessLifecycleMatchingTests.LifecycleRuntimeHarness`) with the REAL
/// `ProcessManager` quit paths.
@MainActor
final class P7MissingPlistReportsFailureTests: XCTestCase {

    // MARK: - Precondition: does `lifecycleUserLaunchAgentJobs` really override user input?

    /// Only the immutable built-in identity receives privileged lifecycle configuration.
    func testOnlyCanonicalGlobalProtectPresetReceivesBuiltInLifecycleJobs() {
        let userCleared = WatchedAppPreset(
            displayName: "GlobalProtect",
            mainProcessName: "GlobalProtect",
            helperProcessNames: ["PanGPA"],
            protectedProcessNames: ["PanGPS"],
            appPath: "/Applications/GlobalProtect.app",
            userLaunchAgentJobs: []
        )

        XCTAssertTrue(userCleared.userLaunchAgentJobs.isEmpty)
        XCTAssertTrue(userCleared.lifecycleUserLaunchAgentJobs.isEmpty)

        let userReplaced = WatchedAppPreset(
            displayName: "GlobalProtect",
            mainProcessName: "GlobalProtect",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/GlobalProtect.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(label: "mine.agent", plistPath: "/Users/me/mine.plist")
            ]
        )
        XCTAssertEqual(userReplaced.lifecycleUserLaunchAgentJobs.map(\.label), ["mine.agent"])
        XCTAssertEqual(
            WatchedAppPreset.globalProtect.lifecycleUserLaunchAgentJobs.map(\.label),
            [
                "com.paloaltonetworks.gp.pangpa",
                "com.paloaltonetworks.gp.pangps"
            ]
        )

        // Out of the box the seeded preset is exactly this shape.
        XCTAssertEqual(WatchedAppsStore(userDefaults: emptyDefaults(), key: "P7.seed").presets,
                       [.globalProtect])
    }

    // MARK: - P7 proof 1: nothing was running, stop still reports .failed

    func testStopOnDefaultPresetWithAbsentPlistIsNotReportedAsFailure() async {
        let harness = P7LifecycleRuntimeHarness(
            existingPaths: [],                      // GlobalProtect is not installed on this Mac
            respond: { command in
                // `launchctl print gui/501/com.paloaltonetworks.gp.pangpa` -> service not found
                P7LifecycleRuntimeHarness.notLoaded(command)
            },
            inventory: []                           // nothing is running
        )
        let preset = WatchedAppPreset.globalProtect
        let manager = makeManager(
            inventory: P7QueuedInventory(results: [.success([])]),
            lifecycle: P7RealControllerLifecycleService(runtime: harness.runtime)
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.quitAllKillable(preset)

        // An absent plist with the job not loaded means there was nothing to unload,
        // so the stop succeeded. `.missing` is now reserved for the bootstrap paths,
        // where an absent plist really does block the requested action.
        // Only the interface agent is in scope: a stop that does not disconnect
        // leaves the session VPN service job alone.
        XCTAssertEqual(
            manager.lifecycleReport?.jobs.map(\.state),
            [.alreadyUnloaded]
        )
        XCTAssertTrue(manager.lifecycleReport?.jobs.allSatisfy(\.succeeded) ?? false)

        XCTAssertEqual(
            result.status,
            .completed,
            "Nothing was running and nothing failed, yet the stop reports: \(result.message)"
        )
        XCTAssertEqual(result.message, "No watched app or user helpers found.")
    }

    // MARK: - P7 proof 2: processes really were stopped, stop still reports .failed

    func testStopThatActuallyStoppedEveryProcessIsNotReportedAsFailure() async {
        let running = [process(pid: 501, name: "GlobalProtect"), process(pid: 502, name: "PanGPA")]
        let harness = P7LifecycleRuntimeHarness(
            existingPaths: [],
            respond: { command in
                P7LifecycleRuntimeHarness.notLoaded(command)
            },
            inventory: running
        )
        let preset = WatchedAppPreset.globalProtect
        let manager = makeManager(
            inventory: P7QueuedInventory(results: [
                // `currentSnapshot(for:)` — GlobalProtect and its helper are running.
                .success(running),
                // `refreshAfterMutation()` — both are gone: the stop fully succeeded.
                .success([])
            ]),
            lifecycle: P7RealControllerLifecycleService(runtime: harness.runtime)
        )
        manager.watchedAppsProvider = { [preset] }

        let result = await manager.quitAllKillable(preset)

        XCTAssertEqual(result.message, "GlobalProtect and helpers quit.")
        XCTAssertEqual(harness.signals.map(\.signal), [SIGTERM, SIGTERM])
        XCTAssertEqual(harness.signals.map(\.pid), [501, 502])
        XCTAssertFalse(manager.snapshots.first?.hasAny ?? true, "precondition: everything stopped")
        XCTAssertEqual(
            result.status,
            .completed,
            "Every watched process was stopped, yet the stop reports: \(result.message)"
        )
    }

    // MARK: - P7 proof 3: the self-contradictory `.missing` at ProcessLifecycleController:224-234

    func testLoadedJobThatWasBootedOutAndVerifiedUnloadedCountsAsSuccess() async {
        let harness = P7LifecycleRuntimeHarness(
            existingPaths: [],                      // plist absent
            queuedResults: [
                P7LifecycleRuntimeHarness.result(exitCode: 0),                             // print -> loaded
                P7LifecycleRuntimeHarness.result(exitCode: 0),                             // bootout -> ok
                P7LifecycleRuntimeHarness.result(stderr: "Could not find service", exitCode: 113) // print -> gone
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/missing/example.plist"),
            runtime: harness.runtime
        )

        // The controller's own detail string says the work succeeded.
        XCTAssertEqual(batch.jobs.count, 1)
        XCTAssertTrue(batch.jobs[0].detail.contains("loaded job was still unloaded and verified"))
        XCTAssertTrue(harness.commands.contains { $0.contains("launchctl bootout") })

        XCTAssertTrue(
            batch.jobs[0].succeeded,
            "detail says \"\(batch.jobs[0].detail)\" but state is .\(batch.jobs[0].state.rawValue), which is not a success"
        )
        XCTAssertTrue(batch.succeeded)
    }

    // MARK: - Helpers

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        lifecycle: any ProcessLifecycleServicing
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: P7NoopSignaler(),
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        return manager
    }

    private func presetWithAgent(plistPath: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(label: "example.agent", plistPath: plistPath)
            ]
        )
    }

    private func emptyDefaults() -> UserDefaults {
        let suite = "TaskScope.LifecycleEngine.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func process(pid: Int32, name: String) -> AppProcess {
        let path = name == "PanGPS"
            ? "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS"
            : "/Applications/GlobalProtect.app/Contents/MacOS/\(name)"
        return AppProcess(
            pid: pid,
            parentPID: 1,
            uid: getuid(),
            cpu: 0,
            memoryMB: 0,
            command: path,
            executablePath: path,
            elapsedTime: "00:10",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

// MARK: - Real controller behind the ProcessManager seam

private struct P7RealControllerLifecycleService: ProcessLifecycleServicing {
    let runtime: ProcessLifecycleRuntime

    func appBundleExists(at path: String) -> Bool {
        runtime.fileExists(path)
    }

    func settleAfterProcessChange() async {
        await ProcessLifecycleController.settleAfterProcessChange(runtime: runtime)
    }

    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: preset.mainProcessName,
            forceIfStillRunning: true,
            expectedExecutableDirectory: preset.mainExecutableDirectory,
            runtime: runtime
        )
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        await ProcessLifecycleController.terminateProcess(
            named: name,
            forceIfStillRunning: true,
            expectedExecutableDirectory: preset.bundleContentsDirectory,
            runtime: runtime
        )
    }

    func isProcessNamedRunning(_ name: String) async -> Bool {
        await ProcessLifecycleController.isProcessNamedRunning(name, runtime: runtime)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: runtime)
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: runtime)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        await ProcessLifecycleController.ensureSystemLaunchDaemons(for: preset, runtime: runtime)
    }

    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool {
        await ProcessLifecycleController.waitForProcessNamed(
            name,
            timeoutSeconds: timeoutSeconds,
            runtime: runtime
        )
    }

    func openAppBundle(at path: String) async -> Bool {
        await ProcessLifecycleController.openAppBundle(at: path, runtime: runtime)
    }
}

// MARK: - Fakes (same shape as ProcessLifecycleMatchingTests.LifecycleRuntimeHarness)

private final class P7LifecycleRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private let respond: (@Sendable (String) -> ShellCommandResult)?
    private var queuedResults: [ShellCommandResult]
    private var inventory: [AppProcess]
    private var recordedCommands: [String] = []
    private var recordedSleepDurations: [UInt64] = []
    private var recordedSignals: [(signal: Int32, pid: Int32)] = []

    init(
        existingPaths: Set<String>,
        respond: (@Sendable (String) -> ShellCommandResult)? = nil,
        queuedResults: [ShellCommandResult] = [],
        inventory: [AppProcess] = []
    ) {
        self.existingPaths = existingPaths
        self.respond = respond
        self.queuedResults = queuedResults
        self.inventory = inventory
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: getuid(),
            fileExists: { [self] path in
                existingPaths.contains(path)
            },
            launchAgentLabel: { _ in nil },
            runCommand: { [self] command, _ in
                lock.withLock {
                    recordedCommands.append(command)
                    if let respond {
                        return respond(command)
                    }
                    guard !queuedResults.isEmpty else {
                        return ShellCommandResult(
                            command: command,
                            stdout: "",
                            stderr: "No fake command result configured.",
                            exitCode: -1
                        )
                    }
                    var response = queuedResults.removeFirst()
                    response.command = command
                    return response
                }
            },
            loadProcessInventory: { [self] in
                lock.withLock { .success(inventory) }
            },
            executablePathForPID: { [self] pid in
                lock.withLock { inventory.first { $0.pid == pid }?.executablePath }
            },
            sendSignal: { [self] signal, pid in
                lock.withLock {
                    recordedSignals.append((signal, pid))
                    inventory.removeAll { $0.pid == pid }
                }
                return true
            },
            isProcessAlive: { _ in false },
            sleep: { [self] duration in
                lock.withLock {
                    recordedSleepDurations.append(duration)
                }
            },
            systemUptime: { 0 }
        )
    }

    var commands: [String] {
        lock.withLock { recordedCommands }
    }

    var signals: [(signal: Int32, pid: Int32)] {
        lock.withLock { recordedSignals }
    }

    static func result(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32
    ) -> ShellCommandResult {
        ShellCommandResult(command: "fake", stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    static func notLoaded(_ command: String) -> ShellCommandResult {
        ShellCommandResult(
            command: command,
            stdout: "",
            stderr: "Could not find service \"com.paloaltonetworks.gp.pangpa\" in domain for login",
            exitCode: 113
        )
    }
}

private final class P7QueuedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            guard results.count > 1 else {
                return results.first ?? .failure(.commandFailed("No fake result configured."))
            }
            return results.removeFirst()
        }
    }
}

private final class P7NoopSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}
