import Darwin
import Foundation
import XCTest
@testable import TaskScope

func batch04Result(_ output: String = "", error: String = "", code: Int32 = 0, signal: Int32? = nil) -> ShellCommandResult {
    ShellCommandResult(command: "fake", stdout: output, stderr: error, exitCode: code, terminatedBySignal: signal)
}

func batch04Process(pid: Int32 = 424242, uid: uid_t = 501, path: String = "/Applications/Batch04NeverInstalled.app/Contents/MacOS/Batch04NeverRunning") -> AppProcess {
    AppProcess(pid: pid, parentPID: 1, uid: uid, cpu: 0, memoryMB: 0, command: path,
               executablePath: path, elapsedTime: "00:10", startTime: "stable fake identity",
               netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
}

final class Batch04FixTests: XCTestCase {
    let preset = WatchedAppPreset(displayName: "Batch04", mainProcessName: "Batch04NeverRunning", helperProcessNames: ["Batch04Helper"],
                                  protectedProcessNames: [], appPath: "/Applications/Batch04NeverInstalled.app",
                                  userLaunchAgentJobs: [.init(label: "batch04.agent", plistPath: "/fake/batch04.plist")])
    let absent = batch04Result(error: "Could not find service \"batch04.agent\" in domain", code: 113)
    let daemon = WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0]

    func harness(_ answers: [ShellCommandResult], exists: Bool = true) -> LifecycleRuntimeHarness {
        LifecycleRuntimeHarness(existingPaths: exists ? [preset.appPath, "/fake/batch04.plist"] : [],
                                launchAgentLabels: ["/fake/batch04.plist": "batch04.agent"], commandResults: answers)
    }

    func testMissingRequiredPlistsFailModelsAndBothBootstrapPathsWithoutCommands() async {
        let missing = LifecycleJobResult(label: "batch04.agent", state: .missing, detail: "Missing plist")
        let batch = LifecycleBatchResult(jobs: [missing])
        XCTAssertFalse(missing.succeeded)
        XCTAssertFalse(batch.succeeded)
        XCTAssertTrue(batch.failureSummary?.contains("batch04.agent") == true)
        let fake = harness([], exists: false)
        let user = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: fake.runtime)
        XCTAssertEqual(user.jobs.map(\.state), [.missing])
        let system = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
        XCTAssertEqual(system.jobs.map(\.label), [daemon.label])
        XCTAssertEqual(system.jobs.map(\.state), [.missing])
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testDisableAndEnableRefusalsAreFailures() async {
        let refusal = batch04Result(error: "Operation not permitted", code: 1)
        let disableFake = harness([refusal])
        let disabled = await SystemProcessLifecycleService(runtime: disableFake.runtime).disableUserLaunchAgents(for: preset, preservingVPNService: false)
        XCTAssertEqual(disabled.jobs.map(\.state), [.failed])
        XCTAssertEqual(disabled.jobs.first?.detail, "Operation not permitted")
        XCTAssertEqual(disableFake.commands, ["/bin/launchctl disable 'gui/501/batch04.agent'"])
        let enableFake = harness([batch04Result("disabled services = {\n}"), refusal])
        let enabled = await SystemProcessLifecycleService(runtime: enableFake.runtime).enableUserLaunchAgents(for: preset)
        XCTAssertFalse(enabled.succeeded)
        XCTAssertEqual(enabled.jobs.first?.detail, "Operation not permitted")
    }

    func testDisableDistinguishesAbsentAndUnreadableJobs() async {
        for absentJob in [true, false] {
            let fake = harness([batch04Result(), absentJob ? absent : batch04Result(error: "Denied", code: 1)])
            let batch = await ProcessLifecycleController.disableUserLaunchAgents(for: preset, runtime: fake.runtime)
            XCTAssertEqual(batch.jobs.first?.state, absentJob ? .changed : .failed)
            XCTAssertEqual(batch.jobs.first?.detail, absentJob ? "Disabled persistently; already unloaded." : "Disabled, but could not inspect the live job: Denied")
            XCTAssertEqual(fake.commands.count, 2)
        }
    }

    func testBootstrapFailuresAndFinalVerification() async {
        let fake = harness([absent, batch04Result(), batch04Result(error: "Bootstrap refused", code: 5), absent])
        let failed = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: fake.runtime)
        XCTAssertEqual(failed.jobs.first?.detail, "Bootstrap refused")
        XCTAssertFalse(failed.succeeded)
        XCTAssertFalse(fake.commands.contains { $0.contains("kickstart") })
        let unverified = harness([absent, batch04Result(), batch04Result(), batch04Result(), absent])
        let final = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: unverified.runtime)
        XCTAssertEqual(final.jobs.first?.state, .failed)
        XCTAssertEqual(final.jobs.first?.detail, "Job could not be verified.")
    }

    func testBootstrapRequiresReadableLabelAndSuccessfulInitialInspection() async {
        let unlabeled = harness([])
        var runtime = unlabeled.runtime
        runtime.launchAgentLabel = { _ in nil }
        let unreadable = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: runtime)
        XCTAssertEqual(unreadable.jobs.first?.state, .failed)
        XCTAssertTrue(unreadable.failureSummary?.contains("valid Label") == true)
        XCTAssertTrue(unlabeled.commands.isEmpty)
        let fake = harness([batch04Result(error: "Operation not permitted", code: 1)])
        let denied = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: fake.runtime)
        XCTAssertFalse(denied.succeeded)
        XCTAssertEqual(fake.commands, ["/bin/launchctl print 'gui/501/batch04.agent'"])
    }

    func testLoadedStateWinsOverBootstrapAndKickstartExitStatus() async {
        for bootstrapCode: Int32 in [0, 5] {
            var answers = [absent, batch04Result(), batch04Result(code: bootstrapCode)]
            if bootstrapCode != 0 { answers.append(batch04Result(launchctlPrintOutput(pid: 42))) }
            answers += [batch04Result(error: "on demand job", code: 1), batch04Result(launchctlPrintOutput(pid: 42))]
            let fake = harness(answers)
            let result = await ProcessLifecycleController.bootstrapUserLaunchAgents(for: preset, runtime: fake.runtime)
            XCTAssertTrue(result.succeeded)
            XCTAssertTrue(result.jobs.first?.detail.contains("start request failed: on demand job") == true)
        }
    }

    func testUnloadingAcknowledgedJobThatStaysLoadedFailsAfterBoundedWait() async {
        let fake = harness([batch04Result(launchctlPrintOutput(pid: 42)), batch04Result()]
            + Array(repeating: batch04Result(launchctlPrintOutput(pid: 42)), count: 61))
        let batch = await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: fake.runtime)
        XCTAssertEqual(batch.jobs.first?.state, .failed)
        XCTAssertEqual(batch.jobs.first?.detail, "Job remained loaded.")
        XCTAssertEqual(fake.sleepDurations.filter { $0 == 500_000_000 }.count, 60)
    }

    func testAmbiguousBootoutWaitsForObservedDisappearance() async {
        for result in [batch04Result(code: ShellCommandRunner.timedOutExitCode), batch04Result(code: 9, signal: 9), batch04Result(code: 1)] {
            let loaded = batch04Result(launchctlPrintOutput(pid: 42))
            let fake = harness([loaded, result, loaded, loaded, absent])
            let batch = await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, runtime: fake.runtime)
            XCTAssertEqual(batch.jobs.first?.state, .changed)
            XCTAssertEqual(fake.sleepDurations.filter { $0 == 500_000_000 }.count, 2)
        }
    }

    func testPrintAbsenceRequiresLabelStatusAndNoSignal() {
        XCTAssertEqual(ProcessLifecycleController.launchJobInspection(from: absent, label: "batch04.agent"), .notLoaded)
        let failures = [batch04Result(error: absent.stderr, code: ShellCommandRunner.timedOutExitCode),
                        batch04Result(error: absent.stderr, code: 113, signal: SIGKILL),
                        batch04Result(error: absent.stderr, code: 1), batch04Result(code: 113),
                        batch04Result(error: "No such process", code: 113), batch04Result(error: "service not found", code: 113),
                        batch04Result(error: absent.stderr.replacingOccurrences(of: "batch04.agent", with: "another.agent"), code: 113)]
        for failure in failures {
            guard case .failed = ProcessLifecycleController.launchJobInspection(from: failure, label: "batch04.agent") else { return XCTFail("Ambiguous result proved absence: \(failure)") }
        }
    }

    /// Shaped like real macOS 27 `launchctl print` output: XPC data values print
    /// as nothing, so a closing brace ends a value line, and a running app job
    /// also lists `pid-local endpoints`.
    static let realShapeRunningListing = """
    gui/501/batch04.agent = {
    \tactive count = 1
    \tpath = /fake/batch04.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /Applications/Batch04NeverInstalled.app/Contents/MacOS/Batch04NeverRunning
    \tinherited environment = {
    \t\tSSH_AUTH_SOCK => /private/tmp/com.apple.launchd.batch04/Listeners
    \t}

    \tdomain = gui/501 [100020]
    \truns = 17
    \tpid = 4242
    \timmediate reason = xpc event

    \tevent triggers = {
    \t\tnew-handles => {
    \t\t\tkeepalive = 0
    \t\t\tservice = batch04.agent
    \t\t\tdescriptor = {
    \t\t\t\t"aux-data" => {
    \t\t\t\t\t"ServerAuxiliaryData" => \t\t\t\t\t"AgentAuxiliaryData" => \t\t\t\t}
    \t\t\t\t"handles-array" => [
    \t\t\t\t\t0 = {
    \t\t\t\t\t\t"file-descriptor" => \t\t\t\t\t\t"type" => 3
    \t\t\t\t\t\t"key-material" => \t\t\t\t\t}
    \t\t\t\t]
    \t\t\t}
    \t\t}
    \t}

    \tpid-local endpoints = {
    \t\t"batch04.agent.xpc" = {
    \t\t\tport = 0x1a2b3
    \t\t\tactive = 1
    \t\t}
    \t}

    \tjob state = running
    \tproperties = app | system service
    }
    """

    /// A loaded job without a process, shaped like real output.
    static let realShapeIdleListing = """
    gui/501/batch04.agent = {
    \tactive count = 0
    \tpath = /fake/batch04.plist
    \ttype = LaunchAgent
    \tstate = not running

    \tprogram = /Applications/Batch04NeverInstalled.app/Contents/MacOS/Batch04NeverRunning
    \tendpoints = {
    \t\t"batch04.agent.xpc" = {
    \t\t\tport = 0x1a2b3
    \t\t\tactive = 0
    \t\t}
    \t}
    \truns = 0
    \tproperties = runatload
    }
    """

    func testRealShapeListingsYieldTheJobPIDAndIdleState() async {
        XCTAssertEqual(GlobalProtectCompatibilityChecker.topLevelPID(Self.realShapeRunningListing), 4242)
        XCTAssertFalse(LaunchctlJobListing.hasNoRunningPID(Self.realShapeRunningListing))
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID(Self.realShapeIdleListing))
        XCTAssertTrue(LaunchctlJobListing.hasNoRunningPID(Self.realShapeIdleListing))
        // Truncated output, a nested pid, or a second pid never yields a pid.
        let truncated = String(Self.realShapeRunningListing.dropLast(2))
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID(truncated))
        XCTAssertFalse(LaunchctlJobListing.hasNoRunningPID(String(Self.realShapeIdleListing.dropLast(2))))
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID(
            Self.realShapeRunningListing.replacingOccurrences(of: "\truns = 17\n", with: "\tpid = 4343\n")))
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID(
            Self.realShapeRunningListing.replacingOccurrences(of: "\tpid = 4242\n", with: "\t\tpid = 4242\n")))

        // Quit Helpers keeps an agent that runs the main process.
        let fake = harness([batch04Result(Self.realShapeRunningListing)])
        let result = await ProcessLifecycleController.unloadUserLaunchAgents(for: preset, preservingPIDs: [4242], runtime: fake.runtime)
        XCTAssertEqual(result.jobs.map(\.state), [.alreadyLoaded])
        XCTAssertFalse(fake.commands.contains { $0.contains("bootout") })
    }

    func testOpaqueXPCBracesDoNotHideJobPIDAndUnverifiablePIDIsPreserved() async {
        let listing = "gui/501/batch04.agent = {\n\txpc = {\n\t\tdata = <deadbeef>}\n\tpid = 42\n\tstate = running\n}"
        XCTAssertEqual(GlobalProtectCompatibilityChecker.topLevelPID(listing), 42)
        for output in [listing, listing.replacingOccurrences(of: "\tpid = 42\n", with: ""), listing.replacingOccurrences(of: "\tpid = 42", with: "\tpid = invalid")] {
            let fake = harness([batch04Result(output)])
            let result = await SystemProcessLifecycleService(runtime: fake.runtime).unloadUserLaunchAgents(for: preset, preservingPIDs: [42])
            XCTAssertFalse(result.didChangeState)
            XCTAssertEqual(fake.commands.count, 1)
            XCTAssertFalse(fake.commands.contains { $0.contains("bootout") })
        }
    }

    func testUnloadUsesReverseJobOrder() async {
        var two = preset
        two.userLaunchAgentJobs.append(.init(label: "batch04.second", plistPath: "/fake/second.plist"))
        let secondAbsent = batch04Result(error: "Could not find service \"batch04.second\" in domain", code: 113)
        let loaded = batch04Result(launchctlPrintOutput(pid: 42))
        let fake = harness([loaded, batch04Result(), secondAbsent, loaded, batch04Result(), absent])
        let result = await ProcessLifecycleController.unloadUserLaunchAgents(for: two, runtime: fake.runtime)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(fake.commands.filter { $0.contains("bootout") }, ["/bin/launchctl bootout 'gui/501/batch04.second'", "/bin/launchctl bootout 'gui/501/batch04.agent'"])
    }

    func testOpenBundleMissingAndCommandFailuresRetainDetails() async {
        let missing = harness([], exists: false)
        let missingResult = await ProcessLifecycleController.openAppBundle(at: preset.appPath, runtime: missing.runtime)
        XCTAssertFalse(missingResult.succeeded)
        XCTAssertTrue(missing.commands.isEmpty)
        for (answer, expected) in [(batch04Result(error: "Launch Services refused", code: 1), "Launch Services refused"),
                                   (batch04Result(code: ShellCommandRunner.timedOutExitCode), "The launch request timed out.")] {
            let fake = harness([answer])
            let result = await SystemProcessLifecycleService(runtime: fake.runtime).openAppBundle(at: preset.appPath)
            XCTAssertEqual(result, .failed(expected))
        }
    }

    func testProductionServiceChecksTheAppBundleAgainBeforeOpening() async {
        let fake = harness([])
        var runtime = fake.runtime
        runtime.isAppBundle = { _ in false }
        let service = SystemProcessLifecycleService(runtime: runtime)
        XCTAssertFalse(service.appBundleExists(at: preset.appPath))
        let result = await service.openAppBundle(at: preset.appPath)
        XCTAssertEqual(result, .failed("The app path no longer leads to an app bundle."))
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testProductionServiceScopesAndEscalatesMainAndHelperSignals() async {
        let main = batch04Process()
        let helper = batch04Process(pid: 424243, path: preset.appPath + "/Contents/Resources/Batch04Helper")
        let outside = batch04Process(pid: 424244, path: "/tmp/Batch04Helper")
        let misplaced = batch04Process(pid: 424245, path: preset.appPath + "/Contents/Resources/Batch04NeverRunning")
        let fake = LifecycleRuntimeHarness(existingPaths: [preset.appPath], commandResults: [], inventory: [main, helper, outside, misplaced])
        let service = SystemProcessLifecycleService(runtime: fake.runtime)
        XCTAssertTrue(service.appBundleExists(at: preset.appPath))
        _ = await service.terminateMainProcess(for: preset)
        _ = await service.terminateHelperProcess(named: "Batch04Helper", for: preset)
        XCTAssertEqual(fake.signals.map { $0.0 }, [SIGTERM, SIGKILL, SIGTERM, SIGKILL])
        XCTAssertEqual(fake.signals.map { $0.1 }, [main.pid, main.pid, helper.pid, helper.pid])
        let outsideFake = LifecycleRuntimeHarness(existingPaths: [], commandResults: [], inventory: [misplaced])
        let running = await SystemProcessLifecycleService(runtime: outsideFake.runtime).waitForMainProcess(for: preset, timeoutSeconds: 0)
        XCTAssertFalse(running)
        XCTAssertGreaterThan(outsideFake.inventoryLoads, 0)
    }

    /// Background Keep Off must neither unload the session VPN service nor ask
    /// for administrator rights; only the production service forwards those flags.
    func testProductionServiceForwardsVPNPreservationAndPromptPermission() async {
        let session = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        for preserve in [true, false] {
            let fake = LifecycleRuntimeHarness(existingPaths: [], commandResults: [], respond: { command in
                if command.contains(" print ") {
                    return batch04Result(error: launchctlNotFoundMessage(command: command), code: 113)
                }
                return batch04Result()
            })
            let result = await SystemProcessLifecycleService(runtime: fake.runtime).disableUserLaunchAgents(for: .globalProtect, preservingVPNService: preserve)
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(fake.commands.contains("/bin/launchctl print 'gui/501/\(session.label)'"), !preserve)
            XCTAssertTrue(fake.commands.contains("/bin/launchctl disable 'gui/501/\(session.label)'"))
        }
        for allowPrompt in [false, true] {
            let fake = LifecycleRuntimeHarness(existingPaths: [daemon.plistPath], commandResults: [], respond: { command in
                if command.contains("print-disabled") { return batch04Result("disabled services = {\n}") }
                if command.contains("osascript") { return batch04Result(error: "0:1: execution error: User canceled. (-128)", code: 1) }
                return batch04Result(launchctlPrintOutput(pid: 42, target: "system/com.paloaltonetworks.gp.pangpsd"))
            })
            let result = await SystemProcessLifecycleService(runtime: fake.runtime).disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: allowPrompt)
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(fake.commands.filter { $0.contains("osascript") }.count, allowPrompt ? 1 : 0)
        }
        let enable = LifecycleRuntimeHarness(existingPaths: [], commandResults: [], respond: { command in
            command.contains("print-disabled")
                ? batch04Result("disabled services = {\n\t\"com.paloaltonetworks.gp.pangpsd\" => disabled\n}")
                : batch04Result(error: "0:1: execution error: User canceled. (-128)", code: 1)
        })
        let enabled = await SystemProcessLifecycleService(runtime: enable.runtime).enableSystemLaunchDaemons(for: .globalProtect)
        XCTAssertFalse(enabled.succeeded)
        XCTAssertEqual(enable.commands.filter { $0.contains("osascript") }.count, 1)
    }

    func testSystemReadinessRejectsWrongNameOwnerAndKernelPathAndRequiresPlistLabel() async {
        for invalid in ["name", "owner", "path", "missing"] {
            let path = invalid == "name" ? "/Applications/GlobalProtect.app/Contents/Resources/UnrelatedTool" : "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"
            let process = batch04Process(pid: 42, uid: invalid == "owner" ? 501 : 0, path: path)
            let fake = LifecycleRuntimeHarness(existingPaths: [daemon.plistPath], launchAgentLabels: [daemon.plistPath: daemon.label], commandResults: [],
                respond: { _ in batch04Result(launchctlPrintOutput(pid: 42)) }, inventory: [process],
                executablePathsAtSignal: invalid == "path" ? [42: "/tmp/PanGPS"] : (invalid == "missing" ? [:] : nil))
            let readiness = await ProcessLifecycleController.systemLaunchDaemonReadiness(daemon, runtime: fake.runtime)
            XCTAssertEqual(readiness, .loadedButNotReady)
            let opened = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
            XCTAssertFalse(opened.succeeded)
            XCTAssertFalse(fake.commands.contains { $0.contains("osascript") })
        }
        // A daemon that is not loaded is never bootstrapped from a plist whose
        // Label is not the job's.
        let unloaded = LifecycleRuntimeHarness(existingPaths: [daemon.plistPath], launchAgentLabels: [daemon.plistPath: "wrong.label"], commandResults: [],
            respond: { _ in batch04Result(error: "Could not find service \"\(WatchedAppPreset.globalProtectSystemLaunchDaemonJobs[0].label)\" in domain for system", code: 113) })
        let wrong = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: unloaded.runtime)
        XCTAssertFalse(wrong.succeeded)
        XCTAssertTrue(wrong.failureSummary?.contains("mismatched Label") == true)
        XCTAssertFalse(unloaded.commands.contains { $0.contains("osascript") })
        // A daemon that is already running needs no privileged command, so the
        // plist Label does not block Open.
        let root = batch04Process(pid: 42, uid: 0, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
        let running = LifecycleRuntimeHarness(existingPaths: [daemon.plistPath], launchAgentLabels: [daemon.plistPath: "wrong.label"], commandResults: [],
            respond: { _ in batch04Result(launchctlPrintOutput(pid: 42, target: "system/com.paloaltonetworks.gp.pangpsd")) }, inventory: [root])
        let ready = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: running.runtime)
        XCTAssertEqual(ready.jobs.map(\.state), [.verified])
        XCTAssertFalse(running.commands.contains { $0.contains("osascript") })
    }

    func testInjectedRuntimeNeverReachesTheLiveGlobalProtectDisconnect() async {
        let fake = harness([])
        let isolated = await SystemProcessLifecycleService(runtime: fake.runtime).disconnectGlobalProtectIfNeeded()
        XCTAssertEqual(isolated, .failed("Automatic GlobalProtect disconnect is unavailable. Its services were left running."))
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(fake.inventoryLoads, 0)
        let forwarded = await SystemProcessLifecycleService(runtime: fake.runtime, disconnect: { .disconnected }).disconnectGlobalProtectIfNeeded()
        XCTAssertEqual(forwarded, .disconnected)
    }

    func testTaskCancellationIsNotReportedAsAnApprovalCancel() async {
        let cancelled = batch04Result(error: "Command cancelled.", code: ShellCommandRunner.cancelledExitCode)
        XCTAssertEqual(ProcessLifecycleController.AdministratorStopOutcome(cancelled), .failed("exited with status \(ShellCommandRunner.cancelledExitCode)"))
        let job = daemon
        let fake = LifecycleRuntimeHarness(existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label], commandResults: [], respond: { command in
            command.contains("osascript") ? cancelled : batch04Result(error: "Could not find service \"\(job.label)\" in domain for system", code: 113)
        })
        let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
        XCTAssertEqual(result.jobs.first?.detail, "Command cancelled.")
    }

    func testApprovedDaemonBootstrapMustActuallyBecomeReadyAndCancellationIsActionable() async {
        for errorCode in [0, -128, -60006, -60005, -60007] {
            let job = daemon
            let fake = LifecycleRuntimeHarness(existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label], commandResults: [], respond: { command in
                if command.contains("osascript") { return batch04Result(error: errorCode == 0 ? "" : "0:1: execution error: User refused. (\(errorCode))", code: errorCode == 0 ? 0 : 1) }
                return batch04Result(error: "Could not find service \"\(job.label)\" in domain", code: 113)
            })
            let result = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
            XCTAssertFalse(result.succeeded)
            let detail = result.jobs.first?.detail ?? ""
            if errorCode == 0 { XCTAssertTrue(detail.contains("Bootstrap was approved")) }
            else if [-128, -60006].contains(errorCode) { XCTAssertEqual(detail, "Administrator approval was cancelled; nothing was started.") }
            else { XCTAssertTrue(detail.contains("approval was denied")) }
            XCTAssertEqual(fake.commands.filter { $0.contains("osascript") }.count, 1)
            XCTAssertTrue(fake.commands.first { $0.contains("osascript") }?.contains("TaskScope needs administrator approval to start") == true)
        }
    }

    func testIdleSessionJobGetsOneNonRestartingStartRequest() async {
        let job = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        let process = batch04Process(pid: 42, uid: 0, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
        let idle = batch04Result("job = {\n\tstate = not running\n\txpc = {\n\t\tdata = <deadbeef>}\n}")
        let fake = LifecycleRuntimeHarness(existingPaths: [job.plistPath], launchAgentLabels: [job.plistPath: job.label],
            commandResults: [idle, idle, batch04Result(), batch04Result(launchctlPrintOutput(pid: 42))], inventory: [process])
        let result = await SystemProcessLifecycleService(runtime: fake.runtime).ensureSystemLaunchDaemons(for: .globalProtect)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(fake.commands.filter { $0.contains("kickstart") }, ["/bin/launchctl kickstart 'gui/501/\(job.label)'"])
        XCTAssertFalse(fake.commands.contains { $0.contains("-k") || $0.contains("osascript") })
    }

    func testStopReportsChangedAgentsEvenWithoutProcessesAndDisclosesRemainingVPN() {
        for (scope, text) in [(PresetStopScope.app, "No Batch04 app was running; launch agents unloaded."), (.helpers, "No user helpers were running; launch agents unloaded."), (.all, "No watched app or user helpers were running; launch agents unloaded.")] {
            let snapshot = WatchedAppSnapshot(preset: preset, runningNames: [])
            let changed = LifecycleBatchResult(jobs: [.init(label: "batch04.agent", state: .changed, detail: "Unloaded")])
            let result = scope.result(before: snapshot, after: snapshot, terminations: [], agents: changed, refreshed: true)
            XCTAssertEqual(result.message, text)
            let vpn = WatchedAppSnapshot(preset: .globalProtect, runningNames: ["PanGPS"])
            let disclosure = scope.result(before: vpn, after: vpn, terminations: [], agents: .notNeeded, refreshed: true)
            XCTAssertTrue(disclosure.message.contains("VPN was not disconnected"))
            XCTAssertTrue(disclosure.message.contains("Quit All in TaskScope"))
        }
    }

    func testLegacyDaemonPortIsIgnoredOnDecode() throws {
        let data = Data(#"{"label":"old","plistPath":"/fake/old.plist","processName":"old","servicePort":4767}"#.utf8)
        let job = try JSONDecoder().decode(SystemLaunchDaemonJob.self, from: data)
        XCTAssertEqual(job.label, "old")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(job), as: UTF8.self).contains("servicePort"))

        // Earlier builds stored the built-in preset's daemon with its port. It
        // still loads as the canonical, writable built-in preset.
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchedAppPreset.globalProtect)) as? [String: Any])
        var daemons = try XCTUnwrap(stored["systemLaunchDaemonJobs"] as? [[String: Any]])
        daemons[0]["servicePort"] = 4767
        stored["systemLaunchDaemonJobs"] = daemons
        let preset = try JSONDecoder().decode(WatchedAppPreset.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertTrue(preset.hasCanonicalGlobalProtectIdentity)
        XCTAssertFalse(preset.hasUnknownFields)
    }
}
