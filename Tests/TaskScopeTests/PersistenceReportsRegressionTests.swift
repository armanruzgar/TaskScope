import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class PersistenceReportsRegressionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.PersistenceReports.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testSelectionsRecoverValidEntriesAndResetCommitsThemWithUnknownFields() throws {
        let process = AppProcess(pid: 42, parentPID: 1, uid: 501, cpu: 0, memoryMB: 0,
                                 command: "Example", executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                                 elapsedTime: "00:10", startTime: "fixture", netInKB: nil, netOutKB: nil,
                                 diskReadBytes: nil, diskWriteBytes: nil)
        let selection = SavedSelectionsStore.SavedSelection(name: "Recovered", pids: [42],
                                                            processes: [.init(process: process)])
        var valid = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
        valid["futureSelectionField"] = ["keep": true]
        let rejected: [[String: Any]] = [
            ["id": "not-a-uuid", "name": "Invalid", "pids": [], "processes": []],
            ["name": "Invalid process", "processes": [["pid": 43, "command": NSNull()]]]
        ]
        for (index, invalid) in rejected.enumerated() {
            let key = "selections.\(index)"
            let original = try JSONSerialization.data(withJSONObject: [valid, invalid])
            defaults.set(original, forKey: key)
            let store = SavedSelectionsStore(userDefaults: defaults, key: key)
            XCTAssertTrue(store.isReadOnlyAfterCorruption)
            XCTAssertEqual(store.selections.map(\.id), [selection.id], "Valid selections must remain visible in recovery")
            XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
            XCTAssertEqual(store.resolve(selection, in: [process]).matched.map(\.pid), [42])
            XCTAssertFalse(store.rename(selection, to: "Refused"))
            XCTAssertFalse(store.remove(selection))
            XCTAssertFalse(store.save(name: "Refused", processes: [process]))
            XCTAssertEqual(defaults.data(forKey: key), original)
            store.resetAfterCorruption()
            let reloaded = SavedSelectionsStore(userDefaults: defaults, key: key)
            XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
            XCTAssertEqual(reloaded.selections.map(\.id), [selection.id], "Reset must commit recovered selections")
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [[String: Any]])
            XCTAssertEqual(persisted.first?["futureSelectionField"] as? [String: Bool], ["keep": true])
            XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        }
    }

    @MainActor
    func testWrongPreferenceTypesArePreservedAndRequireResetAcrossStores() throws {
        let foreignValues: [Any] = ["hand-restored JSON", ["foreign": "value"], ["foreign", 42], true, 17]
        for (index, foreign) in foreignValues.enumerated() {
            let keys = ["settings.\(index)", "presets.\(index)", "selections.\(index)", "rules.\(index)", "events.\(index)"]
            for key in keys { defaults.set(foreign, forKey: key) }
            let settings = SettingsStore(userDefaults: defaults, key: keys[0])
            let presets = WatchedAppsStore(userDefaults: defaults, key: keys[1])
            let selections = SavedSelectionsStore(userDefaults: defaults, key: keys[2])
            let rules = AutoStopRulesStore(userDefaults: defaults, key: keys[3], eventsKey: keys[4],
                                           inventory: ReportsInventory())
            XCTAssertTrue(settings.isReadOnlyAfterCorruption, "Wrong-type settings must enter recovery")
            XCTAssertTrue(presets.isReadOnlyAfterCorruption, "Wrong-type presets must not seed defaults")
            XCTAssertTrue(selections.isReadOnlyAfterCorruption)
            XCTAssertNotNil(rules.rulesRecoveryMessage)
            XCTAssertNotNil(rules.eventsRecoveryMessage)
            XCTAssertTrue(rules.isRulesReadOnlyAfterRecovery)
            XCTAssertTrue(rules.isEventsReadOnlyAfterRecovery)
            settings.enableNotifications = true
            XCTAssertFalse(presets.add(.globalProtect))
            XCTAssertFalse(selections.remove(at: []))
            for key in keys {
                XCTAssertEqual(defaults.object(forKey: key) as? NSObject, foreign as? NSObject,
                               "The primary value must remain untouched until reset: \(key)")
                let backup = try XCTUnwrap(defaults.data(forKey: "\(key).corruptBackup"), "Missing foreign-object backup: \(key)")
                let restored = try PropertyListSerialization.propertyList(from: backup, format: nil)
                XCTAssertEqual(restored as? NSObject, foreign as? NSObject)
            }
            settings.resetAfterCorruption()
            presets.resetAfterCorruption()
            selections.resetAfterCorruption()
            XCTAssertFalse(SettingsStore(userDefaults: defaults, key: keys[0]).isReadOnlyAfterCorruption)
            XCTAssertFalse(WatchedAppsStore(userDefaults: defaults, key: keys[1]).isReadOnlyAfterCorruption)
            XCTAssertFalse(SavedSelectionsStore(userDefaults: defaults, key: keys[2]).isReadOnlyAfterCorruption)
        }
    }

    @MainActor
    func testForeignBackupSlotsAreNeverOverwrittenAndExhaustionStaysReadOnly() {
        let key = "foreign.slots"
        defaults.set("foreign primary", forKey: key)
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            defaults.set("earlier \(slot)", forKey: slot == 1 ? "\(key).corruptBackup" : "\(key).corruptBackup.\(slot)")
        }
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.string(forKey: key), "foreign primary")
        XCTAssertTrue(store.persistenceIssue?.contains("could not be backed up") == true)
        XCTAssertEqual(defaults.string(forKey: "\(key).corruptBackup"), "earlier 1")
        XCTAssertEqual(defaults.string(forKey: "\(key).corruptBackup.10"), "earlier 10")
    }

    @MainActor
    func testAllRejectedPresetsCannotExportAnEmptyRecoveryArchive() throws {
        var invalid = WatchedAppPreset(displayName: "Invalid", mainProcessName: "Example",
                                       helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Example.app")
        invalid.helperProcessNames = ["one,two"]
        let invalidObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid))
        for (index, array) in [[NSNull(), 42] as [Any], [invalidObject]].enumerated() {
            let key = "rejected.presets.\(index)"
            let original = try JSONSerialization.data(withJSONObject: array)
            defaults.set(original, forKey: key)
            let store = WatchedAppsStore(userDefaults: defaults, key: key)
            XCTAssertTrue(store.isReadOnlyAfterCorruption)
            XCTAssertTrue(store.presets.isEmpty)
            XCTAssertFalse(store.canExportPresets, "An all-rejected payload has no trustworthy presets to export")
            XCTAssertThrowsError(try store.encodedPresetArchive())
            XCTAssertFalse(store.persistenceIssue?.contains("export the recovered presets") == true)
            XCTAssertTrue(store.persistenceIssue?.contains("No presets could be recovered") == true)
            XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        }
    }

    @MainActor
    func testPartialRecoveryExportsOnlyRecoveredPresetsAndReadableEmptyListsStillExport() throws {
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchedAppPreset.globalProtect))
        defaults.set(try JSONSerialization.data(withJSONObject: [valid, NSNull()]), forKey: "partial.presets")
        let partial = WatchedAppsStore(userDefaults: defaults, key: "partial.presets")
        XCTAssertTrue(partial.canExportPresets)
        XCTAssertEqual(try WatchedAppsStore.decodePresetArchive(partial.encodedPresetArchive()).count, 1)
        XCTAssertTrue(partial.persistenceIssue?.contains("Rejected presets are excluded from export") == true)
        defaults.set(Data("[]".utf8), forKey: "empty.presets")
        let empty = WatchedAppsStore(userDefaults: defaults, key: "empty.presets")
        XCTAssertTrue(empty.canExportPresets)
        XCTAssertTrue(try WatchedAppsStore.decodePresetArchive(empty.encodedPresetArchive()).isEmpty)
    }

    @MainActor
    func testDiagnosticsPreviewExportsNullSettingsDuringRecoveryEvenAfterInMemoryChanges() async throws {
        for changed in [false, true] {
            let key = "diagnostics.settings.\(changed)"
            defaults.set(Data("unreadable".utf8), forKey: key)
            let settings = SettingsStore(userDefaults: defaults, key: key)
            settings.keepGlobalProtectOff = changed
            settings.enableNotifications = changed
            let completed = expectation(description: "Preview created")
            let view = SupportDiagnosticsView(
                settings: settings, watchedApps: WatchedAppsStore(userDefaults: defaults, key: "diagnostics.presets"),
                processManager: makeManager(), collector: .init(runtime: Self.inspectionRuntime),
                collectPermissions: { enabled in
                    .init(notifications: .denied, notificationsEnabledInApp: enabled,
                          accessibilityGranted: false, launchAtLogin: .off)
                },
                makePreview: { report in
                    let preview = try SupportDiagnosticsPreview(report: report)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.data) as? [String: Any])
                    XCTAssertEqual(json["schemaVersion"] as? Int, 2)
                    let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
                    let preset = try XCTUnwrap(json["selectedPreset"] as? [String: Any])
                    XCTAssertTrue(permissions["notificationsEnabledInApp"] is NSNull, "Unreadable notification preference must encode null")
                    XCTAssertTrue(preset["keepOffRequested"] is NSNull, "Unreadable saved Keep Off intent must encode null")
                    XCTAssertFalse(preview.text.contains("private-fixture"))
                    completed.fulfill()
                    return preview
                }, selectedPresetID: WatchedAppPreset.globalProtect.id
            )
            try view.inspect().find(button: "Preview Diagnostics").tap()
            await fulfillment(of: [completed], timeout: 5)
        }
    }

    @MainActor
    func testDiagnosticsPreviewRetainsReadableSettingsBooleans() async throws {
        let settings = SettingsStore(userDefaults: defaults, key: "readable.settings")
        settings.keepGlobalProtectOff = true
        settings.enableNotifications = true
        let completed = expectation(description: "Readable preview created")
        let view = SupportDiagnosticsView(
            settings: settings, watchedApps: WatchedAppsStore(userDefaults: defaults, key: "readable.presets"),
            processManager: makeManager(), collector: .init(runtime: Self.inspectionRuntime),
            collectPermissions: { enabled in
                .init(notifications: .allowed, notificationsEnabledInApp: enabled,
                      accessibilityGranted: false, launchAtLogin: .off)
            }, makePreview: { report in
                XCTAssertEqual(report.permissions.notificationsEnabledInApp, true)
                XCTAssertEqual(report.selectedPreset?.keepOffRequested, true)
                completed.fulfill()
                return try SupportDiagnosticsPreview(report: report)
            }, selectedPresetID: WatchedAppPreset.globalProtect.id
        )
        try view.inspect().find(button: "Preview Diagnostics").tap()
        await fulfillment(of: [completed], timeout: 5)
    }

    func testDiagnosticsActionAndReasonRawValuesMatchTheExportContract() throws {
        let actions = LifecycleDiagnosticFailure.Action.allCases
        let reasons = LifecycleDiagnosticFailure.Reason.allCases
        XCTAssertEqual(actions.map(\.rawValue), ["open", "quitApp", "quitHelpers", "close", "keepOff", "allowToRun"])
        XCTAssertEqual(reasons.map(\.rawValue), ["disconnectFailed", "incomplete", "appBundleMissing", "inventoryUnavailable",
                                               "systemServiceFailed", "userLaunchAgentFailed", "launchFailed",
                                               "signalRejected", "verificationUnavailable", "stillRunning"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(actions)) as? [String], actions.map(\.rawValue))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reasons)) as? [String], reasons.map(\.rawValue))
    }

    @MainActor
    func testQuitAllDisconnectFailureIsExportedWithoutRawDetails() async throws {
        let manager = makeManager()
        await manager.quitAll(.globalProtect)
        let failures = manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtect.id)
        XCTAssertEqual(failures.map(\.reason), [.disconnectFailed])
        XCTAssertEqual(failures.map(\.action), [.keepOff])
        let preview = try SupportDiagnosticsPreview(report: .init(
            version: "1.0.0", build: "3", macOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            capturedAt: Date(timeIntervalSince1970: 1_000),
            permissions: .init(notifications: .denied, notificationsEnabledInApp: false,
                               accessibilityGranted: false, launchAtLogin: .off),
            selectedPreset: await SupportDiagnosticsCollector(runtime: Self.inspectionRuntime)
                .inspectPreset(.globalProtect, keepOffRequested: false),
            recentLifecycleFailures: failures
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: preview.data) as? [String: Any])
        let exported = try XCTUnwrap(json["recentLifecycleFailures"] as? [[String: Any]])
        XCTAssertEqual(exported.first?["reason"] as? String, "disconnectFailed")
        XCTAssertFalse(preview.text.contains("private-fixture"))
    }

    func testHealthFollowsSymlinkedPlistInfoAndExecutableFiles() async throws {
        let fixture = try makePathFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for relative in ["agent.plist", "Example.app/Contents/Info.plist", "Example.app/Contents/MacOS/Example"] {
            let original = fixture.directory.appendingPathComponent(relative)
            let target = original.appendingPathExtension("target")
            try FileManager.default.moveItem(at: original, to: target)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        }
        let report = await healthRuntime().collect(.init(presets: [fixture.preset], presetsReadable: true, notificationsEnabled: true))
        XCTAssertEqual(report.findings.first { $0.category == .presetPaths }?.state, .healthy,
                       "Valid symlink targets must verify for app metadata, executable and launch plist")
    }

    func testHealthTreatsDanglingSymlinksAsMissingForOptionalAndRequiredPaths() async throws {
        let fixture = try makePathFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let job = fixture.directory.appendingPathComponent("agent.plist")
        try FileManager.default.removeItem(at: job)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: fixture.directory.appendingPathComponent("missing.plist"))
        var preset = fixture.preset
        for required in [true, false] {
            preset.userLaunchAgentJobs[0].isRequired = required
            let report = await healthRuntime().collect(.init(presets: [preset], presetsReadable: true, notificationsEnabled: true))
            XCTAssertEqual(report.findings.first { $0.category == .presetPaths }?.state, required ? .stale : .healthy,
                           "Dangling plist symlinks must have missing-path semantics")
        }
        let executable = fixture.directory.appendingPathComponent("Example.app/Contents/MacOS/Example")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: fixture.directory.appendingPathComponent("missing-executable"))
        let report = await healthRuntime().collect(.init(presets: [preset], presetsReadable: true, notificationsEnabled: true))
        XCTAssertEqual(report.findings.first { $0.category == .presetPaths }?.state, .stale)
    }

    func testHealthRejectsSymlinksToNonregularFilesWithoutBlocking() async throws {
        let fixture = try makePathFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fifo = fixture.directory.appendingPathComponent("fixture-fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let job = fixture.directory.appendingPathComponent("agent.plist")
        try FileManager.default.removeItem(at: job)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: fifo)
        let report = await healthRuntime().collect(.init(presets: [fixture.preset], presetsReadable: true, notificationsEnabled: true))
        XCTAssertEqual(report.findings.first { $0.category == .presetPaths }?.state, .unverified)
    }

    func testCompatibilitySelfCheckPreservesLongTaskScopeBuildNumbers() async {
        for build in ["1000000", "2026101601", "100000000000000000000", String(repeating: "1", count: 64)] {
            let runtime = compatibilityRuntime(build: build)
            let report = await GlobalProtectCompatibilityChecker(runtime: runtime).check(keepOffRequested: nil)
            XCTAssertEqual(report.taskScopeBuild, build, "TaskScope build numbers need their own numeric validator")
            XCTAssertTrue(report.redactedSummary.contains("TaskScope: 1.0.0 (build \(build))"))
            XCTAssertEqual(report.globalProtectBuild, "Unavailable (unrecognized value redacted)")
        }
    }

    func testCompatibilitySelfCheckStillRedactsInvalidTaskScopeBuildMetadata() async {
        for build in ["0", "01", "1.2", "private-fixture", "1234567\nprivate-fixture", String(repeating: "1", count: 65)] {
            let report = await GlobalProtectCompatibilityChecker(runtime: compatibilityRuntime(build: build)).check(keepOffRequested: nil)
            XCTAssertEqual(report.taskScopeBuild, "Unavailable (unrecognized value redacted)")
        }
    }

    @MainActor
    private func makeManager() -> ProcessManager {
        let manager = ProcessManager(processInventory: ReportsInventory(), verificationInventory: ReportsInventory(),
                                     processSignaler: ReportsSignaler(), lifecycle: ReportsLifecycle(), settleAfterProcessChange: {})
        manager.enableNotifications = false
        return manager
    }

    private static var inspectionRuntime: ProcessLifecycleRuntime {
        .init(userID: 501, fileExists: { _ in false }, launchAgentLabel: { _ in nil },
              runCommand: { _, _ in .init(command: "private-fixture", stdout: "", stderr: "private-fixture", exitCode: 1) },
              loadProcessInventory: { XCTFail("Unexpected inventory read"); return .success([]) },
              executablePathForPID: { _ in nil }, sendSignal: { _, _ in XCTFail("Unexpected signal"); return false },
              isProcessAlive: { _ in false }, sleep: { _ in XCTFail("Unexpected wait") }, systemUptime: { 0 })
    }

    private func healthRuntime() -> InstallationHealthRuntime {
        .init(permissions: { .init(notificationsAvailable: false, notifications: .unknown, accessibilityTrusted: false, loginItem: .notFound) },
              bundle: { .init(identity: .healthy, identityDetail: "Fixture", signature: .unsigned, metadata: .unavailable) },
              paths: { InstallationHealthProbe.inspectPaths($0) }, recoveries: { [] }, now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func makePathFixture() throws -> (directory: URL, preset: WatchedAppPreset) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TaskScope.PersistenceReports.\(UUID().uuidString)")
        let app = directory.appendingPathComponent("Example.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture only; never executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"], format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let job = directory.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture.agent"], format: .binary, options: 0).write(to: job)
        return (directory, WatchedAppPreset(displayName: "Fixture", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [],
                                            appPath: app.path, userLaunchAgentJobs: [.init(label: "fixture.agent", plistPath: job.path)]))
    }

    private func compatibilityRuntime(build: String) -> GlobalProtectCompatibilityRuntime {
        .init(userID: 501, inspectPlist: { _ in .missing },
              runProbe: { _ in .init(command: "fixture", stdout: "", stderr: "", exitCode: 1) },
              loadInventory: { .success([]) }, versions: { ("1.0.0", build, "6.3.3", "1234567") },
              now: { Date(timeIntervalSince1970: 1_000) })
    }
}

private struct ReportsInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> { .success([]) }
}

private struct ReportsSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { XCTFail("Unexpected signal"); return false }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct ReportsLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { false }
    func openAppBundle(at path: String) async -> Bool { XCTFail("Unexpected app launch"); return false }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult { .failed("private-fixture disconnect detail") }
}
