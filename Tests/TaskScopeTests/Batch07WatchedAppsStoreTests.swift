import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

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
        let lifecycle = FakeLifecycle()
        let signaler = FakeSignaler(rejectingAll: true)
        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []),
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { store.presets }
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
        XCTAssertEqual(lifecycle.calls, [])
        XCTAssertEqual(signaler.sent.count, 0)
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
