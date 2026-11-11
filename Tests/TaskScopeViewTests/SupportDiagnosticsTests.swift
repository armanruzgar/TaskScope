import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class SupportDiagnosticsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testExportRedactsEveryUntrustedPresetAndErrorField() async throws {
        let preset = Self.privatePreset
        let harness = DiagnosticsInspectionHarness(results: [
            .init(command: Self.secret, stdout: Self.secret, stderr: Self.secret, exitCode: 1)
        ])
        let selected = await SupportDiagnosticsCollector(runtime: harness.runtime)
            .inspectPreset(preset, keepOffRequested: false)
        var history = LifecycleDiagnosticsHistory()
        history.record(
            presetID: preset.id, action: .open, reason: .userLaunchAgentFailed,
            jobs: [.init(label: Self.secret, state: .failed, detail: Self.secret),
                   .init(label: Self.secret, state: .missing, detail: Self.secret)], at: date
        )
        let preview = try SupportDiagnosticsPreview(report: report(
            selected: selected, failures: history.failures(for: preset.id)
        ))

        for secret in [Self.secret, "alice", "Acme", "com.acme", "--token", "secret-value",
                       "/Users/", "/Library/", "launchctl", "PrivateHelper", "PrivateDaemon",
                       preset.id.uuidString, preset.displayName, preset.appPath] {
            XCTAssertFalse(preview.text.contains(secret), "Leaked private field: \(secret)")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "app", "version", "build", "macOS",
                                        "architecture", "capturedAt", "permissions", "selectedPreset",
                                        "recentLifecycleFailures"])
        let identity = try XCTUnwrap(json["selectedPreset"] as? [String: Any])
        XCTAssertEqual(Set(identity.keys), ["reference", "kind", "appBundleFound", "keepOffRequested", "userLaunchAgents"])
        XCTAssertEqual(identity["reference"] as? String, "selected-preset")
        XCTAssertEqual(identity["kind"] as? String, "custom")
        let agents = try XCTUnwrap(identity["userLaunchAgents"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(agents.first).keys), ["number", "required", "plistFound", "state"])
        let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
        XCTAssertEqual(Set(permissions.keys), ["notifications", "notificationsEnabledInApp", "accessibilityGranted",
                                               "launchAtLogin", "administratorAuthorization"])
        XCTAssertEqual(permissions["notifications"] as? String, "denied")
        XCTAssertEqual(permissions["launchAtLogin"] as? String, "requiresApproval")
        let exportedFailures = try XCTUnwrap(json["recentLifecycleFailures"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(exportedFailures.first).keys), ["occurredAt", "action", "reason",
                                                                       "backgroundEnforcement", "failedJobCount", "missingJobCount"])
        XCTAssertEqual(selected.userLaunchAgents.first?.state, .unknown)
        XCTAssertEqual(history.failures(for: preset.id).first?.failedJobCount, 1)
        XCTAssertEqual(history.failures(for: preset.id).first?.missingJobCount, 1)
        XCTAssertTrue(preview.text.contains("userLaunchAgentFailed"))
    }

    func testVersionMetadataAllowsOnlyNumericVersions() {
        for value in [Self.secret, "1.2\nalice", "1.2\n", "1.2-acme", " 1.2", "", "1..2",
                      "1.2.3.4.5", String(repeating: "1", count: 65)] {
            let report = report(version: value, build: value)
            XCTAssertEqual(report.version, "unavailable")
            XCTAssertEqual(report.build, "unavailable")
        }
        XCTAssertEqual(report(version: nil, build: nil).version, "unavailable")
        XCTAssertEqual(report().version, "1.2.3")
        XCTAssertEqual(report().build, "42")
        XCTAssertEqual(report().macOS, "15.2.1")
    }

    func testHistoryIsBoundedFilteredNewestFirstAndCleared() {
        let preset = UUID()
        let other = UUID()
        var history = LifecycleDiagnosticsHistory()
        for index in 0..<25 {
            history.record(
                presetID: preset, action: .close, reason: .inventoryUnavailable,
                jobs: [], at: date.addingTimeInterval(Double(index))
            )
        }
        history.record(presetID: other, action: .keepOff, backgroundEnforcement: true,
                       reason: .signalRejected, jobs: [], at: date.addingTimeInterval(25))
        let failures = history.failures(for: preset)
        XCTAssertEqual(failures.count, 19)
        XCTAssertEqual(failures.first?.occurredAt, date.addingTimeInterval(24))
        XCTAssertEqual(failures.last?.occurredAt, date.addingTimeInterval(6))
        XCTAssertEqual(history.failures(for: other).first?.backgroundEnforcement, true)
        XCTAssertTrue(history.failures(for: nil).isEmpty)
        XCTAssertTrue(LifecycleDiagnosticsHistory().failures(for: preset).isEmpty)
        history.clear()
        XCTAssertTrue(history.failures(for: preset).isEmpty)
        XCTAssertTrue(history.failures(for: other).isEmpty)
    }

    func testCollectorReadsOnlySelectedJobsAndDoesNotMutateOrReadProcesses() async {
        var preset = Self.privatePreset
        preset.userLaunchAgentJobs = (0..<5).map {
            .init(label: "com.acme.agent\($0)", plistPath: "/Users/alice/agent\($0).plist", isRequired: $0 == 0)
        }
        let harness = DiagnosticsInspectionHarness(results: [
            .init(command: "", stdout: Self.secret, stderr: "", exitCode: 0),
            .init(command: "", stdout: "", stderr: "Could not find service \"com.acme.agent1\" in domain for user gui: 501", exitCode: 113),
            .init(command: "", stdout: "", stderr: Self.secret, exitCode: 1),
            .init(command: "", stdout: "service not found", stderr: Self.secret,
                  exitCode: ShellCommandRunner.timedOutExitCode),
            .init(command: "", stdout: "service not found", stderr: Self.secret,
                  exitCode: 15, terminatedBySignal: 15)
        ])
        let result = await SupportDiagnosticsCollector(runtime: harness.runtime)
            .inspectPreset(preset, keepOffRequested: true)
        XCTAssertEqual(result.userLaunchAgents.map(\.state), [.loaded, .notLoaded, .unknown, .unknown, .unknown])
        XCTAssertEqual(result.userLaunchAgents.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(result.userLaunchAgents.map(\.required), [true, false, false, false, false])
        XCTAssertEqual(result.keepOffRequested, true)
        XCTAssertFalse(result.appBundleFound)
        XCTAssertTrue(result.userLaunchAgents.allSatisfy { !$0.plistFound })
        XCTAssertEqual(harness.commands, preset.userLaunchAgentJobs.map {
            .launchctl("print", "gui/501/\($0.label)")
        })
    }

    /// L02-1: `gui/501//x` names the whole login domain, whose listing exits 0.
    /// A label launchctl would misread is reported as unknown, never inspected.
    func testInvalidLabelsAreReportedUnknownWithoutRunningLaunchctl() async {
        var preset = Self.privatePreset
        preset.userLaunchAgentJobs = ["/x", "com.acme.agent/updater", "com.acme.agent"].map {
            .init(label: $0, plistPath: "/Users/alice/agent.plist")
        }
        let harness = DiagnosticsInspectionHarness(results: [
            .init(command: "", stdout: "gui/501/com.acme.agent = {", stderr: "", exitCode: 0)
        ])
        let result = await SupportDiagnosticsCollector(runtime: harness.runtime)
            .inspectPreset(preset, keepOffRequested: false)
        XCTAssertEqual(result.userLaunchAgents.map(\.state), [.unknown, .unknown, .loaded])
        XCTAssertEqual(harness.commands, [.launchctl("print", "gui/501/com.acme.agent")])
    }

    /// T05-9: presence is read for the preset's own app path and each job's
    /// own plist path, and a found file reaches the report.
    func testCollectorReportsWhichConfiguredFilesExist() async {
        var preset = Self.privatePreset
        preset.appPath = "/Applications/Present.app"
        preset.userLaunchAgentJobs = [
            .init(label: "com.acme.present", plistPath: "/Users/alice/present.plist", isRequired: true),
            .init(label: "com.acme.missing", plistPath: "/Users/alice/missing.plist", isRequired: false)
        ]
        let harness = DiagnosticsInspectionHarness(
            results: [], existingPaths: ["/Applications/Present.app", "/Users/alice/present.plist"]
        )

        let result = await SupportDiagnosticsCollector(runtime: harness.runtime)
            .inspectPreset(preset, keepOffRequested: nil)

        XCTAssertTrue(result.appBundleFound)
        XCTAssertEqual(result.userLaunchAgents.map(\.plistFound), [true, false])
        XCTAssertEqual(harness.pathQueries, [
            "/Users/alice/present.plist", "/Users/alice/missing.plist", "/Applications/Present.app"
        ])

        preset.appPath = "/Applications/Missing.app"
        let missing = await SupportDiagnosticsCollector(runtime: harness.runtime)
            .inspectPreset(preset, keepOffRequested: nil)
        XCTAssertFalse(missing.appBundleFound)
    }

    func testCanonicalIdentityCannotBeSpoofedByNameOrUUID() async {
        let collector = SupportDiagnosticsCollector(runtime: DiagnosticsInspectionHarness(results: []).runtime)
        let builtIn = await collector.inspectPreset(.globalProtect, keepOffRequested: false)
        XCTAssertEqual(builtIn.kind, .builtInGlobalProtect)
        var forged = Self.privatePreset
        forged.id = WatchedAppPreset.globalProtectID
        forged.displayName = "GlobalProtect"
        let custom = await collector.inspectPreset(forged, keepOffRequested: false)
        XCTAssertEqual(custom.kind, .custom)
    }

    func testPreviewIsFrozenAndSavedByteForByteWithoutExtraFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var history = LifecycleDiagnosticsHistory()
        let presetID = UUID()
        history.record(presetID: presetID, action: .close, reason: .stillRunning, jobs: [], at: date)
        let snapshot = report(failures: history.failures(for: presetID))
        let preview = try SupportDiagnosticsPreview(report: snapshot)
        history.clear()
        let refreshed = try SupportDiagnosticsPreview(report: report(failures: history.failures(for: presetID)))
        XCTAssertNotEqual(preview.data, refreshed.data)
        XCTAssertTrue(preview.text.contains("stillRunning"))
        let url = directory.appendingPathComponent("report.json")
        try preview.save(to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(preview.text.utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["report.json"])
        XCTAssertEqual(preview.data, try SupportDiagnosticsPreview(report: snapshot).data)
    }

    func testNoPresetExportContainsOnlyAppPermissionsAndEmptyHistory() throws {
        let preview = try SupportDiagnosticsPreview(report: report())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.data) as? [String: Any])
        XCTAssertNil(json["selectedPreset"])
        XCTAssertEqual((json["recentLifecycleFailures"] as? [Any])?.count, 0)
        XCTAssertEqual(json["app"] as? String, "TaskScope")
        XCTAssertEqual(json["version"] as? String, "1.2.3")
        XCTAssertEqual(json["macOS"] as? String, "15.2.1")
    }

    func testCancelledCollectionDoesNotRunCommands() async {
        let harness = DiagnosticsInspectionHarness(results: [])
        let task = Task.detached { [runtime = harness.runtime, preset = Self.privatePreset] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await SupportDiagnosticsCollector(runtime: runtime)
                .inspectPreset(preset, keepOffRequested: false)
        }
        let result = await task.value
        XCTAssertEqual(result.userLaunchAgents.first?.state, .unknown)
        XCTAssertTrue(harness.commands.isEmpty)
    }

    @MainActor
    func testPreviewShowsCompleteExportAndExplicitActions() throws {
        let preview = try SupportDiagnosticsPreview(report: report())
        var closed = false
        let view = SupportDiagnosticsPreviewSheet(preview: preview, onClose: { closed = true })
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: preview.text))
        XCTAssertNoThrow(try inspected.find(button: "Copy JSON"))
        XCTAssertNoThrow(try inspected.find(button: "Save JSON…"))
        try inspected.find(button: "Done").tap()
        XCTAssertTrue(closed)
    }

    @MainActor
    func testAllLifecycleActionsRecordFailuresWithoutRawMessages() async throws {
        let preset = Self.privatePreset
        let lifecycle = diagnosticsLifecycle()
        let manager = ProcessManager(processInventory: ScriptedInventory(processes: []), verificationInventory: ScriptedInventory(processes: []),
                                     processSignaler: FakeSignaler.forbidding("Diagnostics must not signal processes"), lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, now: { self.date }, dependencies: .inert)
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [preset] }
        await manager.openApp(preset)
        await manager.quitMainApp(preset)
        await manager.quitHelpers(preset)
        await manager.quitAllKillable(preset)
        await manager.keepOff(preset)
        let failures = manager.lifecycleDiagnostics.failures(for: preset.id)
        XCTAssertEqual(failures.map(\.action), [.keepOff, .close, .quitHelpers, .quitApp, .open])
        XCTAssertTrue(failures.allSatisfy { $0.reason == .userLaunchAgentFailed && $0.failedJobCount == 1 })
        let preview = try SupportDiagnosticsPreview(report: report(failures: failures))
        XCTAssertFalse(preview.text.contains(Self.secret))
        manager.dismissLifecycleReport()
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: preset.id), failures)
        manager.clearLifecycleDiagnostics()
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)
    }

    @MainActor
    func testEarlyInventoryFailureDoesNotReusePreviousJobReport() async {
        let preset = Self.privatePreset
        let manager = ProcessManager(processInventory: ScriptedInventory(failing: .commandFailed(SupportDiagnosticsTests.secret)),
                                     verificationInventory: ScriptedInventory(failing: .commandFailed(SupportDiagnosticsTests.secret)), processSignaler: FakeSignaler.forbidding("Diagnostics must not signal processes"),
                                     lifecycle: diagnosticsLifecycle(appExists: false), settleAfterProcessChange: {}, dependencies: .inert)
        manager.enableNotifications = false
        // Missing-bundle Open restores overrides without reading inventory.
        manager.dependencies.isPresetKeptOff = { _ in true }
        await manager.openApp(preset)
        await manager.quitAllKillable(preset)
        let failures = manager.lifecycleDiagnostics.failures(for: preset.id)
        XCTAssertEqual(failures.first?.reason, .inventoryUnavailable)
        XCTAssertEqual(failures.first?.failedJobCount, 0)
        XCTAssertEqual(failures.last?.failedJobCount, 1)
    }

    @MainActor
    func testEarlyOpenFailuresHaveUsefulCategoriesWithoutAnExistingReport() async {
        let preset = Self.privatePreset
        let cases: [(FakeLifecycle, LifecycleDiagnosticFailure.Reason)] = [
            (diagnosticsLifecycle(appExists: false), .appBundleMissing),
            (diagnosticsLifecycle(systemServiceFails: true), .systemServiceFailed),
            (diagnosticsLifecycle(fails: false), .launchFailed)
        ]
        for (service, expected) in cases {
            let manager = ProcessManager(processInventory: ScriptedInventory(processes: []), verificationInventory: ScriptedInventory(processes: []),
                                         processSignaler: FakeSignaler.forbidding("Diagnostics must not signal processes"), lifecycle: service,
                                         settleAfterProcessChange: {}, dependencies: .inert)
            manager.enableNotifications = false
            await manager.openApp(preset)
            XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: preset.id).first?.reason, expected)
        }
    }

    @MainActor
    func testSuccessfulAndSkippedActionsDoNotCreateFailuresAndBackgroundIsMarked() async {
        let preset = Self.privatePreset
        let manager = ProcessManager(processInventory: ScriptedInventory(processes: []),
                                     verificationInventory: ScriptedInventory(processes: []), processSignaler: FakeSignaler.forbidding("Diagnostics must not signal processes"),
                                     lifecycle: diagnosticsLifecycle(fails: false), settleAfterProcessChange: {}, dependencies: .inert)
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [preset] }
        await manager.quitAllKillable(preset)
        await manager.keepOff(preset, recordIntent: false)
        XCTAssertTrue(manager.lifecycleDiagnostics.failures(for: preset.id).isEmpty)

        let failing = ProcessManager(processInventory: ScriptedInventory(failing: .commandFailed(SupportDiagnosticsTests.secret)),
                                     verificationInventory: ScriptedInventory(failing: .commandFailed(SupportDiagnosticsTests.secret)), processSignaler: FakeSignaler.forbidding("Diagnostics must not signal processes"),
                                     lifecycle: diagnosticsLifecycle(), settleAfterProcessChange: {}, dependencies: .inert)
        failing.dependencies.isPresetKeptOff = { _ in true }
        await failing.keepOff(preset, recordIntent: false)
        XCTAssertEqual(failing.lifecycleDiagnostics.failures(for: preset.id).first?.backgroundEnforcement, true)
    }

    private func report(
        version: String? = "1.2.3", build: String? = "42",
        selected: SupportDiagnosticsReport.Preset? = nil,
        failures: [LifecycleDiagnosticFailure] = []
    ) -> SupportDiagnosticsReport {
        .init(version: version, build: build,
              macOS: .init(majorVersion: 15, minorVersion: 2, patchVersion: 1),
              architecture: .arm64, capturedAt: date,
              permissions: .init(notifications: .denied, notificationsEnabledInApp: true,
                                 accessibilityGranted: false, launchAtLogin: .requiresApproval),
              selectedPreset: selected, recentLifecycleFailures: failures)
    }

    static let secret = "alice Acme com.acme /Users/alice/Acme.app /bin/tool --token secret-value"
    static let privatePreset = WatchedAppPreset(
        displayName: secret, mainProcessName: secret,
        helperProcessNames: ["PrivateHelper"], protectedProcessNames: ["PrivateDaemon"],
        appPath: "/Users/alice/Acme.app",
        userLaunchAgentJobs: [.init(label: "com.acme.agent", plistPath: "/Users/alice/Acme.plist")],
        systemLaunchDaemonJobs: [.init(label: secret, plistPath: secret, processName: secret)]
    )
}

private final class DiagnosticsInspectionHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ShellCommandResult]
    private var recordedCommands: [ExternalCommand] = []
    private let existingPaths: Set<String>
    private var recordedPathQueries: [String] = []
    var commands: [ExternalCommand] { lock.withLock { recordedCommands } }
    var pathQueries: [String] { lock.withLock { recordedPathQueries } }
    init(results: [ShellCommandResult], existingPaths: Set<String> = []) {
        self.results = results
        self.existingPaths = existingPaths
    }

    var runtime: ProcessLifecycleRuntime {
        .init(userID: 501, fileExists: { [self] path in
            lock.withLock {
                recordedPathQueries.append(path)
                return existingPaths.contains(path)
            }
        }, launchAgentLabel: { _ in nil }, runCommand: { [self] command, timeout in
            XCTAssertEqual(timeout, 5)
            return lock.withLock {
                recordedCommands.append(command)
                return results.isEmpty
                    ? .init(command: command, stdout: "", stderr: "", exitCode: 1)
                    : results.removeFirst()
            }
        }, loadProcessInventory: {
            XCTFail("Diagnostics must not read the process inventory")
            return .success([])
        }, executablePathForPID: { _ in nil }, sendSignal: { _, _ in
            XCTFail("Diagnostics must not signal processes")
            return false
        }, isProcessAlive: { _ in false }, sleep: { _ in XCTFail("Diagnostics must not run lifecycle waits") },
        systemUptime: { 0 }, isAppBundle: { _ in false })
    }
}

/// Every launchd change answers with one job whose label and detail are the
/// secret diagnostics must not export: failed, unless `fails` is false. Daemon
/// checks fail only with `systemServiceFails`. Stops find no process, waits fail,
/// and opening fails.
private func diagnosticsLifecycle(fails: Bool = true, appExists: Bool = true, systemServiceFails: Bool = false) -> FakeLifecycle {
    let batch = LifecycleBatchResult(jobs: [.init(label: SupportDiagnosticsTests.secret, state: fails ? .failed : .changed,
                                                  detail: SupportDiagnosticsTests.secret)])
    let lifecycle = FakeLifecycle.allSucceeding()
    lifecycle.agentsResult = batch
    lifecycle.ensureDaemonsResult = systemServiceFails ? batch : .notNeeded
    lifecycle.terminationOutcome = .noMatchingProcesses
    lifecycle.waitResult = false
    lifecycle.openResult = .failed("Fake launch failed.")
    lifecycle.appExists = appExists
    lifecycle.disconnect = nil
    return lifecycle
}
