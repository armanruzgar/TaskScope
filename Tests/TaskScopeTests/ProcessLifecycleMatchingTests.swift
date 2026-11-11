import XCTest
@testable import TaskScope

final class ProcessLifecycleMatchingTests: XCTestCase {
    func testConfiguredNamesAreMatchedAsExactLiteralBasenames() {
        let names = [
            "Codex (Renderer)",
            "a.b",
            "worker+child",
            "name[1]",
            "contains spaces",
            "-leading-dash"
        ]
        let inventory = names.enumerated().map { offset, name in
            process(pid: Int32(offset + 10), command: "/Applications/\(name)")
        } + [
            process(pid: 90, command: "/Applications/Codex Renderer"),
            process(pid: 91, command: "/Applications/aXb"),
            process(pid: 92, command: "/Applications/workerchild"),
            process(pid: 93, command: "/Applications/name1")
        ]

        for name in names {
            XCTAssertEqual(
                ProcessLifecycleController.matchingProcesses(named: name, in: inventory).map(\.name),
                [name]
            )
        }
    }

    func testMatchingDoesNotUseArgumentsOrSubstrings() {
        let inventory = [
            process(pid: 10, command: "/Applications/Example"),
            process(pid: 11, command: "/Applications/Example Helper"),
            process(pid: 12, command: "/Applications/Other")
        ]

        XCTAssertEqual(
            ProcessLifecycleController.matchingProcesses(named: "Example", in: inventory).map(\.pid),
            [10]
        )
    }

    func testTerminationTargetsExcludeTaskScopeAndScopeMainExecutableDirectory() {
        var spoofedArgv = process(
            pid: 13,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        spoofedArgv.executablePath = "/tmp/Example"
        let inventory = [
            process(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example"),
            process(pid: 11, command: "/tmp/Example"),
            process(pid: 12, command: "/Applications/Example.app/Contents/MacOS/Example"),
            spoofedArgv
        ]

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "Example",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
                excludingPID: 12,
                currentUID: 501,
                in: inventory
            ).map(\.pid),
            [10]
        )
    }

    func testScopedTerminationUsesKernelExecutableNameWhenProcessNameIsTruncated() {
        var target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        target.command = "/Applications/Ex"

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "Example",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
                excludingPID: 99,
                currentUID: 501,
                in: [target]
            ).map(\.pid),
            [10]
        )
    }

    func testTerminationAndRunningDetectionRequireRuntimeUserOwnership() async {
        let directory = "/Applications/Example.app/Contents/MacOS/"
        let others = [
            process(pid: 10, command: directory + "Example", uid: 502),
            process(pid: 11, command: directory + "Example", uid: 0),
            process(pid: 12, command: directory + "Example", uid: nil)
        ]
        let harness = LifecycleRuntimeHarness(existingPaths: [], commandResults: [], inventory: others)
        for scope: String? in [directory, nil] {
            let running = await ProcessTerminationController.isRunning(
                named: "Example", expectedExecutableDirectory: scope, runtime: harness.runtime
            )
            XCTAssertFalse(running)
            let appeared = await ProcessTerminationController.waitUntilRunning(
                named: "Example", timeoutSeconds: 0,
                expectedExecutableDirectory: scope, runtime: harness.runtime
            )
            XCTAssertFalse(appeared)
        }
        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example", forceIfStillRunning: true,
            expectedExecutableDirectory: directory, currentPID: 99, runtime: harness.runtime
        )
        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
        XCTAssertTrue(harness.sleepDurations.isEmpty)

        let mixed = LifecycleRuntimeHarness(
            existingPaths: [], commandResults: [],
            inventory: others + [process(pid: 13, command: directory + "Example")]
        )
        let mixedOutcome = await ProcessLifecycleController.terminateProcess(
            named: "Example", forceIfStillRunning: true,
            expectedExecutableDirectory: directory, currentPID: 99, runtime: mixed.runtime
        )
        XCTAssertEqual(mixedOutcome, .signalled)
        XCTAssertEqual(mixed.signals.map { $0.0 }, [SIGTERM, SIGKILL])
        XCTAssertEqual(mixed.signals.map { $0.1 }, [13, 13])
    }

    func testWaitUntilRunningStopsPollingAfterCancellationDuringSleep() async {
        let harness = LifecycleRuntimeHarness(existingPaths: [], commandResults: [])
        let task = Task {
            var runtime = harness.runtime
            runtime.sleep = { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return await ProcessTerminationController.waitUntilRunning(
                named: "Example", timeoutSeconds: 5,
                expectedExecutableDirectory: nil, runtime: runtime
            )
        }
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(harness.inventoryLoads, 1)
    }

    func testWaitUntilRunningSkipsInventoryWhenAlreadyCancelled() async {
        let harness = LifecycleRuntimeHarness(existingPaths: [], commandResults: [])
        for timeout: TimeInterval in [0, 5] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await ProcessTerminationController.waitUntilRunning(
                    named: "Example", timeoutSeconds: timeout,
                    expectedExecutableDirectory: nil, runtime: harness.runtime
                )
            }
            let result = await task.value
            XCTAssertFalse(result)
        }
        XCTAssertEqual(harness.inventoryLoads, 0)
    }

    func testPresetOpenVerificationRequiresExecutablePathFromLivePSSchema() async {
        let expectedDirectory = "/Applications/Example.app/Contents/MacOS/"
        let validRuntime = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [
                process(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example")
            ]
        ).runtime
        var spoofedArgv = process(
            pid: 11,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        spoofedArgv.executablePath = "/tmp/Example"
        let spoofedArgvRuntime = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [spoofedArgv]
        ).runtime

        let validResult = await ProcessLifecycleController.waitForProcessNamed(
            "Example",
            timeoutSeconds: 0,
            expectedExecutableDirectory: expectedDirectory,
            runtime: validRuntime
        )
        let spoofedResult = await ProcessLifecycleController.waitForProcessNamed(
            "Example",
            timeoutSeconds: 0,
            expectedExecutableDirectory: expectedDirectory,
            runtime: spoofedArgvRuntime
        )

        XCTAssertTrue(validResult)
        XCTAssertFalse(spoofedResult)
    }

    func testScopedTerminationRechecksKernelPathAndNeverSignalsForgedArgv() async {
        var forged = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        // Even if a stale/compromised inventory row appears in-bundle, the
        // signal-time proc_pidpath result is authoritative.
        forged.executablePath = "/Applications/Example.app/Contents/MacOS/Example"
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [forged],
            executablePathsAtSignal: [10: "/tmp/Example"]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testScopedTerminationFailsClosedWhenKernelPathCannotBeResolved() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            executablePathsAtSignal: [:]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testScopedTerminationRejectsExecToDifferentBinaryInsideSameBundle() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            executablePathsAtSignal: [
                10: "/Applications/Example.app/Contents/Library/LaunchServices/Other"
            ]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testTerminationReportsRejectedSignal() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            signalResults: [false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: false,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalRejected)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    func testTerminationReportsUnavailableEscalationInventory() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventoryResults: [
                .success([target]),
                .failure(.commandFailed("ps timed out"))
            ],
            executablePathsAtSignal: [target.pid: target.command]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .escalationUnavailable)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    func testTerminationReportsRejectedEscalationSignal() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target],
            signalResults: [true, false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalRejected)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM, SIGKILL])
    }

    func testRejectedTermIsNotReportedAsFailureWhenCapturedTargetExited() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventoryResults: [.success([target]), .success([])],
            executablePathsAtSignal: [target.pid: target.executablePath!],
            signalResults: [false]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .targetsExited)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM])
    }

    /// The graceful window is disclosed to the user, so it must really be
    /// waited out before SIGKILL, polling liveness on the way.
    func testGracefulStopWaitsOutTheWindowBeforeForceStoppingASurvivor() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [target]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM, SIGKILL])
        XCTAssertGreaterThanOrEqual(ProcessTerminationController.gracefulExitWindowSeconds, 3)
        XCTAssertEqual(Set(harness.sleepDurations), [ProcessTerminationController.livenessPollNanoseconds])
        let waited = Double(harness.sleepDurations.reduce(0, +)) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(waited, ProcessTerminationController.gracefulExitWindowSeconds)
    }

    func testGracefulStopSkipsForceStopOnceTheTargetExitsWithinTheWindow() async {
        let target = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventoryResults: [.success([target]), .success([])],
            executablePathsAtSignal: [target.pid: target.command]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM], "an exited target must not receive SIGKILL")
        XCTAssertTrue(harness.sleepDurations.isEmpty, "liveness polling must end as soon as the target is gone")
    }

    func testEscalationDoesNotKillReusedPIDWithNewStartTime() async {
        await assertReplacementIsNotForceStopped(pid: 10, startTime: "Sat Jul 26 11:20:20 2026")
    }

    func testEscalationDoesNotKillRelaunchedProcessWithNewPID() async {
        await assertReplacementIsNotForceStopped(pid: 11, startTime: "Sat Jul 26 11:20:17 2026")
    }

    private func assertReplacementIsNotForceStopped(pid: Int32, startTime: String) async {
        let path = "/Applications/Example.app/Contents/MacOS/Example"
        let target = process(pid: 10, command: path)
        let replacement = process(pid: pid, command: path, startTime: startTime)
        var paths = [target.pid: path]
        paths[replacement.pid] = path
        let harness = LifecycleRuntimeHarness(
            existingPaths: [], commandResults: [],
            inventoryResults: [.success([target]), .success([replacement])],
            executablePathsAtSignal: paths
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example", forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99, runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(harness.signals.map(\.0), [SIGTERM], "Replacement identity must not receive SIGKILL")
        XCTAssertEqual(harness.signals.map(\.1), [target.pid])
        XCTAssertEqual(harness.inventoryLoads, 2)
    }

    /// PID 1 is launchd and 0 or a negative value addresses a process group.
    /// Even an inventory row that claims such a pid must never be signalled.
    func testTerminationNeverSignalsLaunchdOrProcessGroupPIDs() async {
        let launchd = process(pid: 1, command: "/Applications/Example.app/Contents/MacOS/Example")
        let group = process(pid: 0, command: "/Applications/Example.app/Contents/MacOS/Example")
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [launchd, group]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    /// Signal 0 is harmless, so this is safe to run for real: `kill(0, 0)` would
    /// succeed (and prove the guard missing) if the pid were not refused first.
    func testLiveSignalSenderRefusesPIDsBelowTwoBeforeCallingKill() {
        XCTAssertFalse(ProcessLifecycleRuntime.liveSendSignal(0, to: 0))
        XCTAssertFalse(ProcessLifecycleRuntime.liveSendSignal(0, to: 1))
        XCTAssertFalse(ProcessLifecycleRuntime.liveSendSignal(0, to: -1))
    }

    /// There is no name-only termination entry point: the directory is a
    /// required parameter and a same-named process outside it is never a target.
    func testTerminationRequiresTheExecutableDirectoryAndNeverMatchesByNameAlone() async {
        let outsideBundle = process(pid: 10, command: "/tmp/Example")
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [],
            inventory: [outsideBundle]
        )

        let outcome = await ProcessLifecycleController.terminateProcess(
            named: "Example",
            forceIfStillRunning: true,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 99,
            runtime: harness.runtime
        )

        XCTAssertEqual(outcome, .noMatchingProcesses)
        XCTAssertTrue(harness.signals.isEmpty)
    }

    func testHelperTerminationTargetsAreRestrictedToConfiguredAppBundle() {
        let inventory = [
            process(pid: 10, command: "/Applications/Example.app/Contents/Library/LaunchServices/ExampleHelper"),
            process(pid: 11, command: "/tmp/ExampleHelper")
        ]

        XCTAssertEqual(
            ProcessLifecycleController.terminationTargets(
                named: "ExampleHelper",
                expectedExecutableDirectory: "/Applications/Example.app/Contents/",
                excludingPID: 99,
                currentUID: 501,
                in: inventory
            ).map(\.pid),
            [10]
        )
    }

    func testLaunchctlInspectionDistinguishesNotLoadedFromOperationalFailure() {
        let loaded = ShellCommandResult(
            command: "launchctl print",
            stdout: "service = example",
            stderr: "",
            exitCode: 0
        )
        let notLoaded = ShellCommandResult(
            command: "launchctl print",
            stdout: "",
            stderr: "Could not find service \"example\" in domain for user",
            exitCode: 113
        )
        let failed = ShellCommandResult(
            command: "launchctl print",
            stdout: "",
            stderr: "Operation not permitted",
            exitCode: 1
        )

        XCTAssertEqual(ProcessLifecycleController.launchJobInspection(from: loaded, label: "example"), .loaded)
        XCTAssertEqual(ProcessLifecycleController.launchJobInspection(from: notLoaded, label: "example"), .notLoaded)
        XCTAssertEqual(
            ProcessLifecycleController.launchJobInspection(from: failed, label: "example"),
            .failed("Operation not permitted")
        )
    }

    func testLoadedAgentWithMissingPlistIsUnloadedAndCountsAsSuccess() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: [
                result(exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/missing/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.count, 1)
        // The job was loaded, was booted out, and the unload was verified. An absent
        // plist is not a reason to call that stop a failure.
        XCTAssertEqual(batch.jobs[0].state, .changed)
        XCTAssertTrue(batch.jobs[0].succeeded)
        XCTAssertTrue(batch.succeeded)
        XCTAssertTrue(batch.jobs[0].detail.contains("still unloaded and verified"))
        XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("bootout") })
        XCTAssertEqual(harness.timeouts, [15, 30, 15])
        XCTAssertEqual(harness.sleepDurations, [300_000_000])
    }

    func testLaunchctlInspectionFailureDoesNotPretendAgentWasUnloaded() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(stderr: "Operation not permitted", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("Operation not permitted") == true)
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootout") })
    }

    func testAgentBootstrapExecutesAndVerifiesThroughInjectedRuntime() async throws {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0),
                result(exitCode: 0),
                result(exitCode: 0),
                result(exitCode: 0)
            ]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertEqual(
            harness.commands.filter { $0.executable == "/bin/launchctl" }.count,
            5
        )
        XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("bootstrap") })
        XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("kickstart") })
        let enableIndex = try XCTUnwrap(harness.commands.firstIndex { $0.isLaunchctl("enable") })
        let bootstrapIndex = try XCTUnwrap(harness.commands.firstIndex { $0.isLaunchctl("bootstrap") })
        XCTAssertLessThan(enableIndex, bootstrapIndex, "enable must precede bootstrap")
    }

    func testGlobalProtectDoesNotBootstrapUIJobWhenAppIsAlreadyOpenDirectly() async {
        let job = WatchedAppPreset.globalProtectInterfaceAgent
        var ui = process(pid: 42, command: GlobalProtectAccessibilityDisconnect.executable)
        ui.uid = 501
        let harness = LifecycleRuntimeHarness(
            existingPaths: [job.plistPath],
            launchAgentLabels: [job.plistPath: job.label],
            commandResults: [result(stderr: "Could not find service", exitCode: 113)],
            inventory: [ui]
        )
        let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.jobs.first?.state, .verified)
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootstrap") || $0.mentions("kickstart") })
    }

    func testGlobalProtectUnknownInventoryCannotStartADuplicateUI() async {
        let job = WatchedAppPreset.globalProtectInterfaceAgent
        let harness = LifecycleRuntimeHarness(
            existingPaths: [job.plistPath],
            launchAgentLabels: [job.plistPath: job.label],
            commandResults: [result(stderr: "Could not find service", exitCode: 113)],
            inventoryResults: [.failure(.commandFailed("Unavailable"))]
        )
        let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: .globalProtect, runtime: harness.runtime)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootstrap") || $0.mentions("kickstart") })
    }

    func testGlobalProtectDoesNotTrustAnImpostorOrAnotherUsersUI() async {
        let job = WatchedAppPreset.globalProtectInterfaceAgent
        for (uid, path) in [(uid_t(501), "/tmp/GlobalProtect"), (uid_t(502), GlobalProtectAccessibilityDisconnect.executable)] {
            var ui = process(pid: 42, command: path)
            ui.uid = uid
            let harness = LifecycleRuntimeHarness(
                existingPaths: [job.plistPath],
                launchAgentLabels: [job.plistPath: job.label],
                commandResults: [result(stderr: "Could not find service", exitCode: 113)] + Array(repeating: result(exitCode: 0), count: 4),
                inventory: [ui]
            )
            let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: .globalProtect, runtime: harness.runtime)
            XCTAssertTrue(result.succeeded)
            XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("bootstrap") })
        }
    }

    /// launchd refuses to bootstrap a job that carries a persistent disable
    /// override, which is exactly the state Keep Off leaves behind. Enabling
    /// after the bootstrap therefore never ran when it mattered.
    func testAgentBootstrapEnablesBeforeBootstrapSoADisabledJobCanLoad() async throws {
        let launchd = DisabledJobLaunchd()
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [],
            respond: { launchd.respond(to: $0) }
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed, batch.jobs.first?.detail ?? "")
        XCTAssertTrue(launchd.loaded)
        let enableIndex = try XCTUnwrap(harness.commands.firstIndex { $0.isLaunchctl("enable") })
        let bootstrapIndex = try XCTUnwrap(harness.commands.firstIndex { $0.isLaunchctl("bootstrap") })
        XCTAssertLessThan(enableIndex, bootstrapIndex)
    }

    func testAgentBootstrapRejectsMismatchedPlistLabelBeforeMutation() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "actual.agent"],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("actual.agent") == true)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    func testAgentBootstrapReportsEnableFailureAndDoesNotBootstrapOrKickstart() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(stderr: "Operation not permitted", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertEqual(batch.jobs.first?.detail, "Operation not permitted")
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootstrap") })
        XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") })
    }

    func testOpenAppBundleDoesNotForceASecondInstance() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Applications/Example.app"],
            commandResults: [result(exitCode: 0)]
        )

        let opened = await ProcessLifecycleController.openAppBundle(
            at: "/Applications/Example.app",
            runtime: harness.runtime
        )

        XCTAssertTrue(opened.succeeded)
        XCTAssertEqual(harness.commands, [ExternalCommand("/usr/bin/open", ["/Applications/Example.app"])])
    }

    /// On some GlobalProtect layouts the `pangpa` agent's Program is the main
    /// GlobalProtect binary. Quit Helpers must leave that agent loaded or it
    /// quits the app the user asked to keep.
    func testUnloadLeavesAgentThatRunsThePreservedMainProcessLoaded() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            preservingPIDs: [42],
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .alreadyLoaded)
        XCTAssertTrue(batch.succeeded)
        XCTAssertTrue(batch.jobs.first?.detail.contains("pid 42") == true)
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootout") })
    }

    func testUnloadStillBootsOutAgentsThatDoNotRunAPreservedProcess() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(stdout: launchctlPrintOutput(pid: 43), exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            preservingPIDs: [42],
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertTrue(harness.commands.contains { $0.isLaunchctl("bootout") })
    }

    func testLoadedAgentIsLeftRunningWithoutRestart() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            launchAgentLabels: ["/agents/example.plist": "example.agent"],
            commandResults: [result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .alreadyLoaded)
        XCTAssertEqual(batch.jobs.first?.detail, "Already loaded; no restart needed.")
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootstrap") })
        XCTAssertFalse(harness.commands.contains { $0.mentions("enable") })
        XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") })
    }

    func testBackgroundKeepOffDisablesBothJobsButOnlyBootsOutInterface() async {
        let harness = LifecycleRuntimeHarness(existingPaths: [], commandResults: [
            result(exitCode: 0), // pangps disable; no inspection or bootout
            result(exitCode: 0), // pangpa disable
            result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0),
            result(exitCode: 0),
            result(stderr: "Could not find service", exitCode: 113)
        ])
        let batch = await ProcessLifecycleController.disableUserLaunchAgents(
            for: .globalProtect, preservingVPNService: true, runtime: harness.runtime
        )
        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(harness.commands.filter { $0.isLaunchctl("disable") }.count, 2)
        XCTAssertEqual(harness.commands.filter { $0.isLaunchctl("bootout") }, [
            .launchctl("bootout", "gui/501/com.paloaltonetworks.gp.pangpa")
        ])
        XCTAssertTrue(batch.jobs.contains { $0.detail.contains("loaded VPN service was preserved") })
    }

    func testReadinessCommandsShareWallClockDeadline() async {
        for session in [false, true] {
            let sessionJob = WatchedAppPreset.globalProtectSessionAgent
            let daemonJob = WatchedAppPreset.globalProtectSystemDaemon
            let path = session ? sessionJob.plistPath : daemonJob.plistPath
            let clock = LifecycleTestClock()
            let harness = LifecycleRuntimeHarness(
                existingPaths: [path], launchAgentLabels: [path: sessionJob.label], commandResults: [],
                respond: { _ in ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0) }
            )
            var runtime = harness.runtime
            let run = runtime.runCommand
            runtime.runCommand = { command, timeout in
                // The initial loaded probe is immediate. Subsequent probes take
                // ten seconds unless the shared deadline allows less.
                if !harness.commands.isEmpty { clock.advance(min(10, timeout)) }
                return await run(command, timeout)
            }
            runtime.systemUptime = { clock.now }
            runtime.sleep = { duration in
                if duration == 500_000_000 { clock.advance(0.5) }
            }
            let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(clock.now, 15, accuracy: 0.001)
            XCTAssertEqual(harness.timeouts, [15, 15, 4.5])
            XCTAssertFalse(harness.commands.contains { $0.isAdministratorRequest })
        }
    }

    func testReadinessDoesNotRetryAfterInventoryConsumesDeadline() async {
        for session in [false, true] {
            let job = WatchedAppPreset.globalProtectSessionAgent
            let path = session ? job.plistPath : WatchedAppPreset.globalProtectSystemDaemon.plistPath
            let clock = LifecycleTestClock()
            var service = process(pid: 42, command: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
            service.uid = 0
            let harness = LifecycleRuntimeHarness(
                existingPaths: [path], launchAgentLabels: [path: job.label], commandResults: [],
                respond: { _ in ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0) },
                inventory: [service]
            )
            var runtime = harness.runtime
            let load = runtime.loadProcessInventory
            runtime.loadProcessInventory = {
                clock.advance(20)
                return await load()
            }
            runtime.systemUptime = { clock.now }
            let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(harness.commands.count, session ? 2 : 1)
        }
    }

    func testKeepOffDisablesAndBootsOutLoadedUserAgent() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [
                result(exitCode: 0),
                result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0),
                result(exitCode: 0),
                result(stderr: "Could not find service", exitCode: 113)
            ]
        )

        let batch = await ProcessLifecycleController.disableUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(batch.jobs.first?.state, .changed)
        XCTAssertEqual(
            harness.commands,
            [
                .launchctl("disable", "gui/501/example.agent"),
                .launchctl("print", "gui/501/example.agent"),
                .launchctl("bootout", "gui/501/example.agent"),
                .launchctl("print", "gui/501/example.agent")
            ]
        )
    }

    func testStopWaitsForLaunchdToFinishRemovingAnAcknowledgedJob() async {
        for keepOff in [false, true] {
            let loaded = result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)
            let responses = (keepOff ? [result(exitCode: 0)] : []) + [
                loaded, result(exitCode: 0), loaded, loaded,
                result(stderr: "Could not find service", exitCode: 113)
            ]
            let harness = LifecycleRuntimeHarness(
                existingPaths: ["/agents/example.plist"], commandResults: responses
            )
            let preset = presetWithAgent(plistPath: "/agents/example.plist")
            let batch = keepOff
                ? await ProcessLifecycleController.disableUserLaunchAgents(for: preset, runtime: harness.runtime)
                : await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: harness.runtime)
            XCTAssertTrue(batch.succeeded)
            XCTAssertEqual(batch.jobs.first?.state, .changed)
            XCTAssertEqual(harness.commands.filter { $0.isLaunchctl("bootout") }.count, 1)
            XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") || $0.mentions("kill") })
        }
    }

    func testStopWaitIsBoundedWhenAcknowledgedJobNeverUnloads() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"], commandResults: [],
            respond: { _ in ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0) }
        )
        let batch = await ProcessLifecycleController.disableUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"), runtime: harness.runtime
        )
        XCTAssertFalse(batch.succeeded)
        XCTAssertEqual(harness.commands.filter { $0.isLaunchctl("bootout") }.count, 1)
        XCTAssertLessThan(harness.commands.count, 70)
    }

    func testAllowToRunClearsDisableWithoutStartingAgent() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/agents/example.plist"],
            commandResults: [result(stdout: "disabled services = {\n\"example.agent\" => true\n}", exitCode: 0), result(exitCode: 0)]
        )

        let batch = await ProcessLifecycleController.enableUserLaunchAgents(
            for: presetWithAgent(plistPath: "/agents/example.plist"),
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(
            harness.commands,
            [.launchctl("print-disabled", "gui/501"), .launchctl("enable", "gui/501/example.agent")]
        )
        XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") })
        XCTAssertFalse(harness.commands.contains { $0.mentions("bootstrap") })
    }

    func testMissingOptionalAgentDoesNotBlockOpen() async {
        var preset = presetWithAgent(plistPath: "/agents/optional.plist")
        preset.userLaunchAgentJobs[0].isRequired = false
        let harness = LifecycleRuntimeHarness(
            existingPaths: [],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.bootstrapUserLaunchAgents(
            for: preset,
            runtime: harness.runtime
        )

        XCTAssertTrue(batch.succeeded)
        XCTAssertEqual(batch.jobs.first?.state, .alreadyUnloaded)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    func testRootPanGPSInTheSessionJobIsAcceptedWithoutBootstrappingSystemDaemon() async {
        let job = WatchedAppPreset.globalProtectSessionAgent
        for owner: uid_t in [0, 501] {
            var service = process(pid: 42, command: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
            service.uid = owner
            let harness = LifecycleRuntimeHarness(
                existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label],
                commandResults: [],
                respond: { _ in ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0) },
                inventory: [service]
            )
            let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.jobs.first?.label, job.label)
            XCTAssertTrue(result.jobs.first?.detail.contains("Login-session") == true)
            XCTAssertFalse(harness.commands.contains {
                $0.isAdministratorRequest || $0.mentions("system/") || $0.mentions("kickstart")
            })
        }
    }

    func testStoppedSessionServiceIsEnabledAndStartedWithoutKillingTheNewProcess() async {
        let job = WatchedAppPreset.globalProtectSessionAgent
        var service = process(pid: 42, command: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
        service.uid = 0
        let harness = LifecycleRuntimeHarness(
            existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0), result(exitCode: 0), result(exitCode: 0),
                result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0), result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)
            ], inventory: [service]
        )
        let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.jobs.first?.state, .changed)
        XCTAssertEqual(harness.commands.prefix(4), [
            .launchctl("print", "gui/501/\(job.label)"),
            .launchctl("enable", "gui/501/\(job.label)"),
            .launchctl("bootstrap", "gui/501", job.plistPath),
            .launchctl("kickstart", "gui/501/\(job.label)")
        ])
        XCTAssertFalse(harness.commands.contains {
            $0.isAdministratorRequest || ($0.isLaunchctl("kickstart") && $0.arguments.contains("-k"))
        })
    }

    func testSessionServiceReadinessRejectsWrongOwnerPIDAndExecutableWithoutSystemFallback() async {
        let job = WatchedAppPreset.globalProtectSessionAgent
        for invalid in ["owner", "pid", "path", "missing-path"] {
            var service = process(pid: invalid == "pid" ? 43 : 42,
                                  command: invalid == "path" ? "/tmp/PanGPS" : "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
            service.uid = invalid == "owner" ? 502 : 0
            let harness = LifecycleRuntimeHarness(
                existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label],
                commandResults: [],
                respond: { _ in ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0) },
                inventory: [service], executablePathsAtSignal: invalid == "missing-path" ? [:] : nil
            )
            let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
            XCTAssertFalse(result.succeeded, invalid)
            XCTAssertFalse(harness.commands.contains { $0.isAdministratorRequest || $0.mentions("system/") })
        }
    }

    /// A loaded daemon whose reported pid is not running the expected process is
    /// waited on, never restarted, and never re-bootstrapped with privileges.
    func testLoadedDaemonWithoutMatchingProcessIsWaitedOnNotRestarted() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [],
            respond: { _ in
                ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0)
            },
            inventory: [
                process(pid: 99, command: "/Applications/UnrelatedListener")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertTrue(batch.jobs.first?.detail.contains("never restarts") == true)
        XCTAssertFalse(harness.sleepDurations.isEmpty, "readiness must be re-polled before failing")
        XCTAssertFalse(harness.commands.contains { $0.mentions("/usr/sbin/lsof") })
        XCTAssertFalse(harness.commands.contains { $0.isAdministratorRequest })
        XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") })
    }

    /// Readiness is launchd's pid plus a fresh inventory. An unprivileged `lsof`
    /// cannot see a root daemon's descriptors, so a port probe could only ever
    /// fail and used to make every Open fall into the administrator script.
    func testDaemonReadinessIsVerifiedFromLaunchdPIDAndInventoryWithoutLsof() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)
            ],
            inventory: [
                process(pid: 42, command: "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS", uid: 0),
                process(pid: 99, command: "/Applications/UnrelatedListener")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .verified)
        XCTAssertEqual(
            harness.commands,
            [.launchctl("print", "system/com.paloaltonetworks.gp.pangpsd")]
        )
        XCTAssertFalse(harness.commands.contains { $0.mentions("lsof") })
        XCTAssertFalse(harness.commands.contains { $0.isAdministratorRequest })
    }

    func testDaemonReadinessRejectsSameNameProcessWhosePIDIsNotLaunchdJobPID() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [],
            respond: { _ in
                ShellCommandResult(command: "", stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0)
            },
            inventory: [
                process(pid: 99, command: "/tmp/PanGPS")
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: .globalProtect,
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertFalse(harness.commands.contains { $0.mentions("/usr/sbin/lsof") })
        XCTAssertFalse(harness.commands.contains { $0.isAdministratorRequest })
    }

    /// The privileged script bootstraps only a daemon launchd does not have
    /// loaded. `kickstart -k` on the live VPN daemon would drop the session, so
    /// it must never appear in the script, loaded or not.
    func testEnsureSystemLaunchDaemonsNeverKickstartsTheSystemDaemon() async throws {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(exitCode: 0),
                result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)
            ],
            inventory: [
                process(pid: 42, command: "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS", uid: 0)
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: .globalProtect,
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.first?.state, .changed)
        let adminCommand = try XCTUnwrap(harness.commands.first { $0.isAdministratorRequest })
        let appleScript = try XCTUnwrap(adminCommand.administratorAppleScript, "\(adminCommand.argumentVector)")
        XCTAssertFalse(appleScript.contains("kickstart"))
        XCTAssertTrue(appleScript.contains("launchctl bootstrap system"))
        XCTAssertFalse(harness.commands.contains { $0.mentions("kickstart") })

        let script = ProcessLifecycleController.adminBootstrapScript(
            for: WatchedAppPreset.globalProtectSystemDaemon
        )
        XCTAssertFalse(script.contains("kickstart"))
        XCTAssertTrue(script.contains("exit 0"), "a loaded daemon must be left alone")
        XCTAssertTrue(script.contains("/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist'"))
    }

    func testCustomDaemonConfigurationNeverReachesPrivilegedCommandPath() async {
        let harness = LifecycleRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/example.plist"],
            commandResults: []
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: WatchedAppPreset(
                displayName: "Example",
                mainProcessName: "Example",
                helperProcessNames: [],
                protectedProcessNames: [],
                appPath: "/Applications/Example.app",
                systemLaunchDaemonJobs: [
                    SystemLaunchDaemonJob(
                        label: "example.daemon",
                        plistPath: "/Library/LaunchDaemons/example.plist",
                        processName: "ExampleDaemon"
                    )
                ]
            ),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch, .notNeeded)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    func testLaunchJobPIDRequiresExplicitPositivePIDField() {
        XCTAssertEqual(
            ProcessLifecycleController.launchJobPID(
                from: result(stdout: launchctlPrintOutput(pid: 42), exitCode: 0)
            ),
            42
        )
        XCTAssertNil(
            ProcessLifecycleController.launchJobPID(
                from: result(stdout: "state = running", exitCode: 0)
            )
        )
    }

    func testLaunchJobPIDIgnoresNestedFieldsAndRejectsIncompleteOutput() {
        let nested = "gui/501/example.agent = {\n\tchild = {\n\t\tpid = 99\n\t}\n}"
        XCTAssertNil(ProcessLifecycleController.launchJobPID(from: result(stdout: nested, exitCode: 0)))
        let both = "gui/501/example.agent = {\n\tchild = {\n\t\tpid = 99\n\t}\n\tpid = 42\n}"
        XCTAssertEqual(ProcessLifecycleController.launchJobPID(from: result(stdout: both, exitCode: 0)), 42)
        for output in ["pid = 42", "gui/501/example.agent = {\n\tpid = 42", launchctlPrintOutput(pid: 0)] {
            XCTAssertNil(ProcessLifecycleController.launchJobPID(from: result(stdout: output, exitCode: 0)))
        }
        XCTAssertNil(ProcessLifecycleController.launchJobPID(from: result(stdout: launchctlPrintOutput(pid: 42), exitCode: 1)))
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

    private func presetWithDaemon() -> WatchedAppPreset {
        .globalProtect
    }

    private func result(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32
    ) -> ShellCommandResult {
        ShellCommandResult(
            command: "fake",
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode
        )
    }

    private func process(
        pid: Int32, command: String, uid: uid_t? = 501,
        startTime: String = "Sat Jul 26 11:20:17 2026"
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: uid,
            cpu: 0,
            memoryMB: 0,
            command: command,
            executablePath: command.hasPrefix("/") ? command : nil,
            elapsedTime: "00:01",
            startTime: startTime,
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

/// A fake launchd that mirrors the real one's refusal to bootstrap a job that
/// still carries a persistent disable override.
private final class DisabledJobLaunchd: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private(set) var loaded = false

    func respond(to command: ExternalCommand) -> ShellCommandResult {
        lock.withLock {
            if command.isLaunchctl("print") {
                return loaded
                    ? ShellCommandResult(command: command, stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0)
                    : ShellCommandResult(command: command, stdout: "", stderr: launchctlNotFoundMessage(command: command), exitCode: 113)
            }
            if command.isLaunchctl("enable") {
                enabled = true
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
            }
            if command.isLaunchctl("bootstrap") {
                guard enabled else {
                    return ShellCommandResult(
                        command: command,
                        stdout: "",
                        stderr: "Bootstrap failed: 5: Input/output error",
                        exitCode: 5
                    )
                }
                loaded = true
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
            }
            if command.isLaunchctl("kickstart") {
                return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: loaded ? 0 : 1)
            }
            return ShellCommandResult(command: command, stdout: "", stderr: "unexpected command", exitCode: 1)
        }
    }
}

final class LifecycleRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private let launchAgentLabels: [String: String]
    private var commandResults: [ShellCommandResult]
    private let respond: (@Sendable (ExternalCommand) -> ShellCommandResult)?
    private var inventoryResults: [Result<[AppProcess], ProcessInventoryError>]
    private let executablePathsAtSignal: [Int32: String]
    private var signalResults: [Bool]
    private var recordedInventoryLoads = 0
    private var recordedCommands: [ExternalCommand] = []
    private var recordedTimeouts: [TimeInterval] = []
    private var recordedSleepDurations: [UInt64] = []
    private var recordedSignals: [(Int32, Int32)] = []

    init(
        existingPaths: Set<String>,
        launchAgentLabels: [String: String] = [:],
        commandResults: [ShellCommandResult],
        respond: (@Sendable (ExternalCommand) -> ShellCommandResult)? = nil,
        inventory: [AppProcess] = [],
        inventoryResults: [Result<[AppProcess], ProcessInventoryError>]? = nil,
        executablePathsAtSignal: [Int32: String]? = nil,
        signalResults: [Bool] = [true]
    ) {
        self.existingPaths = existingPaths
        self.launchAgentLabels = launchAgentLabels
        self.commandResults = commandResults
        self.respond = respond
        self.inventoryResults = inventoryResults ?? [.success(inventory)]
        self.executablePathsAtSignal = executablePathsAtSignal
            ?? Dictionary(uniqueKeysWithValues: inventory.compactMap { process in
                process.executablePath.map { (process.pid, $0) }
            })
        self.signalResults = signalResults
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in
                existingPaths.contains(path)
            },
            launchAgentLabel: { [self] path in
                launchAgentLabels[path] ?? (path.contains("LaunchDaemons/") ? "com.paloaltonetworks.gp.pangpsd" : nil)
            },
            runCommand: { [self] command, timeout in
                lock.withLock {
                    recordedCommands.append(command)
                    recordedTimeouts.append(timeout)
                    if let respond {
                        return respond(command)
                    }
                    guard !commandResults.isEmpty else {
                        return ShellCommandResult(
                            command: command,
                            stdout: "",
                            stderr: "No fake command result configured.",
                            exitCode: -1
                        )
                    }
                    var response = commandResults.removeFirst()
                    if response.stderr == "Could not find service" {
                        response.stderr = launchctlNotFoundMessage(command: command)
                    }
                    response.command = command.description
                    return response
                }
            },
            loadProcessInventory: { [self] in
                lock.withLock {
                    recordedInventoryLoads += 1
                    guard inventoryResults.count > 1 else {
                        return inventoryResults.first
                            ?? .failure(.commandFailed("No fake inventory result configured."))
                    }
                    return inventoryResults.removeFirst()
                }
            },
            executablePathForPID: { [self] pid in
                executablePathsAtSignal[pid]
            },
            sendSignal: { [self] signal, pid in
                lock.withLock {
                    recordedSignals.append((signal, pid))
                    guard signalResults.count > 1 else {
                        return signalResults.first ?? false
                    }
                    return signalResults.removeFirst()
                }
            },
            isProcessAlive: { [self] pid in
                // Liveness follows the inventory result the next load will return,
                // so a target that "exits" between reads stops being alive too.
                lock.withLock {
                    guard case .success(let processes)? = inventoryResults.first else { return false }
                    return processes.contains { $0.pid == pid }
                }
            },
            sleep: { [self] duration in
                lock.withLock {
                    recordedSleepDurations.append(duration)
                }
            },
            systemUptime: { 0 },
            isAppBundle: { [self] path in
                existingPaths.contains(path)
            }
        )
    }

    var inventoryLoads: Int {
        lock.withLock { recordedInventoryLoads }
    }

    var commands: [ExternalCommand] {
        lock.withLock { recordedCommands }
    }

    var timeouts: [TimeInterval] {
        lock.withLock { recordedTimeouts }
    }

    var sleepDurations: [UInt64] {
        lock.withLock { recordedSleepDurations }
    }

    var signals: [(Int32, Int32)] {
        lock.withLock { recordedSignals }
    }
}

@MainActor
final class Batch01LifecycleLabelTests: XCTestCase {
    func testUnvalidatedLabelsCannotReachAnyUserAgentLifecycleCommand() async {
        for label in ["/", "/x", "//", "a/b", "/Users/test/Library/LaunchAgents/a.plist", "a\0b", "a\u{202E}b"] {
            let path = "/nonexistent-batch01/agent.plist"
            let harness = LifecycleRuntimeHarness(
                existingPaths: [path], launchAgentLabels: [path: label],
                commandResults: [], respond: { command in
                    .init(command: command, stdout: launchctlPrintOutput(pid: 42), stderr: "", exitCode: 0)
                }
            )
            let preset = WatchedAppPreset(
                displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
                protectedProcessNames: [], appPath: "/nonexistent-batch01/Example.app",
                userLaunchAgentJobs: [.init(label: label, plistPath: path)]
            )
            let stopped = await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: harness.runtime)
            let disabled = await ProcessLifecycleController.disableUserLaunchAgents(for: preset, runtime: harness.runtime)
            let enabled = await ProcessLifecycleController.enableUserLaunchAgents(for: preset, runtime: harness.runtime)
            let started = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: harness.runtime)
            for result in [stopped, disabled, enabled, started] {
                XCTAssertEqual(result.jobs.map(\.state), [.failed], label)
                XCTAssertTrue(result.failureSummary?.contains("label") == true, label)
            }
            XCTAssertTrue(harness.commands.allSatisfy { $0.isLaunchctl("print-disabled") }, label)
            XCTAssertTrue(harness.signals.isEmpty, label)
        }
    }
}
