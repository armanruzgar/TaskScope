import Carbon.HIToolbox
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-17: a configuration backup carries presets, Auto-Stop rules, saved
/// selections, settings and the hotkey, never Keep Off, recovery data or event
/// history. Its import is untrusted configuration: each store validates its
/// section, rules arrive turned off, and nothing turns background enforcement on.
@MainActor
final class ConfigurationBackupTests: XCTestCase {
    // XCTest calls setUp and tearDown outside the main actor.
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: "TaskScope.ConfigurationBackupTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func makeStores(prefix: String = "a") -> ConfigurationBackupActions.Stores {
        ConfigurationBackupActions.Stores(
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "\(prefix).presets"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults, key: "\(prefix).rules", eventsKey: "\(prefix).events",
                inventory: ScriptedInventory(processes: [])
            ),
            savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "\(prefix).selections"),
            settings: SettingsStore(userDefaults: defaults, key: "\(prefix).settings"),
            hotkey: HotkeyManager(defaults: defaults, defaultsKey: "\(prefix).hotkey", backend: BackupHotkeyBackend())
        )
    }

    private let custom = WatchedAppPreset(
        displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Example Helper"],
        protectedProcessNames: [], appPath: "/Applications/Example.app"
    )

    private func process(_ pid: Int32, _ path: String) -> AppProcess {
        AppProcess.fixture(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: path, executablePath: path,
            elapsedTime: "00:01", startTime: "Sat Jul 26 11:20:17 2026", netInKB: nil, netOutKB: nil,
            diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    /// Exports everything from one set of stores, keeping the file's bytes.
    private func exportedData(from stores: ConfigurationBackupActions.Stores) throws -> Data {
        let actions = ConfigurationBackupActions()
        var saved: Data?
        actions.saveArchive = { saved = $0 }
        actions.export(from: stores)
        XCTAssertNil(actions.exportError)
        return try XCTUnwrap(saved)
    }

    private func populated() -> ConfigurationBackupActions.Stores {
        let stores = makeStores()
        XCTAssertTrue(stores.watchedApps.add(custom))
        XCTAssertTrue(stores.autoStopRules.add(AutoStopRule(
            processName: "worker", executablePath: "/usr/local/bin/worker", runtimeMinutes: 30, action: .kill
        )))
        XCTAssertTrue(stores.autoStopRules.add(AutoStopRule(
            processName: "chatty", runtimeMinutes: 5, cpuPercentAtLeast: 150, action: .prompt
        )))
        XCTAssertTrue(stores.savedSelections!.save(name: "Build tools", processes: [process(42, "/usr/bin/make")]))
        stores.settings.refreshIntervalSeconds = 20
        stores.settings.treeMode = true
        stores.settings.keepGlobalProtectOff = true
        stores.settings.setKeptOff(true, for: custom.id)
        XCTAssertTrue(stores.hotkey.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | cmdKey)))
        return stores
    }

    // MARK: Archive

    func testABackupRoundTripsEverySectionAndNeverHoldsKeepOffOrEvents() throws {
        let data = try exportedData(from: populated())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("keepGlobalProtectOff"), "Keep Off is never in a backup")
        XCTAssertFalse(text.contains("keptOffPresetIDs"), "nor is any preset's Keep Off")
        XCTAssertFalse(text.contains("events"), "Event history is never in a backup")
        XCTAssertFalse(text.contains("corruptBackup") || text.contains("rejectedMigrationBackup"))

        let archive = try ConfigurationArchive.decode(data)
        XCTAssertEqual(archive.sections, ConfigurationArchive.Section.allCases)
        XCTAssertEqual(archive.presets?.map(\.displayName), ["GlobalProtect", "Example"])
        XCTAssertEqual(archive.autoStopRules?.map(\.processName), ["worker", "chatty"])
        XCTAssertEqual(archive.savedSelections?.map(\.name), ["Build tools"])
        XCTAssertEqual(archive.settings?.refreshIntervalSeconds, 20)
        XCTAssertEqual(archive.settings?.treeMode, true)
        XCTAssertEqual(archive.hotkey, HotkeyManager.Backup(
            isEnabled: true, keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | cmdKey)
        ))
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int,
            ConfigurationArchive.currentSchemaVersion
        )
    }

    func testOldPresetArchivesStillImport() throws {
        let preset = try String(data: JSONEncoder().encode(custom), encoding: .utf8)!
        let legacy = try ConfigurationArchive.decode(Data("[\(preset)]".utf8))
        XCTAssertEqual(legacy.sections, [.presets])
        XCTAssertEqual(legacy.presets?.map(\.displayName), ["Example"])
        let versionOne = try ConfigurationArchive.decode(Data(#"{"schemaVersion":1,"presets":[\#(preset)]}"#.utf8))
        XCTAssertEqual(versionOne.presets?.map(\.displayName), ["Example"])
        // The preset export itself is unchanged, so older builds can import it.
        let stores = makeStores()
        let presetArchive = try stores.watchedApps.encodedPresetArchive()
        XCTAssertEqual((try JSONSerialization.jsonObject(with: presetArchive) as? [String: Any])?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(try ConfigurationArchive.decode(presetArchive).sections, [.presets])
    }

    func testSizeVersionShapeAndCountAreChecked() throws {
        func error(_ json: String) -> String? {
            do {
                _ = try ConfigurationArchive.decode(Data(json.utf8))
                XCTFail("decoded: \(json.prefix(80))")
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription
            }
        }
        XCTAssertEqual(error(#"{"schemaVersion":3,"presets":[]}"#),
                       "Configuration schema version 3 is not supported by this TaskScope build.")
        XCTAssertEqual(error(#"{"presets":[]}"#), "The file is not a recognized TaskScope configuration or preset archive.")
        XCTAssertEqual(error("not json"), "The file is not a recognized TaskScope configuration or preset archive.")
        XCTAssertEqual(error(#"{"schemaVersion":2,"futureSection":{}}"#),
                       "This configuration backup contains nothing this TaskScope build can import.")
        let badRule = #"{"schemaVersion":2,"autoStopRules":[{"processName":"x","runtimeMinutes":5,"action":"explode"}]}"#
        XCTAssertTrue(error(badRule)?.hasPrefix("The Auto-Stop rules in this backup could not be decoded:") == true)
        XCTAssertTrue(error(#"{"schemaVersion":2,"settings":"fast"}"#)?.hasPrefix("The settings in this backup could not be decoded:") == true)
        let rule = #"{"processName":"x","runtimeMinutes":5,"action":"prompt"}"#
        let tooMany = #"{"schemaVersion":2,"autoStopRules":["# + Array(repeating: rule, count: 501).joined(separator: ",") + "]}"
        XCTAssertEqual(error(tooMany), "A configuration backup may contain at most 500 Auto-Stop rules.")
        let huge = Data(count: ConfigurationArchive.maximumBytes + 1)
        XCTAssertThrowsError(try ConfigurationArchive.decode(huge)) { thrown in
            XCTAssertEqual(thrown as? ConfigurationArchive.ArchiveError, .exceedsMaximumSize)
        }

        let withFuture = try ConfigurationArchive.decode(Data(#"{"schemaVersion":2,"hotkey":{"isEnabled":true,"keyCode":17,"modifiers":4352},"zeta":1,"alpha":[]}"#.utf8))
        XCTAssertEqual(withFuture.sections, [.hotkey])
        XCTAssertEqual(withFuture.unknownSections, ["alpha", "zeta"])
    }

    // MARK: Import

    func testRulesArriveTurnedOffAndThePreviewNamesPathAndAction() throws {
        let stores = makeStores(prefix: "target")
        XCTAssertTrue(stores.autoStopRules.add(AutoStopRule(processName: "taken", runtimeMinutes: 5, action: .prompt)))
        let existingID = try XCTUnwrap(stores.autoStopRules.rules.first?.id)
        let candidates = [
            AutoStopRule(processName: "worker", executablePath: "/usr/local/bin/worker", runtimeMinutes: 30, action: .kill),
            // Name-only Auto Stop is valid only turned off, which is how it arrives.
            AutoStopRule(processName: "legacy", runtimeMinutes: 10, action: .kill),
            AutoStopRule(id: existingID, processName: "fresh", runtimeMinutes: 10, action: .silent),
            AutoStopRule(processName: "TAKEN", runtimeMinutes: 5, action: .prompt),
            AutoStopRule(processName: "  ", runtimeMinutes: 5, action: .prompt),
            AutoStopRule(processName: "/usr/bin/tool", runtimeMinutes: 5, action: .prompt)
        ]
        let items = stores.autoStopRules.previewImport(candidates)
        XCTAssertEqual(items.map(\.isAccepted), [true, true, true, false, false, false])
        XCTAssertTrue(items.compactMap(\.importedRule).allSatisfy { !$0.isEnabled }, "every imported rule is off")
        XCTAssertNotEqual(items[2].importedRule?.id, existingID, "a clashing id gets a new one")
        XCTAssertEqual(items[3].rejectionReason, "A rule for TAKEN already exists.")
        XCTAssertEqual(items[4].rejectionReason, "Process name is required.")
        XCTAssertNotNil(items[5].rejectionReason)

        let row = try RuleImportPreviewRow(item: items[0]).inspect()
        XCTAssertNoThrow(try row.find(text: "Executable path: /usr/local/bin/worker"))
        XCTAssertNoThrow(try row.find(text: "Action: Auto Stop"))
        XCTAssertNoThrow(try row.find(text: "Ready, turned off"))
        let nameOnly = try RuleImportPreviewRow(item: items[1]).inspect()
        XCTAssertNoThrow(try nameOnly.find(text: "Name only: matches any process named legacy"))

        let result = stores.autoStopRules.importRules(candidates)
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.rejected, 3)
        XCTAssertEqual(stores.autoStopRules.rules.filter(\.isEnabled).map(\.processName), ["taken"],
                       "nothing imported can stop a process before review")
    }

    func testANewerBuildsRuleAndARecoveringStoreAreRefused() throws {
        let stores = makeStores(prefix: "target")
        let newer = try JSONDecoder().decode(AutoStopRule.self, from: Data(
            #"{"processName":"x","runtimeMinutes":5,"action":"prompt","isEnabled":true,"futureCondition":1}"#.utf8
        ))
        XCTAssertEqual(stores.autoStopRules.previewImport([newer]).first?.rejectionReason,
                       "This rule contains fields from a newer TaskScope build and cannot be imported by this build.")

        defaults.set(Data("not json".utf8), forKey: "broken.rules")
        let broken = AutoStopRulesStore(userDefaults: defaults, key: "broken.rules", eventsKey: "broken.events",
                                        inventory: ScriptedInventory(processes: []))
        let refused = broken.previewImport([AutoStopRule(processName: "ok", runtimeMinutes: 5, action: .prompt)])
        XCTAssertEqual(refused.first?.rejectionReason, "Auto-Stop rules are in recovery mode; reset them first.")
        XCTAssertNil(try broken.exportedRulesJSON(), "a recovering store exports nothing")
    }

    func testSelectionsNeedPathsAndAFreeName() throws {
        let stores = makeStores(prefix: "target")
        let store = try XCTUnwrap(stores.savedSelections)
        XCTAssertTrue(store.save(name: "Existing", processes: [process(7, "/bin/sleep")]))
        typealias Saved = SavedSelectionsStore.SavedProcess
        let candidates = [
            SavedSelectionsStore.SavedSelection(name: " Tools ", pids: [1], processes: [
                Saved(pid: 1, command: "/usr/bin/make", executableName: "make", executablePath: "/usr/bin/make")
            ]),
            SavedSelectionsStore.SavedSelection(name: "By name", pids: [2], processes: [
                Saved(pid: 2, command: "make", executableName: "make")
            ]),
            SavedSelectionsStore.SavedSelection(name: "Old", pids: [3], processes: [], isLegacyUnsupported: true),
            SavedSelectionsStore.SavedSelection(name: "existing", pids: [4], processes: [
                Saved(pid: 4, command: "/bin/ls", executableName: "ls", executablePath: "/bin/ls")
            ])
        ]
        let items = store.previewImport(candidates)
        XCTAssertEqual(items.map(\.isAccepted), [true, false, false, false])
        XCTAssertEqual(items[0].importedSelection?.name, "Tools")
        XCTAssertEqual(items[3].rejectionReason, "A saved selection named existing already exists.")
        XCTAssertEqual(store.importSelections(candidates).imported, 1)
        XCTAssertEqual(store.selections.map(\.name), ["Existing", "Tools"])
    }

    func testSettingsAreAnAllowlistAndKeepOffIsNeverImported() throws {
        let stores = makeStores(prefix: "target")
        let archive = try ConfigurationArchive.decode(Data(#"""
        {"schemaVersion":2,"settings":{"refreshIntervalSeconds":500,"treeMode":true,"keepGlobalProtectOff":true,
         "keptOffPresetIDs":["\#(WatchedAppPreset.globalProtectID.uuidString)"],
         "sortKeyRaw":"memory","searchText":"secret"}}
        """#.utf8))
        let settings = try XCTUnwrap(archive.settings)
        let changes = stores.settings.backupChanges(settings)
        XCTAssertEqual(changes.map(\.name), ["Watched status interval", "Sort", "Tree view"])
        XCTAssertEqual(changes.first?.imported, "60 s", "clamped as the setting is")

        XCTAssertTrue(stores.settings.applyBackup(settings))
        XCTAssertEqual(stores.settings.refreshIntervalSeconds, 60)
        XCTAssertTrue(stores.settings.treeMode)
        XCTAssertEqual(stores.settings.sortOrder, ProcessSortOrder(key: .memory, direction: ProcessSortKey.memory.defaultDirection))
        XCTAssertFalse(stores.settings.keepGlobalProtectOff, "Keep Off is not a backup setting")
        XCTAssertEqual(stores.settings.keptOffPresetIDs, [], "for any preset")
        XCTAssertEqual(stores.settings.searchText, "", "nor is the search text")

        defaults.set(Data("not json".utf8), forKey: "broken.settings")
        let broken = SettingsStore(userDefaults: defaults, key: "broken.settings")
        XCTAssertFalse(broken.applyBackup(settings))
    }

    func testTheHotkeyIsValidatedAndRegisteredLikeARecording() throws {
        let stores = makeStores(prefix: "target")
        let invalid = HotkeyManager.Backup(isEnabled: true, keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(shiftKey))
        XCTAssertNotNil(stores.hotkey.backupProblem(invalid))
        XCTAssertFalse(stores.hotkey.applyBackup(invalid))
        XCTAssertEqual(stores.hotkey.displayString, "⌃⌥⌘T", "a refused hotkey changes nothing")

        let valid = HotkeyManager.Backup(isEnabled: false, keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | cmdKey))
        XCTAssertNil(stores.hotkey.backupProblem(valid))
        XCTAssertTrue(stores.hotkey.applyBackup(valid))
        XCTAssertEqual(stores.hotkey.displayString, "⌃⌘K")
        XCTAssertFalse(stores.hotkey.hotkeyEnabled)
        XCTAssertEqual(valid.displayString, "⌃⌘K")
    }

    func testImportingABackupAppliesOnlyTheIncludedSectionsAndTurnsNothingOn() throws {
        let data = try exportedData(from: populated())
        let target = makeStores(prefix: "target")
        let actions = ConfigurationBackupActions()
        actions.fileSize = { _ in data.count }
        actions.readFile = { _ in data }
        actions.loadImport(from: URL(fileURLWithPath: "/nonexistent/backup.json"), into: target)
        let preview = try XCTUnwrap(actions.preview)
        XCTAssertEqual(preview.sections, ConfigurationArchive.Section.allCases)
        XCTAssertEqual(preview.importableCount(.presets), 1, "the built-in preset is already there")
        XCTAssertEqual(preview.importableCount(.autoStopRules), 2)
        XCTAssertEqual(preview.importableCount(.hotkey), 1)

        actions.setIncluded(.savedSelections, false)
        actions.commitImport(into: target)

        XCTAssertNil(actions.preview)
        XCTAssertEqual(target.watchedApps.presets.map(\.displayName), ["GlobalProtect", "Example"])
        XCTAssertEqual(target.autoStopRules.rules.map(\.processName), ["worker", "chatty"])
        XCTAssertTrue(target.autoStopRules.rules.allSatisfy { !$0.isEnabled }, "imported rules start off")
        XCTAssertEqual(target.savedSelections?.selections, [], "an excluded section is left alone")
        XCTAssertEqual(target.settings.refreshIntervalSeconds, 20)
        XCTAssertFalse(target.settings.keepGlobalProtectOff, "no background enforcement from an import")
        XCTAssertEqual(target.settings.keptOffPresetIDs, [], "no preset is kept off by an import")
        XCTAssertEqual(target.hotkey.displayString, "⌃⌘K")
        XCTAssertEqual(
            actions.importSummary,
            "Imported 1 preset, 2 Auto-Stop rules, settings and the hotkey. Not imported: 1 preset. Imported Auto-Stop rules are turned off: review each one in Settings > Auto-Stop and turn on the ones you want."
        )

        // The preview sheet lists what the rules match and do.
        actions.loadImport(from: URL(fileURLWithPath: "/nonexistent/backup.json"), into: makeStores(prefix: "other"))
        let sheet = try ConfigurationImportPreviewView(actions: actions, onCancel: {}, onImport: {}).inspect()
        XCTAssertNoThrow(try sheet.find(text: "Executable path: /usr/local/bin/worker"))
        XCTAssertNoThrow(try sheet.find(text: "Action: Auto Stop"))
        XCTAssertNoThrow(try sheet.find(text: "Keep Off is not part of a backup. Your presets keep theirs, and a preset the import adds arrives with Keep Off off."))
    }

    func testExportLeavesOutWhatIsInRecoveryAndSaysSo() throws {
        defaults.set(Data("not json".utf8), forKey: "a.rules")
        let stores = makeStores()
        let actions = ConfigurationBackupActions()
        var saved: Data?
        actions.saveArchive = { saved = $0 }
        actions.export(from: stores)
        let archive = try ConfigurationArchive.decode(try XCTUnwrap(saved))
        XCTAssertNil(archive.autoStopRules)
        XCTAssertNotNil(archive.presets)
        XCTAssertEqual(actions.exportNote,
                       "The backup leaves out Auto-Stop rules: their stored data is in recovery. Recover it first to include it.")
    }

    func testThePresetImportTakesOnlyTheBackupsPresets() throws {
        let data = try exportedData(from: populated())
        let target = makeStores(prefix: "target")
        let actions = PresetSettingsActions()
        actions.fileSize = { _ in data.count }
        actions.readFile = { _ in data }
        actions.loadImport(from: URL(fileURLWithPath: "/nonexistent/backup.json"), into: target.watchedApps)
        XCTAssertEqual(actions.preview?.importableCount, 1)
        actions.commitImport(into: target.watchedApps)
        XCTAssertEqual(target.autoStopRules.rules, [], "rules come in only through Import Configuration")
        XCTAssertEqual(actions.importSummary?.hasSuffix(
            "The rest of the configuration backup was not imported; use Import Configuration… in Settings > General."
        ), true, actions.importSummary ?? "")

        let noPresets = Data(#"{"schemaVersion":2,"settings":{"treeMode":true}}"#.utf8)
        actions.readFile = { _ in noPresets }
        actions.fileSize = { _ in noPresets.count }
        actions.loadImport(from: URL(fileURLWithPath: "/nonexistent/backup.json"), into: target.watchedApps)
        XCTAssertEqual(actions.importError,
                       "This configuration backup holds no watched-app presets. Import it with Import Configuration… in Settings > General.")
    }

    func testListsReadAsEnglish() {
        XCTAssertEqual(ConfigurationBackupActions.list(["a"]), "a")
        XCTAssertEqual(ConfigurationBackupActions.list(["a", "b"]), "a and b")
        XCTAssertEqual(ConfigurationBackupActions.list(["a", "b", "c"]), "a, b and c")
    }
}

/// Records nothing and registers nothing with the system.
private final class BackupHotkeyBackend: HotkeyRegistrationBackend {
    private var nextReference = 1

    func installEventHandler(for manager: HotkeyManager) -> OSStatus { noErr }

    func register(keyCode: UInt32, modifiers: UInt32, identifier: EventHotKeyID)
        -> (status: OSStatus, reference: EventHotKeyRef?) {
        defer { nextReference += 1 }
        return (noErr, OpaquePointer(bitPattern: nextReference))
    }

    func unregister(_ reference: EventHotKeyRef) {}
}
