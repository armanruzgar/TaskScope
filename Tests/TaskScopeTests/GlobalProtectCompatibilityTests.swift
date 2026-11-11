import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class GlobalProtectCompatibilityTests: XCTestCase {
    typealias Checker = GlobalProtectCompatibilityChecker
    typealias Report = GlobalProtectCompatibilityReport
    typealias Runtime = GlobalProtectCompatibilityRuntime

    func testProbeCommandsAreRestrictedToReadOnlyFixedTargets() async {
        let recorder = ProbeRecorder()
        var runtime = fixture()
        runtime.runProbe = { probe in
            await recorder.record(probe)
            return Self.response(for: probe)
        }
        let report = await Checker(runtime: runtime).check(keepOffRequested: true)
        let probes = await recorder.probes
        XCTAssertEqual(Set(probes), [.userDisabled, .systemDisabled, .service(.pangpa), .service(.pangps), .service(.pangpsd), .macOSVersion, .macOSBuild])
        XCTAssertEqual(probes.count, 7)
        XCTAssertEqual(Set(probes.map { $0.command(userID: 501) }), [
            "/bin/launchctl print-disabled gui/501",
            "/bin/launchctl print-disabled system",
            "/bin/launchctl print gui/501/com.paloaltonetworks.gp.pangpa",
            "/bin/launchctl print gui/501/com.paloaltonetworks.gp.pangps",
            "/bin/launchctl print system/com.paloaltonetworks.gp.pangpsd",
            "/usr/bin/sw_vers -productVersion", "/usr/bin/sw_vers -buildVersion"
        ])
        XCTAssertEqual(report.keepOffRequested, true)
        XCTAssertEqual(Report.Service.allCases.filter { !$0.isSystem }.map(\.label), WatchedAppPreset.globalProtect.lifecycleUserLaunchAgentJobs.map(\.label))
        XCTAssertEqual(Report.Service.allCases.map(\.plistPath), WatchedAppPreset.globalProtect.lifecycleUserLaunchAgentJobs.map(\.plistPath) + WatchedAppPreset.globalProtect.lifecycleSystemLaunchDaemonJobs.map(\.plistPath))
    }

    func testAbsentOptionalPlistStillHasIndependentDisabledAndLoadedState() async {
        var runtime = fixture()
        runtime.inspectPlist = { $0 == .pangps ? .missing : .installed(disabledByDefault: false) }
        runtime.runProbe = { probe in
            switch probe {
            case .userDisabled:
                Self.result("disabled services = {\n\"com.paloaltonetworks.gp.pangps\" => disabled\n}")
            case .service(.pangps): Self.result("job = {\n\tpid = 32\n}")
            default: Self.response(for: probe)
            }
        }
        let report = await Checker(runtime: runtime).check(keepOffRequested: true)
        let optional = report.jobs[1]
        XCTAssertEqual(optional.plist, .missing)
        XCTAssertEqual(optional.disabled, .disabled)
        XCTAssertEqual(optional.loaded, .loaded)
        XCTAssertTrue(report.redactedSummary.contains("login-session VPN service, optional install"))
    }

    func testDisabledParsesBothShippedFormatsWithoutConfusingNoOverrideWithEnabled() {
        let label = Report.Service.pangpa.label
        for token in ["true", "disabled"] {
            XCTAssertEqual(Checker.disabledState(Self.result("disabled services = {\n\"\(label)\" => \(token)\n}"), label: label), .disabled)
        }
        for token in ["false", "enabled"] {
            XCTAssertEqual(Checker.disabledState(Self.result("disabled services = {\n\"\(label)\" => \(token)\n}"), label: label), .enabled)
        }
        XCTAssertEqual(Checker.disabledState(Self.result("\n disabled services = {\n}\n"), label: label), .noOverride)
        XCTAssertEqual(Checker.disabledState(Self.result("disabled services = {\n\"\(label).other\" => true\n}"), label: label), .noOverride)
        for output in ["", "new format", "disabled services = {", "disabled services = {\n\"\(label)\" => maybe\n}", "disabled services = {\n\"\(label)\" => true\n\"\(label)\" => false\n}"] {
            XCTAssertEqual(Checker.disabledState(Self.result(output), label: label), .unknown(.unrecognized))
        }
    }

    func testProbeFailuresNeverBecomeAbsenceOrEnabledAndNeverExposeRawErrors() async {
        for (code, reason) in [(Int32(1), Report.UnknownReason.unavailable), (113, .unavailable), (ShellCommandRunner.timedOutExitCode, .timedOut), (ShellCommandRunner.cancelledExitCode, .cancelled)] {
            let response = Self.result("private-user organization.example", code: code, stderr: "/Users/alice/private/key")
            XCTAssertEqual(Checker.disabledState(response, label: Report.Service.pangpa.label), .unknown(reason))
            XCTAssertEqual(Checker.loadedState(response, service: .pangpa), .unknown(reason))
        }
        XCTAssertEqual(Checker.loadedState(Self.response(for: .service(.pangpa)), service: .pangpa), .notLoaded)
        XCTAssertEqual(Checker.loadedState(Self.response(for: .service(.pangpa)), service: .pangps), .unknown(.unavailable))
        let signal = ShellCommandResult(command: "", stdout: "", stderr: "Could not find service \"\(Report.Service.pangpa.label)\" in domain", exitCode: 113, terminatedBySignal: 9)
        XCTAssertEqual(Checker.loadedState(signal, service: .pangpa), .unknown(.unavailable))

        var runtime = fixture()
        runtime.runProbe = { _ in Self.result("/Users/alice/acme", code: 1, stderr: "vpn.acme.example token=secret") }
        runtime.loadInventory = { .failure(.commandFailed("alice: private password")) }
        let report = await Checker(runtime: runtime).check(keepOffRequested: nil)
        XCTAssertEqual(report.inventoryFailure, .unavailable)
        XCTAssertFalse(report.systemProcessVerified)
        XCTAssertTrue(report.redactedSummary.contains("no absence inferred"))
        XCTAssertTrue(report.redactedSummary.contains("Unknown (not read or settings unreadable)"))
        for secret in ["alice", "acme", "token=secret", "password"] {
            XCTAssertFalse(report.redactedSummary.contains(secret))
        }
    }

    func testPlistDefaultsLabelsAndMalformedFilesAreDistinguished() throws {
        func data(_ fields: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
        }
        let label = Report.Service.pangpa.label
        XCTAssertEqual(Checker.plistState(try data(["Label": label]), service: .pangpa), .installed(disabledByDefault: false))
        XCTAssertEqual(Checker.plistState(try data(["Label": label, "Disabled": true]), service: .pangpa), .installed(disabledByDefault: true))
        XCTAssertEqual(Checker.plistState(try data(["Label": label, "Disabled": "false"]), service: .pangpa), .unreadable)
        XCTAssertEqual(Checker.plistState(try data(["Label": label, "Disabled": 1]), service: .pangpa), .unreadable)
        XCTAssertEqual(Checker.plistState(try data(["Label": "private.organization"]), service: .pangpa), .labelMismatch)
        XCTAssertEqual(Checker.plistState(Data("invalid".utf8), service: .pangpa), .unreadable)
    }

    func testCurrentUserPanGPSIsSeparateFromRootOtherUsersAndUnverifiedCandidates() async {
        let processes = [
            process(pid: 10, uid: 501, name: "GlobalProtect"),
            process(pid: 11, uid: 501, name: "PanGPA"),
            process(pid: 12, uid: 501, name: "PanGPS"),
            process(pid: 13, uid: 0, name: "PanGPS"),
            process(pid: 14, uid: 502, name: "PanGPS"),
            process(pid: 15, uid: nil, name: "PanGPS"),
            process(pid: 16, uid: 0, name: "PanGPS", path: "/tmp/PanGPS"),
            process(pid: 17, uid: 0, name: "PanGPS", path: nil),
            process(pid: 18, uid: 501, name: "PanGPS", path: "/Applications/GlobalProtect.app/Contents/../../forged/PanGPS")
        ]
        let report = await Checker(runtime: fixture(processes: processes, systemPID: 13)).check(keepOffRequested: false)
        XCTAssertEqual(report.processes[0].currentUser, 1)
        XCTAssertEqual(report.processes[1].currentUser, 1)
        XCTAssertEqual(report.processes[2], Report.ProcessCounts(name: .panGPS, currentUser: 1, root: 1, otherUser: 1, unverified: 4))
        XCTAssertTrue(report.systemProcessVerified)
        // A matching launchd PID alone is insufficient: root + trusted product
        // executable are both required, and a user PanGPS is never promoted.
        for pid: Int32 in [12, 15, 16, 17, 99] {
            let other = await Checker(runtime: fixture(processes: processes, systemPID: pid)).check(keepOffRequested: false)
            XCTAssertFalse(other.systemProcessVerified)
        }
    }

    func testNestedPIDAndMalformedOutputCannotVerifyTheProtectedProcess() {
        XCTAssertEqual(Checker.topLevelPID("system/job = {\n\tpid = 55\n\tchild = {\n\t\tpid = 99\n\t}\n}"), 55)
        for output in ["job = {\n\tchild = {\n\t\tpid = 99\n\t}\n}", "job = {\n\tpid = 0\n}", "job = {\n\tpid = 55\n", "job = {\n\tpid = 55\n\tpid = 56\n}"] {
            XCTAssertNil(Checker.topLevelPID(output))
        }
    }

    func testVersionsAreUsefulButArbitraryMetadataIsRedacted() {
        for value in ["1.0.0", "3", "6.3.3-711", "6.2.8-h1"] {
            // Numeric build suffixes are used by GlobalProtect bundles.
            XCTAssertEqual(Checker.safeVersion(value), value)
        }
        XCTAssertEqual(Checker.safeVersion("25G83\n", osBuild: true), "25G83")
        XCTAssertEqual(Checker.safeVersion(nil), "Unavailable")
        for value in ["Alice's laptop", "1.0\nvpn.example.org", "/Users/alice", "1.2 (ACME)", String(repeating: "1", count: 100)] {
            XCTAssertEqual(Checker.safeVersion(value), "Unavailable (unrecognized value redacted)")
        }
    }

    func testTaskScopeVersionDoesNotUseTheTestRunnerOrAnotherHostsVersion() {
        let runner: [String: Any] = ["CFBundleExecutable": "xctest", "CFBundleShortVersionString": "16.0", "CFBundleVersion": "24904"]
        XCTAssertNil(Runtime.taskScopeVersionMetadata(runner).version)
        XCTAssertNil(Runtime.taskScopeVersionMetadata(nil).build)
        let app: [String: Any] = ["CFBundleExecutable": "TaskScope", "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "3"]
        XCTAssertEqual(Runtime.taskScopeVersionMetadata(app).version, "1.0.0")
        XCTAssertEqual(Runtime.taskScopeVersionMetadata(app).build, "3")
    }

    func testCancelledInventoryIsUnknownEvenWhenLaunchdReadsSucceed() async {
        var runtime = fixture(systemPID: 42)
        runtime.loadInventory = { .failure(.cancelled) }
        let report = await Checker(runtime: runtime).check(keepOffRequested: false)
        XCTAssertEqual(report.jobs[2].loaded, .loaded)
        XCTAssertEqual(report.inventoryFailure, .cancelled)
        XCTAssertFalse(report.systemProcessVerified)
        XCTAssertFalse(report.redactedSummary.contains("current user 0"))
    }

    @MainActor
    func testSelfCheckIsAvailableOnlyForBuiltInPresetEvenWithUnreadableSettings() throws {
        func card(_ preset: WatchedAppPreset) -> PresetCard {
            PresetCard(snapshot: WatchedAppSnapshot(preset: preset, runningNames: []),
                       onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
                       isKeptOff: false, isKeepOffControlEnabled: false, onKeepOffChanged: { _ in })
        }
        let builtIn = try card(.globalProtect).inspect()
        XCTAssertFalse(try builtIn.find(button: "Compatibility Self-Check").isDisabled())
        XCTAssertNil(try builtIn.find(GlobalProtectCompatibilityButton.self).actualView().keepOffRequested)
        var custom = WatchedAppPreset.globalProtect
        custom.id = UUID()
        XCTAssertThrowsError(try card(custom).inspect().find(GlobalProtectCompatibilityButton.self))
    }

    @MainActor
    func testPreviewClipboardAndExportContainExactlyTheSameRedactedSummary() async throws {
        var runtime = fixture(processes: [process(pid: 54321, uid: 501, name: "GlobalProtect", path: "/Users/alice/Acme/GlobalProtect")])
        runtime.versions = { ("1.0.0", "3", "6.3.3-711", "private.company") }
        let report = await Checker(runtime: runtime).check(keepOffRequested: true)
        let document = GlobalProtectCompatibilityDocument(report: report)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(document.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), report.redactedSummary)
        XCTAssertEqual(String(data: document.utf8Data, encoding: .utf8), report.redactedSummary)
        XCTAssertTrue(report.redactedSummary.contains("TaskScope: 1.0.0 (build 3)"))
        XCTAssertTrue(report.redactedSummary.contains("macOS: 26.6.2 (build 25G83)"))
        for secret in ["54321", "501", "alice", "Acme", "/Users/", "private.company"] {
            XCTAssertFalse(document.text.contains(secret))
        }
        let sheet = GlobalProtectCompatibilitySheet(keepOffRequested: true, onClose: {}, checker: Checker(runtime: runtime), report: report)
        let view = try sheet.inspect()
        XCTAssertNoThrow(try view.find(text: report.redactedSummary))
        XCTAssertFalse(try view.find(button: "Copy Summary").isDisabled())
        XCTAssertFalse(try view.find(button: "Export…").isDisabled())
        let loading = try GlobalProtectCompatibilitySheet(keepOffRequested: false, onClose: {}).inspect()
        XCTAssertTrue(try loading.find(button: "Copy Summary").isDisabled())
        XCTAssertTrue(try loading.find(button: "Export…").isDisabled())
    }

    /// Explicitly opt in on a real Mac. No launchd or process lifecycle mutation
    /// occurs. This is observation evidence, never a lifecycle smoke test.
    func testLiveReadOnlyEvidenceWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["TASKSCOPE_LIVE_COMPATIBILITY"] == "1" else {
            throw XCTSkip("Set TASKSCOPE_LIVE_COMPATIBILITY=1 for a real read-only observation.")
        }
        let report = await Checker().check(keepOffRequested: nil)
        print(report.redactedSummary)
        XCTAssertEqual(report.jobs.count, 3)
        XCTAssertFalse(report.macOSVersion.contains("Unknown"))
        XCTAssertNil(report.inventoryFailure)
    }

    private func fixture(processes: [AppProcess] = [], systemPID: Int32? = nil) -> Runtime {
        Runtime(
            userID: 501,
            inspectPlist: { _ in .installed(disabledByDefault: false) },
            runProbe: { probe in
                if probe == .service(.pangpsd), let systemPID {
                    return Self.result("system/job = {\n\tpid = \(systemPID)\n}")
                }
                return Self.response(for: probe)
            },
            loadInventory: { .success(processes) },
            versions: { ("1.0.0", "3", "6.3.3", "711") },
            now: { Date(timeIntervalSince1970: 1_789_214_400) }
        )
    }

    private static func response(for probe: Runtime.Probe) -> ShellCommandResult {
        switch probe {
        case .userDisabled, .systemDisabled: result("disabled services = {\n}")
        case .macOSVersion: result("26.6.2\n")
        case .macOSBuild: result("25G83\n")
        case .service(let service): result("", code: 113, stderr: "Bad request.\nCould not find service \"\(service.label)\" in domain for \(service.isSystem ? "system" : "user gui: 501")")
        }
    }

    private static func result(_ output: String, code: Int32 = 0, stderr: String = "") -> ShellCommandResult {
        ShellCommandResult(command: "private command", stdout: output, stderr: stderr, exitCode: code)
    }

    private func process(pid: Int32, uid: uid_t?, name: String, path: String? = "default") -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: uid, cpu: 0, memoryMB: 0, command: name,
                   executablePath: path == "default" ? "/Applications/GlobalProtect.app/Contents/MacOS/\(name)" : path,
                   elapsedTime: "00:10", startTime: "private start time", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }
}

private actor ProbeRecorder {
    var probes: [GlobalProtectCompatibilityRuntime.Probe] = []
    func record(_ probe: GlobalProtectCompatibilityRuntime.Probe) { probes.append(probe) }
}
