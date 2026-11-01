import XCTest
@testable import TaskScope

@MainActor
final class WatchedAppsStoreTests: XCTestCase {
    private let suiteName = "TaskScope.WatchedAppsStoreTests"
    private let key = "watched-presets-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSeededGlobalProtectSurvivesReloadAndCatalogLookup() {
        let first = WatchedAppsStore(userDefaults: defaults, key: key)
        let second = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(first.presets, [.globalProtect])
        XCTAssertEqual(second.presets, first.presets)
        XCTAssertFalse(second.isReadOnlyAfterCorruption)
        XCTAssertNil(second.persistenceIssue)
        XCTAssertEqual(
            WatchedPresetCatalog(suiteName: suiteName, key: key).entities().map(\.id),
            [WatchedAppPreset.globalProtectID]
        )
    }

    func testGlobalProtectNotificationUpdateSurvivesReload() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var preset = WatchedAppPreset.globalProtect
        preset.notificationsEnabled = false
        XCTAssertTrue(store.update(preset))
        let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(reloaded.presets, [preset])
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
    }

    func testOptionalCustomAgentSurvivesNormalizationAndReload() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var preset = validPreset(name: "Optional")
        preset.userLaunchAgentJobs = [
            UserLaunchAgentJob(label: " optional.agent ", plistPath: "/agents/../agents/optional.plist", isRequired: false)
        ]
        XCTAssertTrue(store.add(preset))
        let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(reloaded.presets.last?.userLaunchAgentJobs, [
            UserLaunchAgentJob(label: "optional.agent", plistPath: "/agents/optional.plist", isRequired: false)
        ])
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
    }

    func testCorruptPayloadIsBackedUpAndCannotBeOverwrittenByMutation() {
        let corrupt = Data([0xFE, 0xED])
        defaults.set(corrupt, forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(store.persistenceIssue)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)

        _ = store.add(validPreset(name: "Example"))
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testFirstPresetBackupSurvivesASecondCorruptLaunch() {
        let first = Data([0xFE, 0x01])
        let second = Data([0xFE, 0x02])
        defaults.set(first, forKey: key)
        _ = WatchedAppsStore(userDefaults: defaults, key: key)

        defaults.set(second, forKey: key)
        _ = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), first)
        XCTAssertEqual(defaults.data(forKey: key), second)
    }

    func testExplicitResetAfterCorruptionAllowsPersistence() throws {
        defaults.set(Data([0xFE, 0xED]), forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        store.resetAfterCorruption()

        let persisted = try JSONDecoder().decode(
            [WatchedAppPreset].self,
            from: XCTUnwrap(defaults.data(forKey: key))
        )
        XCTAssertEqual(persisted, [.globalProtect])
        XCTAssertNil(store.persistenceIssue)
    }

    func testValidationTrimsFieldsAndRejectsSemanticDuplicates() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var preset = validPreset(name: " Example ")
        preset.mainProcessName = " ExampleProcess "
        preset.appPath = " /Applications/Example.app "

        XCTAssertTrue(store.add(preset))
        XCTAssertEqual(store.presets[0].displayName, "Example")
        XCTAssertEqual(store.presets[0].mainProcessName, "ExampleProcess")
        XCTAssertEqual(store.presets[0].appPath, "/Applications/Example.app")
        XCTAssertFalse(store.add(validPreset(name: "example")))
        XCTAssertNotNil(store.validationError)
    }

    func testCrossFieldNamesRemainValidAfterPersistenceRoundTrip() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        let first = WatchedAppPreset(
            displayName: "Alpha",
            mainProcessName: "Beta",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Alpha.app"
        )
        let second = WatchedAppPreset(
            displayName: "Beta",
            mainProcessName: "Gamma",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Beta.app"
        )

        XCTAssertTrue(store.add(first))
        XCTAssertTrue(store.add(second))

        let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(reloaded.presets.map(\.displayName), ["Alpha", "Beta"])
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertNil(reloaded.persistenceIssue)
    }

    func testDuplicateLaunchJobLabelsAndPathsAreRejected() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var duplicateLabel = validPreset(name: "Labels")
        duplicateLabel.userLaunchAgentJobs = [
            UserLaunchAgentJob(label: "example.agent", plistPath: "/agents/first.plist"),
            UserLaunchAgentJob(label: "EXAMPLE.AGENT", plistPath: "/agents/second.plist")
        ]
        XCTAssertFalse(store.add(duplicateLabel))

        var duplicatePath = validPreset(name: "Paths")
        duplicatePath.userLaunchAgentJobs = [
            UserLaunchAgentJob(label: "first.agent", plistPath: "/agents/../agents/shared.plist"),
            UserLaunchAgentJob(label: "second.agent", plistPath: "/agents/shared.plist")
        ]
        XCTAssertFalse(store.add(duplicatePath))
        XCTAssertTrue(store.validationError?.contains("must be unique") == true)
    }

    func testDirectoryOnlyAppPathAndInvalidPortAreRejected() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var directory = validPreset(name: "Directory")
        directory.appPath = "/Applications/"
        XCTAssertFalse(store.add(directory))

        var invalidPort = validPreset(name: "Port")
        invalidPort.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "daemon",
                plistPath: "/Library/LaunchDaemons/daemon.plist",
                processName: "daemon",
                servicePort: 70_000
            )
        ]
        XCTAssertFalse(store.add(invalidPort))

        var relativeAgent = validPreset(name: "Relative Agent")
        relativeAgent.userLaunchAgentJobs = [
            UserLaunchAgentJob(label: "relative.agent", plistPath: "relative/agent.plist")
        ]
        XCTAssertFalse(store.add(relativeAgent))
        XCTAssertTrue(store.validationError?.contains("absolute .plist") == true)
    }

    func testImportRejectsRepeatedIDsWithinTheSamePayload() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        let first = validPreset(name: "First")
        var repeatedID = validPreset(name: "Second")
        repeatedID.id = first.id

        let result = store.importPresets([first, repeatedID])

        XCTAssertEqual(result, .init(importedCount: 1, rejectedCount: 1))
        XCTAssertEqual(store.presets.map(\.displayName), ["First"])
        XCTAssertEqual(Set(store.presets.map(\.id)).count, store.presets.count)
    }

    func testSemanticDuplicateRejectionDoesNotUseUpItsID() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        XCTAssertTrue(store.add(validPreset(name: "Foo")))
        let duplicate = validPreset(name: "Foo")
        var unique = validPreset(name: "Bar")
        unique.id = duplicate.id

        let preview = store.previewImport([duplicate, unique])

        XCTAssertEqual(
            preview.items[0].rejectionReason,
            "A preset with the same name, process, or app path already exists."
        )
        XCTAssertNil(preview.items[1].rejectionReason)
        XCTAssertEqual(preview.importableCount, 1)

        let result = store.importPresets([duplicate, unique])
        XCTAssertEqual(result, .init(importedCount: 1, rejectedCount: 1))
        XCTAssertEqual(store.presets.map(\.displayName), ["Foo", "Bar"])
    }

    func testImportPreviewDoesNotMutateAndCommitUsesTheSameValidation() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        let valid = validPreset(name: "Valid")
        var invalid = validPreset(name: "Invalid")
        invalid.appPath = "relative/Invalid.app"

        let preview = store.previewImport([valid, invalid])

        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertEqual(preview.importableCount, 1)
        XCTAssertEqual(preview.rejectedCount, 1)
        XCTAssertEqual(preview.items[1].rejectionReason, "App path must be an absolute .app bundle path.")

        let result = store.importPresets(preview.items.map(\.preset))
        XCTAssertEqual(result, .init(importedCount: 1, rejectedCount: 1))
        XCTAssertEqual(store.presets.map(\.displayName), ["Valid"])
    }

    func testVersionedArchiveRoundTripsAndLegacyArrayStillImports() throws {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        let archiveData = try store.encodedPresetArchive()

        XCTAssertEqual(
            try WatchedAppsStore.decodePresetArchive(archiveData),
            store.presets
        )

        let legacy = [validPreset(name: "Legacy")]
        XCTAssertEqual(
            try WatchedAppsStore.decodePresetArchive(JSONEncoder().encode(legacy)),
            legacy
        )
    }

    func testUnsupportedArchiveVersionIsRejected() throws {
        let archive = WatchedAppsStore.PresetArchive(
            schemaVersion: 999,
            presets: [validPreset(name: "Future")]
        )
        let data = try JSONEncoder().encode(archive)

        XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(data)) { error in
            XCTAssertEqual(
                error as? WatchedAppsStore.PresetArchiveError,
                .unsupportedSchemaVersion(999)
            )
        }
    }

    /// A versioned archive whose presets fail to decode must report *that*
    /// error. Retrying it as a legacy array only hid the real problem behind a
    /// generic "not a recognized archive" message.
    func testVersionedArchiveWithABrokenPresetReportsTheDecodingErrorInsteadOfLegacyFallback() {
        let broken = Data("""
        {"schemaVersion":1,"presets":[{"displayName":"Broken","appPath":"/Applications/Broken.app"}]}
        """.utf8)

        XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(broken)) { error in
            guard case .invalidContents(let detail)? = error as? WatchedAppsStore.PresetArchiveError else {
                return XCTFail("Expected invalidContents, got \(error)")
            }
            XCTAssertTrue(detail.contains("mainProcessName"), detail)
            XCTAssertTrue(detail.contains("presets[0]"), detail)
        }

        let legacyBroken = Data("""
        [{"displayName":"Broken","appPath":"/Applications/Broken.app"}]
        """.utf8)
        XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(legacyBroken)) { error in
            guard case .invalidContents(let detail)? = error as? WatchedAppsStore.PresetArchiveError else {
                return XCTFail("Expected invalidContents, got \(error)")
            }
            XCTAssertTrue(detail.contains("[0]"), detail)
        }

        XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(Data(#"{"presets":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? WatchedAppsStore.PresetArchiveError, .unreadable)
        }
    }

    func testMalformedArchiveIsRejected() {
        XCTAssertThrowsError(
            try WatchedAppsStore.decodePresetArchive(Data("not json".utf8))
        ) { error in
            XCTAssertEqual(
                error as? WatchedAppsStore.PresetArchiveError,
                .unreadable
            )
        }
    }

    func testOversizedArchiveIsRejectedBeforeDecoding() {
        let data = Data(
            repeating: 0x20,
            count: WatchedAppsStore.maximumPresetArchiveBytes + 1
        )

        XCTAssertThrowsError(try WatchedAppsStore.decodePresetArchive(data)) { error in
            XCTAssertEqual(
                error as? WatchedAppsStore.PresetArchiveError,
                .exceedsMaximumSize
            )
        }
    }

    func testCustomPrivilegedDaemonsAndProcessRoleOverlapsAreRejected() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.remove(at: IndexSet(store.presets.indices)))
        var daemon = validPreset(name: "Privileged")
        daemon.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "com.example.daemon",
                plistPath: "/Library/LaunchDaemons/com.example.daemon.plist",
                processName: "ExampleDaemon",
                servicePort: nil
            )
        ]
        XCTAssertFalse(store.add(daemon))
        XCTAssertTrue(store.validationError?.contains("cannot configure privileged") == true)

        var overlap = validPreset(name: "Overlap")
        overlap.helperProcessNames = ["Shared"]
        overlap.protectedProcessNames = ["shared"]
        XCTAssertFalse(store.add(overlap))
        XCTAssertTrue(store.validationError?.contains("Protected process names") == true)
    }

    func testStoredAndIntentPresetsAreRevalidatedBeforeUse() throws {
        let valid = validPreset(name: "Valid")
        var unsafe = validPreset(name: "Unsafe")
        unsafe.systemLaunchDaemonJobs = [
            SystemLaunchDaemonJob(
                label: "com.example.unsafe",
                plistPath: "/Library/LaunchDaemons/com.example.unsafe.plist",
                processName: "UnsafeDaemon",
                servicePort: nil
            )
        ]
        let original = try JSONEncoder().encode([valid, unsafe])
        let olderCorruptPayload = Data("older corrupt payload".utf8)
        defaults.set(original, forKey: key)
        defaults.set(olderCorruptPayload, forKey: "\(key).corruptBackup")

        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        let catalog = WatchedPresetCatalog(suiteName: suiteName, key: key)

        XCTAssertEqual(store.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(catalog.entities().map(\.displayName), ["Valid"])
        XCTAssertTrue(store.persistenceIssue?.contains("Rejected 1") == true)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertEqual(defaults.data(forKey: key), original)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), olderCorruptPayload)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        XCTAssertTrue(store.persistenceIssue?.contains("\(key).rejectedMigrationBackup") == true)
        XCTAssertTrue(store.canExportPresets)

        XCTAssertFalse(store.add(validPreset(name: "New")))
        XCTAssertFalse(store.remove(valid))
        XCTAssertEqual(store.presets.map(\.displayName), ["Valid"])
        XCTAssertEqual(defaults.data(forKey: key), original)

        store.resetAfterCorruption()

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), olderCorruptPayload)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        let committed = try JSONDecoder().decode(
            [WatchedAppPreset].self,
            from: XCTUnwrap(defaults.data(forKey: key))
        )
        XCTAssertEqual(committed.map(\.displayName), ["Valid"])
    }

    func testUndecodablePresetsAreRejectedWithoutLosingValidPresetsOrIntentEntities() throws {
        let valid = validPreset(name: "Valid")
        let other = validPreset(name: "Other")
        let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let otherJSON = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
        let original = Data("""
        [null, \(validJSON), 42, {"displayName":[]}, [], \(otherJSON), \(validJSON)]
        """.utf8)
        defaults.set(original, forKey: key)

        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        let catalog = WatchedPresetCatalog(suiteName: suiteName, key: key)

        XCTAssertEqual(store.presets, [valid, other])
        XCTAssertEqual(catalog.entities().map(\.id), [valid.id, other.id])
        XCTAssertTrue(store.persistenceIssue?.contains("Rejected 5") == true)
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.canExportPresets)
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        XCTAssertNil(defaults.data(forKey: "\(key).corruptBackup"))
        XCTAssertFalse(store.remove(valid))
        XCTAssertFalse(store.add(validPreset(name: "New")))
        XCTAssertEqual(defaults.data(forKey: key), original)
        XCTAssertEqual(WatchedAppsStore(userDefaults: defaults, key: key).presets, [valid, other])
        XCTAssertEqual(try WatchedAppsStore.decodePresetArchive(store.encodedPresetArchive()), [valid, other])

        store.resetAfterCorruption()

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        XCTAssertEqual(try JSONDecoder().decode([WatchedAppPreset].self, from: XCTUnwrap(defaults.data(forKey: key))), [valid, other])
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
    }

    func testNonArrayPresetsPayloadUsesCorruptRecovery() {
        for json in ["{}", "null", "42", "\"presets\""] {
            let original = Data(json.utf8)
            defaults.set(original, forKey: key)
            let store = WatchedAppsStore(userDefaults: defaults, key: key)

            XCTAssertTrue(store.presets.isEmpty)
            XCTAssertTrue(store.isReadOnlyAfterCorruption)
            XCTAssertFalse(store.canExportPresets)
            XCTAssertTrue(store.persistenceIssue?.contains("corruptBackup") == true)
            XCTAssertEqual(defaults.data(forKey: key), original)
            XCTAssertNil(defaults.data(forKey: "\(key).rejectedMigrationBackup"))
            XCTAssertTrue(WatchedPresetCatalog(suiteName: suiteName, key: key).entities().isEmpty)
        }
    }

    func testBuiltInGlobalProtectLifecycleIdentityIsImmutable() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var modified = WatchedAppPreset.globalProtect
        modified.systemLaunchDaemonJobs[0].plistPath = "/Library/LaunchDaemons/other.plist"

        XCTAssertFalse(store.update(modified))
        XCTAssertEqual(store.presets, [.globalProtect])
        XCTAssertTrue(store.validationError?.contains("cannot be modified") == true)
        var alteredRequirement = WatchedAppPreset.globalProtect
        alteredRequirement.userLaunchAgentJobs[1].isRequired = true
        XCTAssertFalse(store.update(alteredRequirement))
        XCTAssertEqual(store.presets, [.globalProtect])
    }

    func testPreviousGlobalProtectAgentDefinitionMigratesToCurrentOptionalAgentSet() throws {
        var legacy = WatchedAppPreset.globalProtect
        legacy.userLaunchAgentJobs = WatchedAppPreset.legacyGlobalProtectUserLaunchAgentJobs
        legacy.notificationsEnabled = false
        defaults.set(try JSONEncoder().encode([legacy]), forKey: key)

        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertNil(store.persistenceIssue)
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(
            store.presets[0].userLaunchAgentJobs,
            WatchedAppPreset.globalProtectUserLaunchAgentJobs
        )
        XCTAssertFalse(store.presets[0].notificationsEnabled)
        let persisted = try JSONDecoder().decode(
            [WatchedAppPreset].self,
            from: XCTUnwrap(defaults.data(forKey: key))
        )
        XCTAssertEqual(
            persisted[0].userLaunchAgentJobs,
            WatchedAppPreset.globalProtectUserLaunchAgentJobs
        )
        for _ in 0..<2 {
            let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
            XCTAssertEqual(reloaded.presets, persisted)
            XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        }
    }

    func testMainProcessIsRemovedFromHelpersOnLoadImportAndEdit() throws {
        var preset = validPreset(name: "Example")
        preset.helperProcessNames = ["ExampleProcess", "exampleprocess", "Helper"]
        defaults.set(try JSONEncoder().encode([preset]), forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(store.presets[0].helperProcessNames, ["Helper"])
        XCTAssertTrue(store.update(preset))
        XCTAssertEqual(store.presets[0].helperProcessNames, ["Helper"])
        XCTAssertTrue(store.remove(preset))
        XCTAssertEqual(store.importPresets([preset]).importedCount, 1)
        XCTAssertEqual(store.presets[0].helperProcessNames, ["Helper"])
        XCTAssertEqual(WatchedAppsStore(userDefaults: defaults, key: key).presets[0].helperProcessNames, ["Helper"])
    }

    func testPresetPathsUseOnDiskCaseAndMainExecutableAdoptsBundleSpelling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("Example.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["CFBundleExecutable": "ExampleProcess", "CFBundleIdentifier": "test.example", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: contents.appendingPathComponent("MacOS/ExampleProcess"))
        let alias = directory.appendingPathComponent("example.app")
        // Also exercise realpath on case-sensitive test volumes.
        if !FileManager.default.fileExists(atPath: alias.path) {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
        }
        var preset = validPreset(name: "Example")
        preset.appPath = alias.path
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.add(preset))
        XCTAssertEqual(store.presets.last?.appPath, AutoStopRuleValidation.canonicalPath(bundle.path))
        preset.mainProcessName = "exampleprocess"
        XCTAssertTrue(store.update(preset))
        XCTAssertEqual(store.presets.last?.mainProcessName, "ExampleProcess")

        // A stored preset with the wrong case loads corrected, never read-only.
        defaults.set(try JSONEncoder().encode([preset]), forKey: key)
        let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.presets.first?.mainProcessName, "ExampleProcess")
    }

    func testCommasAreRejectedInListFieldsOnLoadImportAndEdit() throws {
        let valid = validPreset(name: "Example")
        // Single-value fields are never split by the form, so commas stay valid there.
        var singleValues = validPreset(name: "Example, Inc")
        singleValues.appPath = "/Applications/Example, Inc.app"
        let singleValueStore = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(singleValueStore.add(singleValues), singleValueStore.validationError ?? "")
        XCTAssertTrue(singleValueStore.remove(singleValues))

        let mutations: [(inout WatchedAppPreset) -> Void] = [
            { $0.helperProcessNames = ["Foo, Bar Helper"] },
            { $0.protectedProcessNames = ["Foo, Bar"] },
            { $0.userLaunchAgentJobs = [UserLaunchAgentJob(label: "foo", plistPath: "/tmp/Foo, Bar.plist")] },
            { $0.userLaunchAgentJobs = [UserLaunchAgentJob(label: "foo, bar", plistPath: "/tmp/foo.plist")] }
        ]
        for mutate in mutations {
            defaults.set(try JSONEncoder().encode([valid]), forKey: key)
            let store = WatchedAppsStore(userDefaults: defaults, key: key)
            var invalid = valid
            mutate(&invalid)
            XCTAssertFalse(store.update(invalid))
            XCTAssertTrue(store.validationError?.contains("commas") == true)
            XCTAssertTrue(store.remove(valid))
            XCTAssertEqual(store.importPresets([invalid]).rejectedCount, 1)
            XCTAssertFalse(store.add(invalid))
            let payload = try JSONEncoder().encode([invalid])
            defaults.set(payload, forKey: key)
            let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
            XCTAssertTrue(reloaded.presets.isEmpty)
            XCTAssertTrue(reloaded.isReadOnlyAfterCorruption)
            XCTAssertEqual(defaults.data(forKey: key), payload)
        }
    }

    private func validPreset(name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: "\(name.trimmingCharacters(in: .whitespaces))Process",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name.trimmingCharacters(in: .whitespaces)).app"
        )
    }
}
