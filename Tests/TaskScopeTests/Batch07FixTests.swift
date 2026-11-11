import Foundation
import ViewInspector
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

private func batch07Process(
    pid: Int32,
    command: String,
    executablePath: String?,
    startTime: String = ""
) -> AppProcess {
    AppProcess(
        pid: pid,
        parentPID: 1,
        cpu: 0,
        memoryMB: 0,
        command: command,
        executablePath: executablePath,
        elapsedTime: "00:10",
        startTime: startTime,
        netInKB: nil,
        netOutKB: nil,
        diskReadBytes: nil,
        diskWriteBytes: nil
    )
}

private func batch07Preset(
    name: String,
    main: String? = nil,
    appPath: String? = nil
) -> WatchedAppPreset {
    WatchedAppPreset(
        displayName: name,
        mainProcessName: main ?? "\(name)Process",
        helperProcessNames: [],
        protectedProcessNames: [],
        appPath: appPath ?? "/Batch07Apps/\(name).app"
    )
}

private func batch07JSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

/// A minimal app bundle on disk: `Contents/Info.plist` and an executable file
/// that is never run.
private func batch07MakeBundle(named name: String, executable: String, in directory: URL) throws -> URL {
    let bundle = directory.appendingPathComponent(name, isDirectory: true)
    let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleExecutable": executable,
        "CFBundleIdentifier": "test.batch07.\(UUID().uuidString)",
        "CFBundlePackageType": "APPL"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    try Data("fixture only; never executed".utf8).write(to: macOS.appendingPathComponent(executable))
    return bundle
}

// MARK: - Watched-app presets

@MainActor
final class Batch07WatchedAppsStoreTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    nonisolated(unsafe) private var directories: [URL] = []
    private let key = "batch07-presets"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07WatchedAppsStoreTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // L02-3 (A09-2): the configured path is stored and followed at use.
    func testAPresetKeepsTheLinkItWasGivenAndFollowsTheLinkWhenItMoves() throws {
        let directory = try makeDirectory()
        let real = try batch07MakeBundle(named: "Real.app", executable: "RealTool", in: directory)
        let link = directory.appendingPathComponent("Tool.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = makeStore()

        XCTAssertTrue(store.add(batch07Preset(name: "Tool", main: "RealTool", appPath: link.path)), store.validationError ?? "")
        let saved = try XCTUnwrap(store.presets.last)
        XCTAssertEqual(saved.appPath, link.standardizedFileURL.path)
        XCTAssertEqual(saved.resolvedAppPath, AutoStopRuleValidation.canonicalPath(real.path))
        XCTAssertEqual(saved.mainExecutableDirectory, AutoStopRuleValidation.canonicalPath(real.path) + "/Contents/MacOS/")

        // A newer copy behind the same link: matching follows it, nothing stored changes.
        let newer = try batch07MakeBundle(named: "Real 2.app", executable: "RealTool", in: directory)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: newer)
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertNil(reloaded.persistenceIssue)
        XCTAssertEqual(reloaded.presets.last, saved)
        XCTAssertEqual(reloaded.presets.last?.resolvedAppPath, AutoStopRuleValidation.canonicalPath(newer.path))
        XCTAssertEqual(WatchedAppPreset.globalProtect.resolvedAppPath, "/Applications/GlobalProtect.app")
    }

    // L02-3 (a) and L05-5: a `*.app` link must lead to an app bundle.
    func testALinkToSomethingOtherThanAnAppBundleIsRefusedButNeverLocksTheStore() throws {
        let directory = try makeDirectory()
        let versioned = try batch07MakeBundle(named: "Tool-1.2.3", executable: "Tool", in: directory)
        let script = directory.appendingPathComponent("tool.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        let plainFolder = directory.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        var links: [URL] = []
        for (name, target) in [("Versioned.app", versioned), ("Script.app", script), ("Folder.app", plainFolder)] {
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            links.append(link)
        }
        let store = makeStore()

        for link in links {
            let preset = batch07Preset(name: link.lastPathComponent, main: "Tool", appPath: link.path)
            XCTAssertFalse(store.add(preset), link.path)
            XCTAssertTrue(store.validationError?.contains("must lead to an app bundle") == true, store.validationError ?? link.path)
            XCTAssertTrue(store.previewImport([preset]).items[0].rejectionReason?.contains("must lead to an app bundle") == true)
            // Open checks the target again when it runs.
            XCTAssertFalse(SystemProcessLifecycleService.isAppBundle(at: link.path), link.path)
        }
        XCTAssertEqual(store.presets.map(\.id), [WatchedAppPreset.globalProtectID])
        // A folder named .app without a bundle inside is not opened either.
        let emptyFolder = directory.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        XCTAssertFalse(SystemProcessLifecycleService.isAppBundle(at: emptyFolder.path))
        let good = try batch07MakeBundle(named: "Good.app", executable: "Good", in: directory)
        XCTAssertTrue(SystemProcessLifecycleService.isAppBundle(at: good.path))
        let goodLink = directory.appendingPathComponent("Good Link.app")
        try FileManager.default.createSymbolicLink(at: goodLink, withDestinationURL: good)
        XCTAssertTrue(SystemProcessLifecycleService.isAppBundle(at: goodLink.path))
        XCTAssertTrue(store.add(batch07Preset(name: "Good", main: "Good", appPath: goodLink.path)), store.validationError ?? "")

        // Saved before its link was re-pointed (or by an older build), a preset
        // still loads: what is on disk now never puts the store into recovery.
        defaults.set(
            try JSONEncoder().encode([.globalProtect, batch07Preset(name: "Versioned", main: "Tool", appPath: links[0].path)]),
            forKey: key
        )
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertNil(reloaded.persistenceIssue)
        XCTAssertEqual(reloaded.presets.count, 2)
    }

    // L02-3 (b): a link created later between two presets.
    func testALinkCreatedLaterBetweenTwoPresetsDoesNotLockTheStore() throws {
        let directory = try makeDirectory()
        let real = try batch07MakeBundle(named: "Real.app", executable: "RealTool", in: directory)
        let alias = directory.appendingPathComponent("Alias.app")
        let store = makeStore()
        XCTAssertTrue(store.add(batch07Preset(name: "Real", main: "RealTool", appPath: real.path)), store.validationError ?? "")
        XCTAssertTrue(store.add(batch07Preset(name: "Alias", main: "AliasTool", appPath: alias.path)), store.validationError ?? "")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertNil(reloaded.persistenceIssue)
        XCTAssertEqual(reloaded.presets.map(\.displayName), ["GlobalProtect", "Real", "Alias"])

        // A new preset that reaches the same bundle through another link is
        // still refused when it is added.
        let second = directory.appendingPathComponent("Second.app")
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: real)
        XCTAssertFalse(reloaded.add(batch07Preset(name: "Second", main: "SecondTool", appPath: second.path)))
        XCTAssertEqual(reloaded.validationError, "The preset “Real” already watches this app path.")
    }

    // A13-1: archives and the store are bounded by preset count.
    func testPresetArchivesAddAndImportAreBoundedByPresetCount() throws {
        func archive(_ count: Int, envelope: Bool) throws -> Data {
            let presets = (0..<count).map {
                ["displayName": "P\($0)", "mainProcessName": "P\($0)", "appPath": "/Batch07Apps/P\($0).app"]
            }
            let object: Any = envelope ? ["schemaVersion": 1, "presets": presets] as [String: Any] : presets
            return try JSONSerialization.data(withJSONObject: object)
        }
        for envelope in [true, false] {
            XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(archive(201, envelope: envelope))) {
                XCTAssertEqual($0 as? WatchedAppsStore.PresetArchiveError, .exceedsMaximumCount)
            }
        }
        XCTAssertEqual(
            WatchedAppsStore.PresetArchiveError.exceedsMaximumCount.errorDescription,
            "Preset archives may contain at most 200 presets."
        )

        let store = makeStore()
        let candidates = try WatchedAppsStore.decodePresetArchive(archive(200, envelope: true))
        XCTAssertEqual(candidates.count, 200)
        let preview = store.previewImport(candidates)
        XCTAssertEqual(preview.importableCount, 199, "the built-in preset already takes one place")
        XCTAssertEqual(preview.items.last?.rejectionReason, WatchedAppsStore.presetLimitMessage)
        XCTAssertEqual(store.importPresets(candidates), .init(importedCount: 199, rejectedCount: 1))
        XCTAssertEqual(store.presets.count, WatchedAppsStore.maximumPresetCount)
        XCTAssertFalse(store.add(batch07Preset(name: "Extra")))
        XCTAssertEqual(store.validationError, WatchedAppsStore.presetLimitMessage)
    }

    // A13-1: lists saved before the limit existed still load in full.
    func testStoredPresetsBeyondTheLimitStillLoadWithoutRecovery() throws {
        let stored = (0..<205).map { batch07Preset(name: "Stored \($0)") }
        defaults.set(try JSONEncoder().encode(stored), forKey: key)
        let store = makeStore()
        XCTAssertEqual(store.presets.count, 205)
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        XCTAssertFalse(store.add(batch07Preset(name: "Extra")))
        XCTAssertTrue(store.remove(try XCTUnwrap(store.presets.first)))
    }

    // L05-2: GlobalProtect's jobs and service name belong to the built-in preset.
    func testCustomPresetsCannotUseGlobalProtectAgentsOrItsServiceName() throws {
        let store = makeStore()
        var byLabel = batch07Preset(name: "Zoom", main: "zoom.us")
        byLabel.userLaunchAgentJobs = [UserLaunchAgentJob(label: "COM.paloaltonetworks.gp.pangps", plistPath: "/Users/Shared/zoom.plist")]
        var byPath = batch07Preset(name: "Other", main: "Other")
        byPath.userLaunchAgentJobs = [UserLaunchAgentJob(label: "us.zoom.agent", plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist")]
        var byDaemonLabel = batch07Preset(name: "Daemon", main: "Daemon")
        byDaemonLabel.userLaunchAgentJobs = [UserLaunchAgentJob(label: "com.paloaltonetworks.gp.pangpsd", plistPath: "/Users/Shared/daemon.plist")]
        var byHelper = batch07Preset(name: "Helper", main: "Helper", appPath: "/Batch07Apps/GlobalProtect Copy.app")
        byHelper.helperProcessNames = ["PanGPS"]

        let reason = "reserved for the built-in GlobalProtect preset"
        for preset in [byLabel, byPath, byDaemonLabel, byHelper] {
            XCTAssertFalse(store.add(preset), preset.displayName)
            XCTAssertTrue(store.validationError?.contains(reason) == true, store.validationError ?? preset.displayName)
            XCTAssertTrue(store.previewImport([preset]).items[0].rejectionReason?.contains(reason) == true)
        }

        // A stored look-alike is rejected at load like any invalid preset, with
        // the payload backed up; the built-in preset keeps its agents.
        let payload = try JSONEncoder().encode([WatchedAppPreset.globalProtect, byLabel])
        defaults.set(payload, forKey: key)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.presets, [.globalProtect])
        XCTAssertTrue(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), payload)
    }

    // A09-5: different bundles may share a main process name.
    func testPresetsForDifferentBundlesMayShareAMainProcessName() throws {
        let store = makeStore()
        XCTAssertTrue(store.add(batch07Preset(name: "JDownloader2", main: "JavaApplicationStub")))
        XCTAssertTrue(store.add(batch07Preset(name: "OpenRocket", main: "JavaApplicationStub")), store.validationError ?? "")
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.presets.map(\.displayName), ["GlobalProtect", "JDownloader2", "OpenRocket"])

        // Collisions name the field and the preset that already has it.
        XCTAssertFalse(store.add(batch07Preset(name: "jdownloader2", main: "Other", appPath: "/Batch07Apps/Other.app")))
        XCTAssertEqual(store.validationError, "A preset named “JDownloader2” already exists.")
        XCTAssertFalse(store.add(batch07Preset(name: "Other", main: "Other", appPath: "/batch07apps/OPENROCKET.app")))
        XCTAssertEqual(store.validationError, "The preset “OpenRocket” already watches this app path.")
    }

    // A09-5: notifications keep two presets that share a process name apart.
    func testNotificationNamesKeepPresetsThatShareAProcessNameApart() {
        let first = batch07Preset(name: "JDownloader2", main: "JavaApplicationStub")
        let second = batch07Preset(name: "OpenRocket", main: "JavaApplicationStub")
        let firstRunning = WatchedAppSnapshot(preset: first, runningNames: ["JavaApplicationStub"])
        let secondIdle = WatchedAppSnapshot(preset: second, runningNames: [])
        let secondRunning = WatchedAppSnapshot(preset: second, runningNames: ["JavaApplicationStub"])

        XCTAssertEqual(ProcessManager.notificationNames(for: [firstRunning, secondIdle]), ["JDownloader2: JavaApplicationStub"])
        XCTAssertEqual(
            ProcessManager.notificationNames(for: [firstRunning, secondRunning]),
            ["JDownloader2: JavaApplicationStub", "OpenRocket: JavaApplicationStub"]
        )
        // A name that only one preset lists keeps its plain form.
        XCTAssertEqual(
            ProcessManager.notificationNames(for: [WatchedAppSnapshot(preset: .globalProtect, runningNames: ["PanGPA"])]),
            ["PanGPA"]
        )
    }

    // T04-8: each duplicate rule, and the required names, on their own.
    func testEachDuplicateRuleAndTheRequiredNamesAreEnforcedOnTheirOwn() {
        let store = makeStore()
        XCTAssertTrue(store.add(batch07Preset(name: "Alpha", main: "AlphaMain", appPath: "/Batch07Apps/Alpha.app")))

        XCTAssertFalse(store.add(batch07Preset(name: "Beta", main: "BetaMain", appPath: "/batch07apps/ALPHA.app")))
        XCTAssertEqual(store.validationError, "The preset “Alpha” already watches this app path.")
        XCTAssertFalse(store.add(batch07Preset(name: "ALPHA", main: "GammaMain", appPath: "/Batch07Apps/Gamma.app")))
        XCTAssertEqual(store.validationError, "A preset named “Alpha” already exists.")
        XCTAssertTrue(store.add(batch07Preset(name: "Delta", main: "alphamain", appPath: "/Batch07Apps/Delta.app")))

        for (display, main) in [("", "Main"), ("Name", ""), ("   ", "Main"), ("Name", "  ")] {
            let preset = batch07Preset(name: display, main: main, appPath: "/Batch07Apps/Required.app")
            XCTAssertFalse(store.add(preset))
            XCTAssertEqual(store.validationError, "Display name and main process name are required.")
            XCTAssertEqual(
                store.previewImport([preset]).items[0].rejectionReason,
                "Display name and main process name are required."
            )
            XCTAssertEqual(store.importPresets([preset]), .init(importedCount: 0, rejectedCount: 1))
        }
        XCTAssertEqual(store.presets.map(\.displayName), ["GlobalProtect", "Alpha", "Delta"])
    }

    // T04-4: every mutation is refused in recovery mode.
    func testRecoveryModeRefusesUpdateMoveAndImportWithoutTouchingStorage() throws {
        var invalid = batch07Preset(name: "Invalid")
        invalid.appPath = "relative/Invalid.app"
        let payload = try JSONEncoder().encode([batch07Preset(name: "First"), batch07Preset(name: "Second"), invalid])
        defaults.set(payload, forKey: key)
        let store = makeStore()
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        let recovered = store.presets
        XCTAssertEqual(recovered.map(\.displayName), ["First", "Second"])
        guard recovered.count == 2 else { return }

        var edited = recovered[0]
        edited.notificationsEnabled = false
        XCTAssertFalse(store.update(edited))
        XCTAssertEqual(store.validationError, "Preset data is in recovery mode; reset presets before making changes.")
        XCTAssertFalse(store.move(from: IndexSet(integer: 0), to: 2))
        XCTAssertFalse(store.remove(recovered[1]))
        XCTAssertEqual(store.presets, recovered)

        let candidates = [batch07Preset(name: "New"), batch07Preset(name: "Newer")]
        let preview = store.previewImport(candidates)
        XCTAssertEqual(preview.items.map(\.rejectionReason), Array(repeating: "Preset storage is in recovery mode.", count: 2))
        XCTAssertEqual(preview.importableCount, 0)
        XCTAssertEqual(store.importPresets(candidates), .init(importedCount: 0, rejectedCount: 2))
        XCTAssertEqual(store.presets, recovered)
        XCTAssertEqual(defaults.data(forKey: key), payload)
    }

    // L06-10: a preset with a newer build's fields is read-only, per preset.
    func testAPresetWithANewerBuildsFieldsIsReadOnlyWhileTheRestStayEditable() throws {
        var future = try batch07JSONObject(batch07Preset(name: "Future"))
        future["futureScope"] = ["session": "only"]
        var agentPreset = batch07Preset(name: "Agent")
        agentPreset.userLaunchAgentJobs = [UserLaunchAgentJob(label: "com.example.agent", plistPath: "/Users/Shared/agent.plist")]
        var futureJob = try batch07JSONObject(agentPreset)
        var jobs = try XCTUnwrap(futureJob["userLaunchAgentJobs"] as? [[String: Any]])
        jobs[0]["futureJobScope"] = "gui"
        futureJob["userLaunchAgentJobs"] = jobs
        // Builds before 1.0 stored `priority`; it is retired, not a newer build's field.
        var retired = try batch07JSONObject(batch07Preset(name: "Retired"))
        retired["priority"] = 0
        try seed([future, futureJob, retired])

        let store = makeStore()
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        let loaded = store.presets
        XCTAssertEqual(loaded.map(\.hasUnknownFields), [true, true, false])
        guard loaded.count == 3 else { return }
        let (futureLoaded, agentLoaded, retiredLoaded) = (loaded[0], loaded[1], loaded[2])

        var edited = futureLoaded
        edited.notificationsEnabled = false
        XCTAssertFalse(store.update(edited))
        XCTAssertEqual(store.validationError, WatchedAppsStore.newerBuildMessage)
        // A copy without the unknown fields cannot replace or remove it either.
        let known = batch07Preset(name: "Future")
        let fabricated = WatchedAppPreset(
            id: futureLoaded.id, displayName: known.displayName, mainProcessName: known.mainProcessName,
            helperProcessNames: [], protectedProcessNames: [], appPath: known.appPath
        )
        XCTAssertFalse(fabricated.hasUnknownFields)
        XCTAssertFalse(store.update(fabricated))
        XCTAssertFalse(store.remove(fabricated))
        XCTAssertFalse(store.remove(agentLoaded))
        XCTAssertEqual(store.presets, loaded)

        var retiredEdit = retiredLoaded
        retiredEdit.notificationsEnabled = false
        XCTAssertTrue(store.update(retiredEdit))
        XCTAssertTrue(store.move(from: IndexSet(integer: 2), to: 0))
        let saved = try rows()
        XCTAssertEqual(saved.map { $0["displayName"] as? String }, ["Retired", "Future", "Agent"])
        guard saved.count == 3 else { return }
        XCTAssertEqual(saved[0]["priority"] as? Int, 0)
        XCTAssertEqual(saved[0]["notificationsEnabled"] as? Bool, false)
        XCTAssertEqual(saved[1]["futureScope"] as? NSDictionary, ["session": "only"] as NSDictionary)
        XCTAssertEqual((saved[2]["userLaunchAgentJobs"] as? [[String: Any]])?.first?["futureJobScope"] as? String, "gui")

        // Shortcuts never offer them, and an import cannot bring one in.
        let catalogIDs = WatchedPresetCatalog(key: key, objectForKey: defaults.objectReader).entities().map(\.id)
        XCTAssertEqual(catalogIDs, [retiredLoaded.id])
        let otherStore = WatchedAppsStore(userDefaults: defaults, key: "\(key).other")
        let decoded = try JSONDecoder().decode([WatchedAppPreset].self, from: JSONSerialization.data(withJSONObject: [future]))
        XCTAssertTrue(otherStore.previewImport(decoded).items.first?.rejectionReason?.contains("newer TaskScope build") == true)
    }

    // L06-10: lifecycle actions refuse such a preset before doing anything.
    func testLifecycleActionsRefuseAPresetWithANewerBuildsFields() async throws {
        var future = try batch07JSONObject(batch07Preset(name: "Future"))
        future["futureConfirmation"] = true
        try seed([future])
        let store = makeStore()
        let locked = try XCTUnwrap(store.presets.first)
        XCTAssertTrue(locked.hasUnknownFields)
        let lifecycle = Batch07RecordingLifecycle()
        let signaler = Batch07RecordingSignaler()
        let manager = ProcessManager(
            processInventory: Batch07EmptyInventory(),
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        manager.watchedAppsProvider = { store.presets }
        let copy = WatchedAppPreset(
            id: locked.id, displayName: locked.displayName, mainProcessName: locked.mainProcessName,
            helperProcessNames: [], protectedProcessNames: [], appPath: locked.appPath
        )

        var results: [TaskScopeCommandResult] = []
        results.append(await manager.openApp(locked))
        results.append(await manager.quitMainApp(locked))
        results.append(await manager.quitHelpers(locked))
        results.append(await manager.quitAll(locked))
        results.append(await manager.quitAllKillable(locked))
        results.append(await manager.quitAllKillable(copy))

        XCTAssertEqual(results.count, 6)
        for result in results {
            XCTAssertEqual(result.status, .rejected)
            XCTAssertEqual(result.message, WatchedAppsStore.newerBuildMessage)
        }
        XCTAssertEqual(lifecycle.recordedCalls, [])
        XCTAssertEqual(signaler.recordedSignals, 0)
    }

    // A09-6: export keeps fields that this build does not model.
    func testExportKeepsANewerBuildsFieldsAndImportRefusesToStripThem() throws {
        var future = try batch07JSONObject(batch07Preset(name: "Future"))
        future["futureScope"] = ["uid": 501]
        var retired = try batch07JSONObject(batch07Preset(name: "Retired"))
        retired["priority"] = 3
        try seed([future, retired])
        let store = makeStore()
        XCTAssertTrue(store.add(batch07Preset(name: "Added")))

        let data = try store.encodedPresetArchive()
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(archive["schemaVersion"] as? Int, WatchedAppsStore.PresetArchive.currentSchemaVersion)
        let exported = try XCTUnwrap(archive["presets"] as? [[String: Any]])
        XCTAssertEqual(exported.map { $0["displayName"] as? String }, ["Future", "Retired", "Added"])
        guard exported.count == 3 else { return }
        XCTAssertEqual(exported[0]["futureScope"] as? NSDictionary, ["uid": 501] as NSDictionary)
        XCTAssertEqual(exported[1]["priority"] as? Int, 3)

        // Restoring that file elsewhere refuses the newer build's preset with a
        // reason instead of importing it without its fields.
        let candidates = try WatchedAppsStore.decodePresetArchive(data)
        let restored = WatchedAppsStore(userDefaults: defaults, key: "\(key).restored")
        let preview = restored.previewImport(candidates)
        XCTAssertEqual(preview.items.map(\.isAccepted), [false, true, true])
        XCTAssertTrue(preview.items.first?.rejectionReason?.contains("newer TaskScope build") == true)
    }

    private func makeStore() -> WatchedAppsStore {
        WatchedAppsStore(userDefaults: defaults, key: key)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskScope.Batch07.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func seed(_ presets: [[String: Any]]) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: presets), forKey: key)
    }

    private func rows() throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [[String: Any]])
    }
}

// MARK: - Saved selections

@MainActor
final class Batch07SavedSelectionsTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    private let key = "batch07-selections"
    private let nodePath = "/Batch07/bin/node"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07SavedSelectionsTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // L08-1: each saved and each running path is standardized once.
    func testRecallStandardizesEverySavedAndRunningPathOnlyOnce() {
        let paths = (0..<20).map { "/Batch07/bin/tool\($0)" }
        let saved = paths.enumerated().flatMap { index, path in
            [0, 1].map { copy in
                SavedSelectionsStore.SavedProcess(
                    pid: Int32(100 + index * 2 + copy), command: "tool", executableName: "tool",
                    executablePath: path, startTime: "saved"
                )
            }
        }
        let selection = SavedSelectionsStore.SavedSelection(name: "Many", pids: saved.map(\.pid), processes: saved)
        let running = (0..<100).map { index in
            batch07Process(pid: Int32(1_000 + index), command: "tool", executablePath: paths[index % 20], startTime: "r\(index)")
        }

        var standardizations = 0
        let result = SavedSelectionsStore.resolve(selection, in: running) { path in
            standardizations += 1
            return path
        }
        XCTAssertEqual(standardizations, saved.count + running.count)
        XCTAssertEqual(result.ambiguous.count, saved.count, "five copies run for every two saved ones")
        XCTAssertEqual(result, makeStore().resolve(selection, in: running))
    }

    // L08-1: a legacy entry that claims a process first still excludes it.
    func testALegacyEntryThatClaimsAProcessFirstStillExcludesItFromAPathGroup() {
        let legacy = SavedSelectionsStore.SavedProcess(pid: 1, command: "/Batch07/bin/tool --one", executableName: "tool")
        let pathEntry = SavedSelectionsStore.SavedProcess(
            pid: 2, command: "tool", executableName: "tool", executablePath: "/Batch07/bin/tool", startTime: "gone"
        )
        let selection = SavedSelectionsStore.SavedSelection(name: "Mixed", pids: [1, 2], processes: [legacy, pathEntry])
        let first = batch07Process(pid: 10, command: "/Batch07/bin/tool --one", executablePath: "/Batch07/bin/tool", startTime: "a")
        let second = batch07Process(pid: 11, command: "/Batch07/bin/tool --two", executablePath: "/Batch07/bin/tool", startTime: "b")

        let result = makeStore().resolve(selection, in: [first, second])
        XCTAssertEqual(result.matched.map(\.pid), [10, 11])
        XCTAssertEqual(result.legacyNameMatches, [first.identity])
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    // A11-4: the saved process itself is recognized among more copies.
    func testRecallSelectsTheSavedProcessWhenMoreCopiesOfItsExecutableRun() throws {
        let store = makeStore()
        let running = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        XCTAssertTrue(store.save(name: "One worker", processes: [running[1]]))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [[String: Any]])
        let storedProcesses = try XCTUnwrap(stored.first?["processes"] as? [[String: Any]])
        XCTAssertEqual(storedProcesses.first?["startTime"] as? String, "start-11")

        let selection = try XCTUnwrap(store.selections.first)
        let result = store.resolve(selection, in: running)
        XCTAssertEqual(result.matched.map(\.pid), [11])
        XCTAssertTrue(result.ambiguous.isEmpty)
        XCTAssertTrue(result.unmatched.isEmpty)

        // A process that reused the PID later is not taken for the saved one.
        let recycled = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "later-\($0)") }
        let recycledResult = store.resolve(selection, in: recycled)
        XCTAssertTrue(recycledResult.matched.isEmpty)
        XCTAssertEqual(recycledResult.ambiguous.count, 1)

        // With the original gone and two other copies running, nothing is chosen.
        let others = [20, 21].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        XCTAssertEqual(store.resolve(selection, in: others).ambiguous.count, 1)
    }

    // A11-4: entries saved before start times were kept fall back to the PID.
    func testEntriesSavedWithoutAStartTimeAreRecognizedByTheirPID() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-00000000B007","name":"Legacy","pids":[11],"processes":[{"pid":11,"command":"node","executablePath":"/Batch07/bin/node","executableName":"node"}]}]"#
        defaults.set(Data(json.utf8), forKey: key)
        let store = makeStore()
        let selection = try XCTUnwrap(store.selections.first)
        let entry = try XCTUnwrap(selection.processes.first)
        XCTAssertNil(entry.startTime)
        XCTAssertEqual(entry.id, "/Batch07/bin/node|node|11")

        let running = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        let result = store.resolve(selection, in: running)
        XCTAssertEqual(result.matched.map(\.pid), [11])
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    // A11-5: repeated ids load once, read-only, with the payload backed up.
    func testRepeatedSelectionIDsLoadOnceAndReadOnly() throws {
        let id = UUID()
        let process = SavedSelectionsStore.SavedProcess(pid: 1, command: "node", executableName: "node", executablePath: nodePath)
        let payload = try JSONEncoder().encode([
            SavedSelectionsStore.SavedSelection(id: id, name: "First", pids: [1], processes: [process]),
            SavedSelectionsStore.SavedSelection(id: id, name: "Second", pids: [1], processes: [process])
        ])
        defaults.set(payload, forKey: key)

        let store = makeStore()
        XCTAssertEqual(store.selections.map(\.name), ["First"])
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("duplicate") == true, store.recoveryMessage ?? "")
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), payload)
        let first = try XCTUnwrap(store.selections.first)
        XCTAssertFalse(store.rename(first, to: "Renamed"))
        XCTAssertFalse(store.remove(first))
        XCTAssertEqual(defaults.data(forKey: key), payload)

        store.resetAfterCorruption()
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.selections.map(\.name), ["First"])
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
    }

    // A11-7: names typed now are checked; stored names are left alone.
    func testSelectionNamesRefuseLineBreaksControlBidiCharactersAndLongText() throws {
        let store = makeStore()
        let process = batch07Process(pid: 42, command: "node", executablePath: nodePath)
        let refused = [
            "Line\nbreak", "Line\rbreak", "Line\u{2028}break", "Nul\u{0}name", "Tab\tname",
            "Delete\u{7F}name", "C1\u{85}name", "Override\u{202E}name", "Isolate\u{2066}name",
            String(repeating: "n", count: SavedSelectionsStore.maximumNameLength + 1)
        ]
        for name in refused {
            XCTAssertFalse(store.save(name: name, processes: [process]), name.debugDescription)
            XCTAssertNotNil(store.validationError)
        }
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertTrue(store.save(name: String(repeating: "n", count: SavedSelectionsStore.maximumNameLength), processes: [process]))
        XCTAssertTrue(store.save(name: "Family 👨‍👩‍👧", processes: [process]), store.validationError ?? "")
        XCTAssertTrue(store.save(name: "  Trimmed\n", processes: [process]))
        XCTAssertEqual(store.selections.last?.name, "Trimmed")

        let selection = try XCTUnwrap(store.selections.first { $0.name.hasPrefix("Family") })
        XCTAssertFalse(store.rename(selection, to: "Re\nnamed"))
        XCTAssertFalse(store.rename(selection, to: "Re\u{202D}named"))
        XCTAssertTrue(store.rename(selection, to: "Renamed"))

        // A stored name is not revalidated at load; it stays usable and renameable.
        let stored = SavedSelectionsStore.SavedSelection(name: "Old\nname", pids: [42], processes: [.init(process: process)])
        defaults.set(try JSONEncoder().encode([stored]), forKey: key)
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.selections.map(\.name), ["Old\nname"])
        XCTAssertTrue(reloaded.rename(try XCTUnwrap(reloaded.selections.first), to: "New name"))
    }

    // A11-7: a long stored name cannot push the recall sheet's buttons away.
    func testRecallSheetTitleIsLimitedToTwoLines() throws {
        let name = String(repeating: "Long name ", count: 300)
        let sheet = SavedSelectionRecallSheet(
            selection: .init(name: name, pids: [], processes: []),
            result: .init(matched: [], unmatched: [], ambiguous: [], legacyUnsupported: false),
            onApply: {},
            onCancel: {}
        )
        XCTAssertEqual(try sheet.inspect().find(text: "Recall “\(name)”").lineLimit(), 2)
    }

    private func makeStore() -> SavedSelectionsStore {
        SavedSelectionsStore(userDefaults: defaults, key: key)
    }
}

// MARK: - Settings

@MainActor
final class Batch07SettingsTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    private let key = "batch07-settings"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07SettingsTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // T06-9
    func testAutoRefreshProcessListIsSaved() {
        let store = makeStore()
        XCTAssertFalse(store.autoRefreshProcessList)
        store.autoRefreshProcessList = true
        XCTAssertTrue(makeStore().autoRefreshProcessList)
        store.autoRefreshProcessList = false
        XCTAssertFalse(makeStore().autoRefreshProcessList)
    }

    // T06-9
    func testSearchTextIsCappedAt500CharactersInMemoryStoredAndLoaded() throws {
        let store = makeStore()
        store.searchText = String(repeating: "a", count: 600)
        XCTAssertEqual(store.searchText, String(repeating: "a", count: 500))
        store.flushPendingWrites()
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        XCTAssertEqual((stored["searchText"] as? String)?.count, 500)
        XCTAssertEqual(makeStore().searchText.count, 500)

        let long: [String: Any] = ["schemaVersion": 3, "searchText": String(repeating: "b", count: 700)]
        defaults.set(try JSONSerialization.data(withJSONObject: long), forKey: key)
        XCTAssertEqual(makeStore().searchText, String(repeating: "b", count: 500))
    }

    // A11-8: a payload replaced after launch is never overwritten by a save.
    func testSaveKeepsSettingsThatBecameUnreadableAfterLaunch() throws {
        let store = makeStore()
        store.refreshIntervalSeconds = 22
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        let foreign = Data(#"{"schemaVersion":3,"refreshIntervalSeconds":{"seconds":22}}"#.utf8)
        defaults.set(foreign, forKey: key)

        store.keepGlobalProtectOff = true
        XCTAssertEqual(defaults.data(forKey: key), foreign)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), foreign)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("\(key).corruptBackup") == true, store.recoveryMessage ?? "")
        store.searchText = "later"
        store.flushPendingWrites()
        store.processListLimit = 50
        XCTAssertEqual(defaults.data(forKey: key), foreign)

        store.resetAfterCorruption()
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertTrue(reloaded.keepGlobalProtectOff)
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 22)
        XCTAssertEqual(reloaded.processListLimit, 50)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), foreign)
    }

    // L11-6: every process can be shown.
    func testShowAllProcessesLiftsTheDisplayLimitAndIsKept() {
        let store = makeStore()
        XCTAssertFalse(store.showsAllProcesses)
        store.showsAllProcesses = true
        XCTAssertEqual(store.processListLimit, SettingsStore.allProcessesLimit)
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.showsAllProcesses)
        reloaded.showsAllProcesses = false
        XCTAssertEqual(reloaded.processListLimit, 80)
        reloaded.processListLimit = 5_000
        XCTAssertEqual(reloaded.processListLimit, 200, "other values keep the ordinary range")

        let inventory = (1...250).map { batch07Process(pid: Int32($0), command: "tool\($0)", executablePath: nil) }
        var projection = ProcessListProjection(inventory: inventory)
        let query = ProcessListQuery(
            searchText: "", filterMode: .all, watchedScopes: [],
            cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1024
        )
        XCTAssertEqual(projection.displayList(for: query, sortKey: .pid, limit: SettingsStore.allProcessesLimit).processes.count, 250)
        XCTAssertEqual(projection.displayList(for: query, sortKey: .pid, limit: 200).processes.count, 200)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
    }
}

// MARK: - Readable payloads that cannot be written back (A11-9)

@MainActor
final class Batch07UnrewritablePayloadTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07UnrewritablePayloadTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSettingsApplyReadOnlyWhenAnUnknownFieldCannotBeParsedBack() throws {
        let key = "batch07-settings"
        let payload = Data(#"{"schemaVersion":3,"refreshIntervalSeconds":22,"keepGlobalProtectOff":true,"futureLimit":1e400}"#.utf8)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: payload), "precondition: the raw snapshot cannot hold this payload")
        defaults.set(payload, forKey: key)

        let store = SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
        XCTAssertEqual(store.refreshIntervalSeconds, 22)
        XCTAssertTrue(store.keepGlobalProtectOff)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("\(key).corruptBackup") == true, store.recoveryMessage ?? "")
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), payload)
        store.processListLimit = 50
        XCTAssertEqual(defaults.data(forKey: key), payload)

        store.resetAfterCorruption()
        let reloaded = SettingsStore(userDefaults: defaults, key: key, searchPersistenceDelay: 0)
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.refreshIntervalSeconds, 22)
        XCTAssertEqual(reloaded.processListLimit, 50)
    }

    func testSavedSelectionsPresetsAndRulesApplyReadOnlyWhenAnUnknownFieldCannotBeParsedBack() throws {
        let selections = Data(#"[{"id":"00000000-0000-0000-0000-00000000B007","name":"Workers","pids":[42],"processes":[{"pid":42,"command":"node","executablePath":"/Batch07/bin/node","executableName":"node"}],"future":1e400}]"#.utf8)
        let presets = Data(#"[{"displayName":"Example","mainProcessName":"Example","appPath":"/Batch07Apps/Example.app","future":1e400}]"#.utf8)
        let rules = Data(#"[{"id":"00000000-0000-0000-0000-00000000B008","processName":"Example","runtimeMinutes":5,"action":"silent","future":1e400}]"#.utf8)
        for payload in [selections, presets, rules] {
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: payload))
        }
        defaults.set(selections, forKey: "selections")
        defaults.set(presets, forKey: "presets")
        defaults.set(rules, forKey: "rules")

        let selectionStore = SavedSelectionsStore(userDefaults: defaults, key: "selections")
        XCTAssertEqual(selectionStore.selections.map(\.name), ["Workers"])
        XCTAssertTrue(selectionStore.isReadOnlyAfterCorruption)
        XCTAssertTrue(selectionStore.recoveryMessage?.contains("were read") == true, selectionStore.recoveryMessage ?? "")
        XCTAssertFalse(selectionStore.rename(try XCTUnwrap(selectionStore.selections.first), to: "Renamed"))
        XCTAssertEqual(defaults.data(forKey: "selections"), selections)
        XCTAssertEqual(defaults.data(forKey: "selections.corruptBackup"), selections)

        let presetStore = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertEqual(presetStore.presets.map(\.displayName), ["Example"])
        XCTAssertTrue(presetStore.isReadOnlyAfterCorruption)
        XCTAssertTrue(presetStore.canExportPresets)
        XCTAssertTrue(presetStore.persistenceIssue?.contains("presets.corruptBackup") == true, presetStore.persistenceIssue ?? "")
        XCTAssertEqual(defaults.data(forKey: "presets"), presets)

        let ruleStore = AutoStopRulesStore(
            userDefaults: defaults,
            key: "rules",
            eventsKey: "events",
            inventory: Batch07EmptyInventory(),
            eventLimit: 200,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        XCTAssertEqual(ruleStore.rules.map(\.processName), ["Example"])
        XCTAssertTrue(ruleStore.isRulesReadOnlyAfterRecovery)
        XCTAssertFalse(ruleStore.isEventsReadOnlyAfterRecovery)
        XCTAssertEqual(defaults.data(forKey: "rules.corruptBackup"), rules)
        XCTAssertEqual(defaults.data(forKey: "rules"), rules)
    }
}

// MARK: - Preset editor

@MainActor
final class Batch07PresetEditorTests: XCTestCase {
    private let optionalAgent = UserLaunchAgentJob(
        label: "com.example.tool.agent",
        plistPath: "/Library/LaunchAgents/com.example.tool.agent.plist",
        isRequired: false
    )

    // A09-7
    func testEditingAnOptionalAgentsLabelOrPathKeepsItOptional() throws {
        var existing = batch07Preset(name: "Tool", main: "Tool")
        existing.userLaunchAgentJobs = [optionalAgent]
        let form = WatchedPresetFormState()
        func requirements(labels: String? = nil, paths: String? = nil) throws -> [Bool] {
            form.prepareForEditing(existing)
            if let labels { form.agentLabels = labels }
            if let paths { form.agentPlistPaths = paths }
            return try form.makePreset(existing: existing).get().userLaunchAgentJobs.map(\.isRequired)
        }

        XCTAssertEqual(try requirements(labels: "com.example.tool.helper"), [false])
        XCTAssertEqual(try requirements(paths: "/Users/Shared/LaunchAgents/com.example.tool.agent.plist"), [false])
        XCTAssertEqual(try requirements(paths: "/Library/LaunchAgents/./com.example.tool.agent.plist"), [false])
        XCTAssertEqual(
            try requirements(
                labels: "com.example.tool.agent, com.example.other",
                paths: "/Library/LaunchAgents/com.example.tool.agent.plist, /Library/LaunchAgents/com.example.other.plist"
            ),
            [false, true],
            "an agent added in the editor is required, as before"
        )
    }

    // T04-12 (1), A09-10
    func testEditingAPresetKeepsItsNotificationSwitch() throws {
        var existing = batch07Preset(name: "Tool", main: "Tool")
        existing.notificationsEnabled = false
        let form = WatchedPresetFormState()
        form.prepareForEditing(existing)
        form.displayName = "Tool Renamed"
        let edited = try form.makePreset(existing: existing).get()
        XCTAssertEqual(edited.displayName, "Tool Renamed")
        XCTAssertFalse(edited.notificationsEnabled)
        existing.notificationsEnabled = true
        form.prepareForEditing(existing)
        XCTAssertTrue(try form.makePreset(existing: existing).get().notificationsEnabled)
    }
}

// MARK: - Guards without other coverage (T04-12)

final class Batch07GuardTests: XCTestCase {
    private let cancelled = GlobalProtectDisconnectResult.failed("GlobalProtect shutdown was cancelled before its services were stopped.")

    // T04-12 (2): a cancelled disconnect neither reads nor presses.
    func testAPreCancelledDisconnectNeitherReadsNorPresses() async {
        let runtime = Batch07DisconnectRuntime(firstState: .connected, suspendsFirstRead: false)
        let task = Task { () -> GlobalProtectDisconnectResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await GlobalProtectDisconnectController.disconnect(using: runtime)
        }
        let result = await task.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(runtime.counts.reads, 0)
        XCTAssertEqual(runtime.counts.presses, 0)
    }

    // T04-12 (2): cancelled while waiting for an observation, it stops at the
    // next check instead of reporting a disconnect.
    func testCancellingDuringAnObservationStopsBeforeReportingDisconnected() async {
        let runtime = Batch07DisconnectRuntime(firstState: .disconnected, suspendsFirstRead: true)
        let task = Task { await GlobalProtectDisconnectController.disconnect(using: runtime) }
        await runtime.waitForFirstRead()
        task.cancel()
        runtime.resumeFirstRead()
        let result = await task.value
        XCTAssertEqual(result, cancelled)
        XCTAssertEqual(runtime.counts.reads, 1)
        XCTAssertEqual(runtime.counts.presses, 0)
    }

    // T04-12 (3): launchd's own PID is never taken for a job's PID.
    func testLaunchdPIDOneIsNeverAJobPID() {
        XCTAssertNil(GlobalProtectCompatibilityChecker.topLevelPID("system/com.paloaltonetworks.gp.pangpsd = {\n pid = 1\n}"))
        XCTAssertEqual(GlobalProtectCompatibilityChecker.topLevelPID("system/com.paloaltonetworks.gp.pangpsd = {\n pid = 2\n}"), 2)
        XCTAssertNil(ProcessLifecycleController.launchJobPID(from: ShellCommandResult(
            command: "fixture", stdout: "gui/501/com.example.agent = {\n pid = 1\n}", stderr: "", exitCode: 0
        )))
    }
}

// MARK: - Fakes

private struct Batch07EmptyInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success([])
    }
}

/// Records signals instead of sending them.
private final class Batch07RecordingSignaler: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var signals = 0

    var recordedSignals: Int { lock.withLock { signals } }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        lock.withLock { signals += 1 }
        return false
    }

    func isAlive(_ pid: Int32) -> Bool { false }
}

/// Records every lifecycle call instead of running launchctl, open or kill.
private final class Batch07RecordingLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    var recordedCalls: [String] { lock.withLock { calls } }

    private func record(_ call: String) {
        lock.withLock { calls.append(call) }
    }

    func appBundleExists(at path: String) -> Bool { record("appBundleExists"); return true }
    func openAppBundle(at path: String) async -> Bool { record("openAppBundle"); return true }
    func settleAfterProcessChange() async { record("settle") }
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminateMainProcess")
        return .signalled
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminateHelperProcess")
        return .signalled
    }
    func isProcessNamedRunning(_ name: String) async -> Bool { record("isProcessNamedRunning"); return false }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { record("waitForProcessNamed"); return true }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("unloadUserLaunchAgents"); return .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("bootstrapUserLaunchAgents"); return .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("ensureSystemLaunchDaemons"); return .notNeeded }
}

/// Never touches the vendor interface. The first read can be held open so a
/// test can cancel the disconnect while it waits for an observation.
private final class Batch07DisconnectRuntime: GlobalProtectDisconnectRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private let firstState: GlobalProtectConnectionState
    private let suspendsFirstRead: Bool
    private var reads = 0
    private var presses = 0
    private var firstReadStarted = false
    private var pendingRead: CheckedContinuation<GlobalProtectConnectionState, Never>?
    private var firstReadWaiter: CheckedContinuation<Void, Never>?

    init(firstState: GlobalProtectConnectionState, suspendsFirstRead: Bool) {
        self.firstState = firstState
        self.suspendsFirstRead = suspendsFirstRead
    }

    var counts: (reads: Int, presses: Int) { lock.withLock { (reads, presses) } }

    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState {
        let isFirst: Bool = lock.withLock {
            reads += 1
            return reads == 1
        }
        guard isFirst, suspendsFirstRead else { return isFirst ? firstState : .disconnected }
        return await withCheckedContinuation { continuation in
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                pendingRead = continuation
                firstReadStarted = true
                defer { firstReadWaiter = nil }
                return firstReadWaiter
            }
            waiter?.resume()
        }
    }

    func waitForFirstRead() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let started: Bool = lock.withLock {
                if firstReadStarted { return true }
                firstReadWaiter = continuation
                return false
            }
            if started { continuation.resume() }
        }
    }

    func resumeFirstRead() {
        let continuation: CheckedContinuation<GlobalProtectConnectionState, Never>? = lock.withLock {
            defer { pendingRead = nil }
            return pendingRead
        }
        continuation?.resume(returning: firstState)
    }

    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> Bool {
        lock.withLock { presses += 1 }
        return true
    }

    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async {}
}
