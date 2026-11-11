import Foundation
import XCTest
@testable import TaskScope

final class GlobalProtectServiceControlTests: XCTestCase {
    func testSessionKeepOffPreservesLoadedSystemDaemonAndItsOverride() async {
        for disabled in [false, true] {
            let harness = ServiceHarness(disabled: disabled, loaded: true)
            let session = WatchedAppPreset.globalProtectSessionAgent
            var runtime = harness.runtime
            let exists = runtime.fileExists
            runtime.fileExists = { $0 == session.plistPath || exists($0) }
            runtime.launchAgentLabel = { $0 == session.plistPath ? session.label : ServiceHarness.label }
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertFalse(stopped.succeeded)
            XCTAssertTrue(stopped.failureSummary?.contains("preserved") == true)
            let opened = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertTrue(opened.succeeded)
            XCTAssertTrue(enabled.succeeded)
            let state = await harness.state
            XCTAssertEqual(state.disabled, disabled)
            XCTAssertTrue(state.loaded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
        }
    }

    func testSessionKeepOffRejectsUnknownSystemStateWithoutChangingOverride() async {
        let harness = ServiceHarness()
        var runtime = harness.runtime
        runtime.fileExists = { _ in true }
        let run = runtime.runCommand
        runtime.runCommand = { command, timeout in
            if command.hasPrefix("/bin/launchctl print ") {
                return ShellCommandResult(command: command, stdout: "", stderr: "Access denied", exitCode: 1)
            }
            return await run(command, timeout)
        }
        let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
        )
        XCTAssertFalse(result.succeeded)
        let commands = await harness.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") })
    }

    func testAdministratorStopWaitsForDelayedDaemonExitAndBoundsFailure() async {
        for delayedProbes in [3, 1000] {
            let clock = LifecycleTestClock()
            let harness = ServiceHarness(delayedStopProbes: delayedProbes)
            var runtime = harness.runtime
            runtime.systemUptime = { clock.now }
            runtime.sleep = { clock.advance(Double($0) / 1_000_000_000) }
            let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertEqual(result.succeeded, delayedProbes == 3)
            XCTAssertEqual(clock.now, delayedProbes == 3 ? 1.5 : 30, accuracy: 0.001)
            let commands = await harness.commands
            XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
            XCTAssertLessThan(commands.count, 130)
        }
    }

    func testSystemStopDeadlineIncludesSlowVerificationCommands() async {
        let clock = LifecycleTestClock()
        let harness = ServiceHarness(delayedStopProbes: 1000)
        var runtime = harness.runtime
        let run = runtime.runCommand
        runtime.runCommand = { command, timeout in
            let commands = await harness.commands
            if commands.contains(where: { $0.contains("osascript") }) {
                clock.advance(min(12, timeout))
            }
            return await run(command, timeout)
        }
        runtime.systemUptime = { clock.now }
        runtime.sleep = { clock.advance(Double($0) / 1_000_000_000) }
        let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(clock.now, 30, accuracy: 0.001)
    }

    func testExplicitStopDisablesAndUnloadsThenRestoresWithoutChangingFiles() async {
        let harness = ServiceHarness()
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        XCTAssertTrue(stopped.succeeded)
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(restored.succeeded)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        XCTAssertTrue(enabled.succeeded)
        let final = await harness.state
        XCTAssertFalse(final.disabled)
        XCTAssertTrue(final.loaded)
        let commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 2)
        XCTAssertFalse(commands.contains { $0.contains("kickstart") || $0.contains("/bin/rm") || $0.contains("/bin/mv") || $0.contains("kill ") })
    }

    func testCancelledBootstrapPreservesDisableOverrideWithOnePrompt() async {
        let harness = ServiceHarness(disabled: true, loaded: false, adminFailure: .cancelled)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)

        XCTAssertFalse(restored.succeeded)
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)
        let commands = await harness.commands
        let adminCommands = commands.filter { $0.contains("osascript") }
        XCTAssertEqual(adminCommands.count, 1)
        XCTAssertTrue(adminCommands.first?.contains("launchctl enable") == true)
        XCTAssertTrue(adminCommands.first?.contains("launchctl bootstrap") == true)
    }

    func testLoadedDaemonClearsOverrideWithoutBootstrapping() async {
        let harness = ServiceHarness(disabled: true, loaded: true)

        let restored = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)

        XCTAssertTrue(restored.succeeded)
        XCTAssertTrue(enabled.succeeded)
        let state = await harness.state
        XCTAssertFalse(state.disabled)
        XCTAssertTrue(state.loaded)
        let commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
        XCTAssertFalse(commands.contains { $0.contains("bootstrap") })
    }

    func testBackgroundEnforcementNeverPromptsOrMutatesSystemState() async {
        for disabled in [false, true] {
            for loaded in [false, true] {
                let harness = ServiceHarness(disabled: disabled, loaded: loaded)
                let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                    for: .globalProtect, allowAdministratorPrompt: false, runtime: harness.runtime
                )
                XCTAssertEqual(result.succeeded, disabled && !loaded)
                let commands = await harness.commands
                XCTAssertFalse(commands.contains { $0.contains("osascript") })
                let state = await harness.state
                XCTAssertEqual(state.disabled, disabled)
                XCTAssertEqual(state.loaded, loaded)
            }
        }
    }

    func testCancelledAdministratorStopAndPartialBootoutFailureAreReported() async {
        for failure in [ServiceHarness.AdminFailure.cancelled, .bootoutFailed] {
            let harness = ServiceHarness(adminFailure: failure)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
            )
            XCTAssertFalse(stopped.succeeded)
            XCTAssertTrue(stopped.failureSummary?.contains("Open") == true)
            if failure == .bootoutFailed {
                XCTAssertTrue(stopped.failureSummary?.contains("launchctl bootout exited with status 5.") == true)
            }
            let state = await harness.state
            XCTAssertTrue(state.loaded)
            XCTAssertEqual(state.disabled, failure == .bootoutFailed)
        }
    }

    func testNonzeroAdministratorBootoutIsJudgedByBoundedFinalInspection() async {
        for delayedProbes in [0, 3, 1000] {
            let clock = LifecycleTestClock()
            let harness = ServiceHarness(adminFailure: .bootoutNonzeroAfterExit, delayedStopProbes: delayedProbes)
            var runtime = harness.runtime
            runtime.systemUptime = { clock.now }
            runtime.sleep = { clock.advance(Double($0) / 1_000_000_000) }
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            let exits = delayedProbes < 1000
            XCTAssertEqual(stopped.succeeded, exits, stopped.failureSummary ?? "")
            XCTAssertEqual(stopped.jobs.first?.state, exits ? .changed : .failed)
            XCTAssertEqual(clock.now, exits ? Double(delayedProbes) * 0.5 : 30, accuracy: 0.001)
            if !exits {
                XCTAssertTrue(stopped.failureSummary?.contains("still loaded") == true)
                XCTAssertTrue(stopped.failureSummary?.contains("launchctl bootout exited with status 36.") == true)
            }
            let state = await harness.state
            XCTAssertTrue(state.disabled)
            XCTAssertEqual(state.loaded, !exits)
            let commands = await harness.commands
            XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
        }
    }

    func testRefusedApprovalAndFailedDisableAreToldApartWithoutWaiting() async throws {
        let expectations: [(ServiceHarness.AdminFailure, String)] = [
            (.cancelled, "Administrator approval was cancelled; TaskScope made no change."),
            (.denied, "Administrator approval was denied or could not be requested (AppleScript error -60005); TaskScope made no change."),
            (.disableFailed, "The administrator stop did not confirm its disable step (Could not disable service: Operation not permitted).")
        ]
        for (failure, reason) in expectations {
            let harness = ServiceHarness(adminFailure: failure)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
            )
            XCTAssertFalse(stopped.succeeded)
            let detail = try XCTUnwrap(stopped.jobs.first?.detail)
            XCTAssertTrue(detail.hasPrefix(reason), detail)
            XCTAssertTrue(detail.contains("still loaded"), detail)
            XCTAssertTrue(detail.hasSuffix("Choose Open to restore GlobalProtect or Apply Keep Off to retry."), detail)
            // A definitive refusal needs one inspection, not a disappearance wait.
            let commands = await harness.commands
            let admin = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("/usr/bin/osascript") })
            XCTAssertEqual(Array(commands[(admin + 1)...]), [
                "/bin/launchctl print-disabled system",
                "/bin/launchctl print 'system/com.paloaltonetworks.gp.pangpsd'"
            ])
            let state = await harness.state
            XCTAssertFalse(state.disabled)
            XCTAssertTrue(state.loaded)
        }
    }

    func testFailedAndUnknownProbesNeverClaimOffOrEnabled() async {
        let probes: [ShellCommandResult] = [
            .init(command: "", stdout: "", stderr: "Access denied", exitCode: 1),
            .init(command: "", stdout: "new output format", stderr: "", exitCode: 0),
            .init(command: "", stdout: "", stderr: "Could not find service", exitCode: ShellCommandRunner.timedOutExitCode),
            .init(command: "", stdout: "", stderr: "cancelled", exitCode: ShellCommandRunner.cancelledExitCode)
        ]
        for probe in probes {
            let harness = ServiceHarness(disabled: true, loaded: false, disabledProbe: probe)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: false, runtime: harness.runtime
            )
            let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
            XCTAssertFalse(stopped.succeeded)
            XCTAssertFalse(enabled.succeeded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
        }
    }

    func testUnrecognizedAbsenceAndInterruptedLoadedProbesCannotClaimOff() async {
        for probe in [
            ShellCommandResult(command: "", stdout: "", stderr: "Access denied", exitCode: 113),
            ShellCommandResult(command: "", stdout: "", stderr: "Could not find service \"com.paloaltonetworks.gp.pangpsd\" in domain for system", exitCode: ShellCommandRunner.timedOutExitCode)
        ] {
            var runtime = ServiceHarness(disabled: true, loaded: false).runtime
            let original = runtime.runCommand
            runtime.runCommand = { command, timeout in
                if command.hasPrefix("/bin/launchctl print ") { return probe }
                return await original(command, timeout)
            }
            let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: false, runtime: runtime
            )
            XCTAssertFalse(result.succeeded)
        }
    }

    func testMissingOrMismatchedPlistDoesNotIntroduceDisableOverride() async {
        for label in [nil, "wrong.label"] as [String?] {
            let harness = ServiceHarness(plistLabel: label)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
            )
            XCTAssertFalse(stopped.succeeded)
            XCTAssertEqual(stopped.jobs.first?.detail, "The system service plist is missing or its label does not match. Nothing was disabled; restoration could not be guaranteed.")
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
        }
    }

    func testAlreadyOffAndAlreadyEnabledDoNotPrompt() async {
        let harness = ServiceHarness(disabled: true, loaded: false)
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: .globalProtect, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        XCTAssertTrue(stopped.succeeded)
        var commands = await harness.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") })
        _ = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        _ = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: harness.runtime)
        commands = await harness.commands
        XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
        let state = await harness.state
        XCTAssertFalse(state.loaded, "Turning Keep Off off must not launch anything")
    }

    func testForgedBuiltInIdentityCannotRequestSystemOperations() async {
        let harness = ServiceHarness()
        var forged = WatchedAppPreset.globalProtect
        forged.systemLaunchDaemonJobs[0].plistPath = "/tmp/evil.plist"
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
            for: forged, allowAdministratorPrompt: true, runtime: harness.runtime
        )
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: forged, runtime: harness.runtime)
        XCTAssertEqual(stopped, .notNeeded)
        XCTAssertEqual(enabled, .notNeeded)
        let commands = await harness.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testSessionInstallationPreservesSystemDisableWithoutAdministratorRequest() async {
        let harness = ServiceHarness(disabled: true, loaded: false)
        let session = WatchedAppPreset.globalProtectSessionAgent
        var runtime = harness.runtime
        runtime.fileExists = { $0 == session.plistPath }
        runtime.launchAgentLabel = { $0 == session.plistPath ? session.label : nil }

        // Covers repeated Open / allow-to-run preparation followed by Keep Off.
        for _ in 0..<2 {
            let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertTrue(enabled.succeeded)
            XCTAssertTrue(enabled.jobs.first?.detail.contains("remains disabled") == true)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertTrue(stopped.succeeded)
        }
        let state = await harness.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)
        let commands = await harness.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") || $0.contains("launchctl enable") || $0.contains("bootstrap") })
    }

    func testInvalidSessionPlistCannotClaimPasswordlessRestoration() async {
        for label in [nil, "wrong.label"] as [String?] {
            let harness = ServiceHarness(disabled: true, loaded: false)
            var runtime = harness.runtime
            runtime.fileExists = { $0 == WatchedAppPreset.globalProtectSessionAgent.plistPath }
            runtime.launchAgentLabel = { _ in label }
            let result = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
            XCTAssertFalse(result.succeeded)
            let commands = await harness.commands
            XCTAssertFalse(commands.contains { $0.contains("osascript") })
            let state = await harness.state
            XCTAssertTrue(state.disabled)
        }
    }

    func testPrivilegedStopOrdersAndGuardsDisableBeforeBootout() async throws {
        for preservingLoadedDaemon in [false, true] {
            let harness = ServiceHarness(loaded: !preservingLoadedDaemon)
            var runtime = harness.runtime
            if preservingLoadedDaemon {
                let fileExists = runtime.fileExists
                runtime.fileExists = { fileExists($0) || $0 == WatchedAppPreset.globalProtectSessionAgent.plistPath }
            }
            let result = await ProcessLifecycleController.disableSystemLaunchDaemons(
                for: .globalProtect, allowAdministratorPrompt: true, runtime: runtime
            )
            XCTAssertTrue(result.succeeded)
            let commands = await harness.commands
            let command = try XCTUnwrap(commands.first { $0.hasPrefix("/usr/bin/osascript") })
            let disable = try XCTUnwrap(command.range(of: "/bin/launchctl disable "))
            let bootout = try XCTUnwrap(command.range(of: "/bin/launchctl bootout "))
            XCTAssertLessThan(disable.lowerBound, bootout.lowerBound, "Disable must precede bootout")
            XCTAssertTrue(command.contains(" || exit $?"),
                          "Disable failure must stop the privileged script")
        }
    }

    func testPrivilegedDisableScriptParsesAsShell() async {
        for preservesLoadedDaemon in [false, true] {
            let script = ProcessLifecycleController.adminDisableScript(
                for: WatchedAppPreset.globalProtectSystemDaemon,
                preservingLoadedDaemon: preservesLoadedDaemon
            )
            if preservesLoadedDaemon {
                XCTAssertTrue(script.hasPrefix("if /bin/launchctl print"))
                XCTAssertTrue(script.components(separatedBy: "launchctl disable")[0].contains("exit 1"))
            }
            let result = await ShellCommandRunner.run("/bin/sh -n -c \(ShellCommandRunner.shellQuoted(script))", timeout: 5)
            XCTAssertTrue(result.succeeded, result.stderr)
        }
    }

    /// Runs the root script against a shell-function stand-in for launchctl;
    /// the real tool is never invoked.
    func testPrivilegedStopScriptReportsDisablePhaseAndBootoutStatus() async throws {
        let marker = ProcessLifecycleController.systemDisablePhaseMarker
        let status = ProcessLifecycleController.systemBootoutStatusPrefix
        let cases: [(preserve: Bool, disable: Int, print: Int, bootout: Int, exit: Int32, stdout: String)] = [
            (false, 0, 0, 36, 0, "\(marker)\n\(status)36"),
            (false, 0, 0, 0, 0, marker),
            (false, 0, 113, 0, 0, marker),
            (false, 5, 0, 0, 5, ""),
            (true, 0, 0, 0, 1, ""),
            (true, 0, 113, 36, 0, marker)
        ]
        for scenario in cases {
            let script = ProcessLifecycleController.adminDisableScript(
                for: WatchedAppPreset.globalProtectSystemDaemon,
                preservingLoadedDaemon: scenario.preserve
            ).replacingOccurrences(of: "/bin/launchctl", with: "fake_launchd_tool")
            guard !script.contains("launchctl") else { return XCTFail("The stand-in did not replace every launchctl call") }
            let program = """
            fake_launchd_tool() {
              case "$1" in
                disable) return \(scenario.disable) ;;
                print) return \(scenario.print) ;;
                bootout) return \(scenario.bootout) ;;
              esac
              return 99
            }
            \(script)
            """
            let result = await ShellCommandRunner.run("/bin/sh -c \(ShellCommandRunner.shellQuoted(program))", timeout: 5)
            XCTAssertEqual(result.exitCode, scenario.exit, "\(scenario)")
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .newlines), scenario.stdout, "\(scenario)")
        }
    }

    func testAdministratorStopOutcomeRequiresThePhaseMarkerAndNamesRefusals() {
        typealias Outcome = ProcessLifecycleController.AdministratorStopOutcome
        func osascript(stdout: String = "", stderr: String = "", exitCode: Int32) -> ShellCommandResult {
            ShellCommandResult(command: "osascript", stdout: stdout, stderr: stderr, exitCode: exitCode)
        }
        let marker = ProcessLifecycleController.systemDisablePhaseMarker
        let status = ProcessLifecycleController.systemBootoutStatusPrefix
        // `do shell script` returns carriage-return line endings.
        XCTAssertEqual(Outcome(osascript(stdout: "\(marker)\r\(status)36\n", exitCode: 0)), .disabled(bootoutStatus: 36))
        XCTAssertEqual(Outcome(osascript(stdout: "\(marker)\n", exitCode: 0)), .disabled(bootoutStatus: nil))
        XCTAssertEqual(Outcome(osascript(stdout: "", exitCode: 0)), .failed("exited with status 0"))
        XCTAssertEqual(Outcome(osascript(stderr: "0:242: execution error: User canceled. (-128)\n", exitCode: 1)), .cancelled)
        XCTAssertEqual(
            Outcome(osascript(stderr: "0:242: execution error: The administrator user name or password was incorrect. (-60005)", exitCode: 1)),
            .denied(-60005)
        )
        XCTAssertEqual(Outcome(osascript(stderr: "0:242: execution error: No user interaction allowed. (-60007)", exitCode: 1)), .denied(-60007))
        XCTAssertEqual(
            Outcome(osascript(stderr: "0:242: execution error: The command exited with a non-zero status. (1)", exitCode: 1)),
            .failed("The command exited with a non-zero status.")
        )
        XCTAssertEqual(Outcome(osascript(stderr: "0:242: execution error: Cancelled (-60006)", exitCode: 1)), .cancelled)
        XCTAssertEqual(Outcome(osascript(stderr: "User canceled.", exitCode: 1)), .failed("exited with status 1"))
        XCTAssertEqual(
            Outcome(osascript(exitCode: ShellCommandRunner.timedOutExitCode)),
            .timedOut
        )
    }
    func testBatch04SessionOpenWorksWithDisabledUnloadedSystemDaemon() async {
        let fake = ServiceHarness(disabled: true, loaded: false, sessionLoaded: true)
        let session = WatchedAppPreset.globalProtectSessionAgent
        var runtime = fake.runtime
        let exists = runtime.fileExists
        runtime.fileExists = { $0 == session.plistPath || exists($0) }
        runtime.launchAgentLabel = { $0 == session.plistPath ? session.label : ServiceHarness.label }
        let opened = await ProcessLifecycleController.ensureSystemLaunchDaemons(for: .globalProtect, runtime: runtime)
        XCTAssertTrue(opened.succeeded)
        let commands = await fake.commands
        XCTAssertFalse(commands.contains { $0.contains("system/") || $0.contains("osascript") })
        let state = await fake.state
        XCTAssertTrue(state.disabled)
        XCTAssertFalse(state.loaded)
    }

    func testBatch04ApprovedEnableMustClearOverride() async {
        let fake = ServiceHarness(disabled: true, loaded: false, adminFailure: .enableIgnored)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
        XCTAssertFalse(enabled.succeeded)
        XCTAssertTrue(enabled.failureSummary?.contains("Could not verify that the system service was re-enabled") == true)
    }

    func testBatch04AdministratorTimeoutHasActionableTextAndWaitsOnlyAfterDisable() async {
        for disabled in [false, true] {
            let fake = ServiceHarness(adminFailure: disabled ? .timedOutAfterChange : .timedOut, delayedStopProbes: 3)
            let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: true, runtime: fake.runtime)
            XCTAssertEqual(stopped.succeeded, disabled)
            if !disabled { XCTAssertTrue(stopped.failureSummary?.contains("approval may not have been given") == true) }
            let commands = await fake.commands
            XCTAssertEqual(commands.filter { $0.contains("osascript") }.count, 1)
            XCTAssertTrue(commands.first { $0.contains("osascript") }?.contains("with prompt") == true)
        }
        let fake = ServiceHarness(disabled: true, loaded: false, adminFailure: .timedOut)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
        XCTAssertTrue(enabled.failureSummary?.contains("approval may not have been given") == true)
    }

    func testBatch04MissingDaemonPlistCountsAsOffOnlyWhenNothingIsLoaded() async {
        for allowPrompt in [false, true] {
            let absent = ServiceHarness(loaded: false, plistLabel: nil)
            let off = await ProcessLifecycleController.disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: allowPrompt, runtime: absent.runtime)
            XCTAssertEqual(off.jobs.map(\.state), [.alreadyUnloaded])
            let loaded = ServiceHarness(loaded: true, plistLabel: nil)
            let refused = await ProcessLifecycleController.disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: allowPrompt, runtime: loaded.runtime)
            XCTAssertFalse(refused.succeeded)
            XCTAssertFalse(refused.failureSummary?.contains("login-session") == true)
            for harness in [absent, loaded] {
                let commands = await harness.commands
                XCTAssertFalse(commands.contains { $0.contains("osascript") })
            }
        }
    }

    func testBatch04LateApprovedEnableIsVerifiedFromLaunchd() async {
        let fake = ServiceHarness(disabled: true, loaded: false, adminFailure: .timedOutAfterChange)
        let enabled = await ProcessLifecycleController.enableSystemLaunchDaemons(for: .globalProtect, runtime: fake.runtime)
        XCTAssertEqual(enabled.jobs.map(\.state), [.changed])
        XCTAssertTrue(enabled.jobs.first?.detail.contains("after the administrator request timed out") == true)
        let commands = await fake.commands
        XCTAssertTrue(commands.first { $0.contains("osascript") }?.contains("with prompt") == true)
    }

    func testBatch04SessionOnlyInstallNeedsNoSystemDisableOverrideOrPrompt() async {
        let fake = ServiceHarness(disabled: false, loaded: false)
        let session = WatchedAppPreset.globalProtectSessionAgent
        var runtime = fake.runtime
        runtime.fileExists = { $0 == session.plistPath }
        let stopped = await ProcessLifecycleController.disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: false, runtime: runtime)
        XCTAssertTrue(stopped.succeeded)
        XCTAssertEqual(stopped.jobs.first?.state, .alreadyUnloaded)
        XCTAssertTrue(stopped.jobs.first?.detail.contains("No system VPN daemon is installed or loaded") == true)
        let commands = await fake.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") })
    }

}

private actor ServiceHarness {
    /// `bootoutFailed` leaves the daemon loaded; `bootoutNonzeroAfterExit`
    /// reports a nonzero bootout while launchd still removes the job.
    enum AdminFailure { case cancelled, denied, disableFailed, bootoutFailed, bootoutNonzeroAfterExit, enableIgnored, timedOut, timedOutAfterChange }
    var sessionLoaded: Bool
    var state: (disabled: Bool, loaded: Bool)
    var commands: [String] = []
    let adminFailure: AdminFailure?
    let plistLabel: String?
    let disabledProbe: ShellCommandResult?
    var delayedStopProbes: Int
    var stopAcknowledged = false
    static let label = "com.paloaltonetworks.gp.pangpsd"

    init(disabled: Bool = false, loaded: Bool = true, adminFailure: AdminFailure? = nil,
         plistLabel: String? = label, disabledProbe: ShellCommandResult? = nil, delayedStopProbes: Int = 0, sessionLoaded: Bool = true) {
        self.sessionLoaded = sessionLoaded
        state = (disabled, loaded)
        self.adminFailure = adminFailure
        self.plistLabel = plistLabel
        self.disabledProbe = disabledProbe
        self.delayedStopProbes = delayedStopProbes
    }

    nonisolated var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in plistLabel != nil && path == "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist" },
            launchAgentLabel: { [self] _ in plistLabel },
            runCommand: { [self] command, _ in await run(command) },
            loadProcessInventory: {
                .success([AppProcess(pid: 42, parentPID: 1, uid: 0, cpu: 0, memoryMB: 0,
                    command: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS",
                    elapsedTime: "00:10", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)])
            },
            executablePathForPID: { _ in "/Applications/GlobalProtect.app/Contents/Resources/PanGPS" },
            sendSignal: { _, _ in false },
            isProcessAlive: { _ in false },
            sleep: { _ in },
            systemUptime: { 0 },
            isAppBundle: { _ in false }
        )
    }

    func run(_ command: String) -> ShellCommandResult {
        commands.append(command)
        if command == "/bin/launchctl print-disabled system" {
            return disabledProbe ?? result("disabled services = {\n\"\(Self.label)\" => \(state.disabled ? "disabled" : "enabled")\n}")
        }
        if command.hasPrefix("/bin/launchctl print ") {
            if command.contains("gui/501/com.paloaltonetworks.gp.pangps") {
                return sessionLoaded ? result(launchctlPrintOutput(pid: 42))
                    : result("", error: "Could not find service \"com.paloaltonetworks.gp.pangps\" in domain", code: 113)
            }
            if stopAcknowledged {
                state.loaded = delayedStopProbes > 0
                delayedStopProbes = max(0, delayedStopProbes - 1)
            }
            return state.loaded ? result(launchctlPrintOutput(pid: 42))
                : result("", error: "Could not find service \"\(Self.label)\" in domain for system", code: 113)
        }
        if command.hasPrefix("/usr/bin/osascript") {
            if adminFailure == .timedOut { return result("", code: ShellCommandRunner.timedOutExitCode) }
            // osascript's own report of a refused authorization.
            if adminFailure == .cancelled {
                return result("", error: "0:242: execution error: User canceled. (-128)", code: 1)
            }
            if adminFailure == .denied {
                return result("", error: "0:242: execution error: The administrator user name or password was incorrect. (-60005)", code: 1)
            }
            if command.contains("launchctl disable") {
                if adminFailure == .disableFailed {
                    return result("", error: "0:242: execution error: Could not disable service: Operation not permitted (1)", code: 1)
                }
                state.disabled = true
                if adminFailure == .timedOutAfterChange {
                    stopAcknowledged = true
                    state.loaded = delayedStopProbes > 0
                    return result("", code: ShellCommandRunner.timedOutExitCode)
                }
                // `do shell script` returns stdout only when the script exits 0.
                let phase = command.contains("echo TASKSCOPE_SYSTEM_DISABLED") ? "TASKSCOPE_SYSTEM_DISABLED" : ""
                switch adminFailure {
                case .bootoutFailed:
                    return bootoutFailure(5, "Input/output error", phase: phase, command: command)
                case .bootoutNonzeroAfterExit:
                    stopAcknowledged = true
                    state.loaded = delayedStopProbes > 0
                    return bootoutFailure(36, "Operation now in progress", phase: phase, command: command)
                default:
                    stopAcknowledged = true
                    state.loaded = delayedStopProbes > 0
                    return result(phase)
                }
            } else if command.contains("launchctl bootstrap") {
                state.disabled = false
                state.loaded = true
                stopAcknowledged = false
            } else if command.contains("launchctl enable"), adminFailure != .enableIgnored {
                state.disabled = false
                if adminFailure == .timedOutAfterChange { return result("", code: ShellCommandRunner.timedOutExitCode) }
            }
            return result("")
        }
        return result("", error: "Unexpected command", code: 1)
    }

    /// A script that captures bootout's status still exits 0 and returns its
    /// output; one that exits with that status surfaces only the error.
    func bootoutFailure(_ status: Int32, _ reason: String, phase: String, command: String) -> ShellCommandResult {
        if command.contains("TASKSCOPE_BOOTOUT_EXIT=") {
            return result("\(phase)\rTASKSCOPE_BOOTOUT_EXIT=\(status)")
        }
        return result("", error: "0:242: execution error: Boot-out failed: \(status): \(reason) (\(status))", code: 1)
    }

    func result(_ text: String, error: String = "", code: Int32 = 0) -> ShellCommandResult {
        ShellCommandResult(command: "fixture", stdout: text, stderr: error, exitCode: code)
    }
}
