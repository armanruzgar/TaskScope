import AppKit
import Carbon.HIToolbox
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Regression tests for the Settings window and its sheets (audit batch 11).
@MainActor
final class Batch11FixTests: XCTestCase {
    // MARK: - Fixtures

    /// A private in-memory domain; reuse the instance to "relaunch" a store.
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults(suiteName: "TaskScope.Batch11FixTests.\(UUID().uuidString)")!
    }

    private func process(
        pid: Int32 = 421,
        path: String = "/opt/tools/Example",
        uid: uid_t? = getuid()
    ) -> AppProcess {
        AppProcess.fixture(pid: pid, parentPID: 1, uid: uid, cpu: 1, memoryMB: 12, command: path,
                   executablePath: path, elapsedTime: "01:00", startTime: "start-\(pid)",
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func rules(_ defaults: UserDefaults) -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events",
                           inventory: ScriptedInventory(processes: []))
    }

    private func settingsView(
        _ defaults: UserDefaults,
        tab: SettingsView.Tab,
        watchedApps: WatchedAppsStore? = nil,
        autoStopRules: AutoStopRulesStore? = nil,
        actions: PresetSettingsActions? = nil,
        interactions: SettingsInteractionState? = nil
    ) -> SettingsView {
        SettingsView(
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: watchedApps ?? WatchedAppsStore(userDefaults: defaults, key: "presets"),
            autoStopRules: autoStopRules ?? rules(defaults),
            processManager: ProcessManager(
                processInventory: ScriptedInventory(processes: []),
                verificationInventory: ScriptedInventory(processes: []),
                processSignaler: FakeSignaler.forbidding("Settings tests must never signal a process"),
                lifecycle: FakeLifecycle(),
                settleAfterProcessChange: {},
                dependencies: .inert
            ),
            hotkey: .forTests(), notificationService: .forTests(),
            selectedTab: tab,
            presetActions: actions ?? PresetSettingsActions(),
            interactions: interactions ?? SettingsInteractionState()
        )
    }

    private func button<V: View>(labeled label: String, in view: V) throws -> InspectableView<ViewType.Button> {
        try view.inspect().find(ViewType.Button.self, where: {
            (try? $0.accessibilityLabel().string()) == label
        })
    }

    /// The one confirmation dialog the Settings view is presenting.
    private func presentedDialog(_ view: SettingsView) throws -> InspectableView<ViewType.ConfirmationDialog> {
        let tabView = try view.inspect().tabView()
        for index in 0..<3 {
            if let dialog = try? tabView.confirmationDialog(index) { return dialog }
        }
        throw NoDialog()
    }

    private struct NoDialog: Error {}

    private let customPreset = WatchedAppPreset(
        displayName: "Example", mainProcessName: "Example", helperProcessNames: [],
        protectedProcessNames: [], appPath: "/Applications/Example.app"
    )

    // MARK: - A13-4: quick Update discloses a rule's retargeted binary

    func testQuickUpdateNamesTheBinaryTheRuleCoversNowAndAfterTheUpdate() throws {
        let store = rules(makeDefaults())
        let rule = AutoStopRule(processName: "node", executablePath: "/opt/homebrew/bin/node",
                                runtimeMinutes: 5, action: .prompt)
        XCTAssertTrue(store.add(rule))
        let other = process(path: "/Users/me/.nvm/versions/node/v22/bin/node")
        let expected = "This rule currently applies to /opt/homebrew/bin/node. Updating it applies it to /Users/me/.nvm/versions/node/v22/bin/node instead."

        let sheet = QuickAutoStopRuleSheet(process: other, existingRule: rule,
                                          onSave: { _, _, _ in nil }, onCancel: {})
        XCTAssertNoThrow(try sheet.inspect().find(text: expected))

        let outcome = QuickAutoStopRuleSaver.save(
            into: store, processName: "node", observedProcessName: other.name,
            observedExecutablePath: other.executablePath, runtimeMinutes: 5, action: .prompt,
            existingRule: rule
        )
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.statusMessage, "Updated auto-stop rule for node. " + expected)
        // The retarget itself is kept: it also repairs a rule whose path moved.
        XCTAssertEqual(store.rules.first?.executablePath, other.executablePath)

        let same = QuickAutoStopRuleSheet(process: process(path: "/opt/homebrew/bin/node"), existingRule: rule,
                                         onSave: { _, _, _ in nil }, onCancel: {})
        XCTAssertThrowsError(try same.inspect().find(textWhere: { text, _ in text.hasPrefix("This rule currently applies") }))
        XCTAssertNil(QuickAutoStopRuleSaver.scopeChangeMessage(
            existingRule: rule, processName: "node", executablePath: "/opt/homebrew/bin/node"
        ))
    }

    // MARK: - A13-5: renaming in the quick Update sheet drops the old name's path

    func testRenamingAPathBoundRuleInTheQuickSheetDoesNotKeepTheOldNamesPath() throws {
        let store = rules(makeDefaults())
        let rule = AutoStopRule(processName: "node", executablePath: "/opt/homebrew/bin/node",
                                runtimeMinutes: 5, action: .prompt)
        XCTAssertTrue(store.add(rule))
        XCTAssertNil(QuickAutoStopRuleSaver.executablePath(
            processName: "deno", observedProcessName: "node",
            observedExecutablePath: "/opt/homebrew/bin/node", action: .prompt, existingRule: rule
        ))

        let autoStop = QuickAutoStopRuleSaver.save(
            into: store, processName: "deno", observedProcessName: "node",
            observedExecutablePath: "/opt/homebrew/bin/node", runtimeMinutes: 5, action: .kill,
            existingRule: rule
        )
        XCTAssertEqual(autoStop.error, "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules.")
        XCTAssertEqual(store.rules, [rule])

        let prompt = QuickAutoStopRuleSaver.save(
            into: store, processName: "deno", observedProcessName: "node",
            observedExecutablePath: "/opt/homebrew/bin/node", runtimeMinutes: 5, action: .prompt,
            existingRule: rule
        )
        XCTAssertNil(prompt.error)
        XCTAssertEqual(store.rules.map(\.processName), ["deno"])
        XCTAssertNil(store.rules.first?.executablePath, "A renamed rule must not keep a path it can never match")
        XCTAssertTrue(prompt.statusMessage?.hasSuffix("Updating it applies it to any process named deno instead.") == true)
    }

    // MARK: - A13-3: rules for other users' processes are refused in the sheet

    func testQuickRuleSheetRefusesProcessesOwnedByAnotherOrAnUnknownUser() throws {
        let explanation = QuickAutoStopRuleSheet.otherOwnerExplanation(processName: "Example")
        for owner: uid_t? in [getuid() + 1, 0, nil] where owner != getuid() {
            for existing in [nil, AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)] {
                let sheet = QuickAutoStopRuleSheet(
                    process: process(uid: owner), existingRule: existing,
                    onSave: { _, _, _ in XCTFail("The rule must not be saved"); return nil },
                    onCancel: {}, currentUID: getuid()
                )
                XCTAssertTrue(try sheet.inspect().find(button: existing == nil ? "Add Rule" : "Update Rule").isDisabled())
                XCTAssertNoThrow(try sheet.inspect().find(text: explanation))
            }
        }
        let owned = QuickAutoStopRuleSheet(process: process(), existingRule: nil,
                                          onSave: { _, _, _ in nil }, onCancel: {}, currentUID: getuid())
        XCTAssertFalse(try owned.inspect().find(button: "Add Rule").isDisabled())
        XCTAssertThrowsError(try owned.inspect().find(text: explanation))
    }

    // MARK: - A13-8: a helper listed before its app is not taken for the app

    func testSaveSelectionAsPresetUsesTheAppsOwnExecutableWhenAHelperComesFirst() throws {
        let helper = process(
            pid: 948, path: "/Applications/Example.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper"
        )
        let main = process(pid: 19_987, path: "/Applications/Example.app/Contents/MacOS/Example")
        var saved: WatchedAppPreset?
        let sheet = QuickWatchedPresetSheet(draft: QuickWatchedPresetDraft(processes: [helper, main]),
                                           onSave: { saved = $0; return nil }, onCancel: {})
        let inspected = try sheet.inspect()
        func field(_ label: String) throws -> String {
            try inspected.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == label }).input()
        }
        XCTAssertEqual(try field("Display name"), "Example")
        XCTAssertEqual(try field("Main process name"), "Example")
        XCTAssertEqual(try field("Helpers"), "Example Helper")
        XCTAssertEqual(try field("App path"), "/Applications/Example.app")

        try inspected.find(button: "Add Preset").tap()
        let preset = try XCTUnwrap(saved, "The inferred draft must be accepted as it stands")
        XCTAssertEqual(preset.mainProcessName, "Example")
        XCTAssertEqual(preset.helperProcessNames, ["Example Helper"])
        XCTAssertEqual(preset.appPath, "/Applications/Example.app")

        // Without the app's own executable the old inference is kept.
        XCTAssertNil(QuickWatchedPresetSheet.mainProcess(in: [helper]))
        XCTAssertNil(QuickWatchedPresetSheet.mainProcess(
            in: [main, process(pid: 7, path: "/Applications/Other.app/Contents/MacOS/Other")]
        ))
    }

    // MARK: - A11-1 and A11-11 (5): the recall sheet scrolls and keeps its buttons

    func testRecallSheetKeepsItsButtonsOnScreenForALargeSelection() throws {
        _ = NSApplication.shared // The size check hosts the sheet in AppKit.
        let selection = SavedSelectionsStore.SavedSelection(name: "Large", pids: [], processes: [])
        let matched = (1...200).map { process(pid: Int32($0), path: "/opt/tools/Helper\($0)") }
        let large = SavedSelectionRecallSheet(
            selection: selection,
            result: .init(matched: matched, unmatched: [], ambiguous: [], legacyUnsupported: false),
            onApply: {}, onCancel: {}
        )
        XCTAssertNoThrow(try large.inspect().find(ViewType.ScrollView.self))
        XCTAssertFalse(try large.inspect().find(button: "Apply Selection").isDisabled())
        // Shorter than a 1,004 pt screen with room to spare; it was 3,973 pt.
        let size = NSHostingController(rootView: large).sizeThatFits(in: CGSize(width: 430, height: 1_004))
        XCTAssertLessThan(size.height, 700)

        let small = SavedSelectionRecallSheet(
            selection: selection,
            result: .init(matched: Array(matched.prefix(3)), unmatched: [], ambiguous: [], legacyUnsupported: false),
            onApply: {}, onCancel: {}
        )
        XCTAssertThrowsError(try small.inspect().find(ViewType.ScrollView.self), "A short list keeps its plain layout")

        let empty = SavedSelectionRecallSheet(
            selection: selection,
            result: .init(matched: [], unmatched: [], ambiguous: [], legacyUnsupported: false),
            onApply: { XCTFail("Nothing to apply") }, onCancel: {}
        )
        XCTAssertTrue(try empty.inspect().find(button: "Apply Selection").isDisabled())
    }

    // MARK: - A09-3 and L11-9: the built-in preset can be restored

    func testDeletedBuiltInPresetCanBeRestoredFromSettings() throws {
        let defaults = makeDefaults()
        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(store.remove(.globalProtect))
        // A stored empty list is valid, so the next launch had no way back.
        let relaunched = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(relaunched.presets.isEmpty)
        XCTAssertFalse(relaunched.isReadOnlyAfterCorruption)

        let view = settingsView(defaults, tab: .watchedApps, watchedApps: relaunched)
        try view.inspect().find(button: "Restore Built-in GlobalProtect Preset").tap()
        XCTAssertEqual(relaunched.presets, [.globalProtect])
        XCTAssertEqual(WatchedAppsStore(userDefaults: defaults, key: "presets").presets.map(\.id),
                       [WatchedAppPreset.globalProtectID])
        XCTAssertThrowsError(try view.inspect().find(button: "Restore Built-in GlobalProtect Preset"),
                             "Offered only while the built-in preset is missing")
    }

    func testRestoringTheBuiltInPresetNamesALookAlikeAndIsRefusedInRecovery() throws {
        let defaults = makeDefaults()
        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(store.remove(.globalProtect))
        XCTAssertTrue(store.add(WatchedAppPreset(
            displayName: "GlobalProtect", mainProcessName: "GlobalProtect", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/GlobalProtect Copy.app"
        )))
        let view = settingsView(defaults, tab: .watchedApps, watchedApps: store)
        try view.inspect().find(button: "Restore Built-in GlobalProtect Preset").tap()
        let message = "The built-in GlobalProtect preset cannot be restored. A preset named “GlobalProtect” already exists. Delete or change that preset first."
        XCTAssertEqual(store.validationError, message)
        XCTAssertFalse(store.presets.contains { $0.id == WatchedAppPreset.globalProtectID })

        defaults.set(Data([0xFF]), forKey: "corrupt")
        let corrupt = WatchedAppsStore(userDefaults: defaults, key: "corrupt")
        XCTAssertFalse(corrupt.restoreBuiltInPreset())
        XCTAssertEqual(defaults.data(forKey: "corrupt"), Data([0xFF]))
        let recoveryView = settingsView(defaults, tab: .watchedApps, watchedApps: corrupt)
        XCTAssertThrowsError(try recoveryView.inspect().find(button: "Restore Built-in GlobalProtect Preset"))
    }

    // MARK: - L11-9: deletions are confirmed

    func testDeletingAPresetAsksFirstAndExplainsWhatTheBuiltInTakesWithIt() throws {
        let defaults = makeDefaults()
        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(store.add(customPreset))
        let interactions = SettingsInteractionState()
        let view = settingsView(defaults, tab: .watchedApps, watchedApps: store, interactions: interactions)

        try button(labeled: "Delete preset GlobalProtect", in: view).tap()
        XCTAssertEqual(store.presets.count, 2, "Nothing is deleted before confirmation")
        var dialog = try presentedDialog(view)
        XCTAssertEqual(try dialog.title().string(), "Delete “GlobalProtect”?")
        XCTAssertTrue(try dialog.message().text().string().contains("Keep GlobalProtect Off and Disconnect controls"))
        try dialog.actions().find(button: "Cancel").tap()
        XCTAssertEqual(store.presets.count, 2)
        XCTAssertThrowsError(try presentedDialog(view))

        try button(labeled: "Delete preset Example", in: view).tap()
        dialog = try presentedDialog(view)
        XCTAssertEqual(try dialog.message().text().string(), "This cannot be undone.")
        try dialog.actions().find(button: "Delete Preset").tap()
        XCTAssertEqual(store.presets, [.globalProtect])
    }

    func testDeletingARuleAndClearingEventsAskFirst() throws {
        let defaults = makeDefaults()
        let events = (1...3).map {
            AutoStopEvent(timestamp: Date(timeIntervalSince1970: 1_000), processName: "Example", pid: Int32($0),
                          ruleID: UUID(), outcome: .logged, detail: "Reason \($0)")
        }
        defaults.set(try JSONEncoder().encode(events), forKey: "events")
        let store = rules(defaults)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        let interactions = SettingsInteractionState()
        let view = settingsView(defaults, tab: .autoStop, autoStopRules: store, interactions: interactions)

        try button(labeled: "Delete rule Example", in: view).tap()
        XCTAssertEqual(store.rules.count, 1)
        var dialog = try presentedDialog(view)
        XCTAssertEqual(try dialog.title().string(), "Delete the auto-stop rule for “Example”?")
        try dialog.actions().find(button: "Delete Rule").tap()
        XCTAssertTrue(store.rules.isEmpty)

        try button(labeled: "Clear all auto-stop events", in: view).tap()
        XCTAssertEqual(store.events.count, 3)
        dialog = try presentedDialog(view)
        XCTAssertEqual(try dialog.title().string(), "Clear all 3 auto-stop events?")
        try dialog.actions().find(button: "Clear Events").tap()
        XCTAssertTrue(store.events.isEmpty)
    }

    // MARK: - L11-9 and A11-10 (Saved menu): selection deletes and discards ask first

    private func savedMenu(_ view: TaskScopePopoverView, selection name: String) throws -> InspectableView<ViewType.Menu> {
        try view.inspect().find(ViewType.Menu.self, where: { try $0.labelView().text().string() == name })
    }

    func testDeletingASavedSelectionAsksFirstInTheWindowAndTheMenuBar() async throws {
        for menuBar in [false, true] {
            let target = Batch10.process(51)
            let fixture = await Batch10.fixture(processes: [target])
            defer { fixture.stores.cleanup() }
            XCTAssertTrue(fixture.stores.savedSelections.save(name: "Saved", processes: [target]))
            let state = ProcessConfirmationState()
            let presenter = UIMenuBarConfirmation(answer: true)
            let view = Batch10.popover(fixture, state: state, confirmer: menuBar ? presenter : nil)

            try savedMenu(view, selection: "Saved").find(button: "Delete…").tap()
            XCTAssertEqual(state.pendingSelectionDeletion?.name, "Saved")
            XCTAssertEqual(fixture.stores.savedSelections.selections.count, 1, "Nothing is deleted before confirmation")
            if menuBar {
                try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingSelectionDeletion)
                await state.waitForActions()
                XCTAssertEqual(presenter.requests.map(\.title), ["Delete the saved selection “Saved”?"])
            } else {
                try view.inspect().find(ViewType.ConfirmationDialog.self).actions().find(button: "Delete Selection").tap()
            }
            XCTAssertTrue(fixture.stores.savedSelections.selections.isEmpty)
            XCTAssertNil(state.pendingSelectionDeletion)
        }
    }

    func testSavedSelectionsResetPromisesABackupOnlyWhenOneExists() async throws {
        for menuBar in [false, true] {
            let target = Batch10.process(51)
            var fixture = await Batch10.fixture(processes: [target])
            defer { fixture.stores.cleanup() }
            let defaults = fixture.stores.defaults
            fillEverySlot(of: "unreadable", in: defaults)
            let unreadable = SavedSelectionsStore(userDefaults: defaults, key: "unreadable")
            XCTAssertTrue(unreadable.isReadOnlyAfterCorruption)
            XCTAssertFalse(unreadable.isRecoveryBackupPreserved)
            fixture.stores.savedSelections = unreadable
            let state = ProcessConfirmationState()
            let presenter = UIMenuBarConfirmation(answer: true)
            let view = Batch10.popover(fixture, state: state, confirmer: menuBar ? presenter : nil)

            XCTAssertThrowsError(try view.inspect().find(button: "Reset Saved Selections After Backup"))
            try view.inspect().find(button: "Discard Unreadable Saved Selections and Reset…").tap()
            XCTAssertNotNil(state.pendingSelectionsDiscard)
            XCTAssertTrue(unreadable.isReadOnlyAfterCorruption, "Nothing is discarded before confirmation")
            if menuBar {
                try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingSelectionsDiscard)
                await state.waitForActions()
                XCTAssertEqual(presenter.requests.map(\.confirmTitle), ["Discard and Reset"])
            } else {
                let dialog = try view.inspect().find(ViewType.ConfirmationDialog.self)
                XCTAssertTrue(try dialog.message().text().string().hasPrefix("Nothing was backed up"))
                try dialog.actions().find(button: "Discard and Reset").tap()
            }
            XCTAssertFalse(unreadable.isReadOnlyAfterCorruption)
        }

        // With a free slot the backup exists and the menu says so.
        var backedUp = await Batch10.fixture(processes: [])
        defer { backedUp.stores.cleanup() }
        backedUp.stores.defaults.set(Data([0xFF]), forKey: "backedUp")
        backedUp.stores.savedSelections = SavedSelectionsStore(userDefaults: backedUp.stores.defaults, key: "backedUp")
        XCTAssertTrue(backedUp.stores.savedSelections.isRecoveryBackupPreserved)
        XCTAssertNoThrow(try Batch10.popover(backedUp).inspect().find(button: "Reset Saved Selections After Backup"))
    }

    // MARK: - L10-10: rules can be duplicated and deleted without a context menu

    func testRuleRowsOfferVisibleDuplicateAndDelete() throws {
        let defaults = makeDefaults()
        let store = rules(defaults)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        let view = settingsView(defaults, tab: .autoStop, autoStopRules: store)
        try button(labeled: "Duplicate rule Example", in: view).tap()
        XCTAssertEqual(store.rules.count, 2)
        XCTAssertNoThrow(try button(labeled: "Delete rule Example", in: view))
    }

    // MARK: - L12-7: every retained event is visible

    func testRecentEventsListsEveryRetainedEvent() throws {
        let defaults = makeDefaults()
        let events = (1...120).map {
            AutoStopEvent(timestamp: Date(timeIntervalSince1970: 1_000), processName: "Event \($0)", pid: Int32($0),
                          ruleID: UUID(), outcome: .logged, detail: "Reason \($0)")
        }
        defaults.set(try JSONEncoder().encode(events), forKey: "events")
        let view = settingsView(defaults, tab: .autoStop)
        XCTAssertNoThrow(try view.inspect().find(text: "Reason 51"))
        XCTAssertNoThrow(try view.inspect().find(text: "Reason 120"))
    }

    // MARK: - L09-1 (Settings part, from batch 10): event PIDs are not grouped numbers

    func testEventHistoryShowsThePIDAsAPlainNumber() throws {
        let defaults = makeDefaults()
        let event = AutoStopEvent(timestamp: Date(timeIntervalSince1970: 1_000), processName: "Example", pid: 48_165,
                                  ruleID: UUID(), outcome: .logged, detail: "Logged")
        let line = SettingsView.eventTimeAndPID(event)
        XCTAssertTrue(line.hasSuffix(" · PID 48165"), line)
        defaults.set(try JSONEncoder().encode([event]), forKey: "events")
        XCTAssertNoThrow(try settingsView(defaults, tab: .autoStop).inspect().find(text: line))
    }

    // MARK: - L07-7: a refused rule change is reported on its row

    func testRefusedRuleToggleIsReportedOnItsOwnRow() throws {
        let defaults = makeDefaults()
        let store = rules(defaults)
        // Auto Stop without a path may be stored disabled, but not enabled.
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .kill, isEnabled: false)
        XCTAssertTrue(store.add(rule))
        let interactions = SettingsInteractionState()
        let view = settingsView(defaults, tab: .autoStop, autoStopRules: store, interactions: interactions)

        try view.inspect().find(ViewType.Toggle.self, where: {
            try $0.accessibilityLabel().string() == "Enable rule Example"
        }).tap()

        let reason = "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules."
        XCTAssertFalse(store.rules[0].isEnabled)
        XCTAssertEqual(interactions.ruleRowErrors[rule.id], reason)
        XCTAssertNil(store.validationError, "The shared message must not reappear under Add Rule")
        XCTAssertNil(interactions.addRuleError)
        XCTAssertNoThrow(try view.inspect().find(text: reason))
    }

    func testUpdatingAnUnknownRuleOrPresetSaysWhy() {
        let defaults = makeDefaults()
        let store = rules(defaults)
        XCTAssertFalse(store.update(AutoStopRule(processName: "Gone", runtimeMinutes: 5, action: .prompt)))
        XCTAssertEqual(store.validationError, "This auto-stop rule no longer exists.")
        let presets = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertFalse(presets.update(customPreset))
        XCTAssertEqual(presets.validationError, "This preset no longer exists.")
    }

    // MARK: - L09-20: an empty rule list says how to add one

    func testEmptyRuleListShowsHowToAddARule() throws {
        let defaults = makeDefaults()
        let store = rules(defaults)
        let view = settingsView(defaults, tab: .autoStop, autoStopRules: store)
        XCTAssertNoThrow(try view.inspect().find(text: SettingsView.noRulesMessage))
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        XCTAssertThrowsError(try view.inspect().find(text: SettingsView.noRulesMessage))
    }

    // MARK: - A13-14: row buttons name their preset or rule

    func testRowButtonsNameTheirPresetOrRule() throws {
        let defaults = makeDefaults()
        let presets = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(presets.add(customPreset))
        let watched = settingsView(defaults, tab: .watchedApps, watchedApps: presets)
        for label in ["Dry run GlobalProtect", "Dry run Example", "Edit preset Example"] {
            XCTAssertNoThrow(try button(labeled: label, in: watched), label)
        }
        let store = rules(defaults)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        let autoStop = settingsView(defaults, tab: .autoStop, autoStopRules: store)
        XCTAssertNoThrow(try button(labeled: "Edit rule Example", in: autoStop))
    }

    // MARK: - L09-14: empty lists are hidden and the toggle has a title

    func testPresetRowsHideEmptyListsAndTitleTheNotificationsToggle() throws {
        let defaults = makeDefaults()
        let presets = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(presets.remove(.globalProtect))
        XCTAssertTrue(presets.add(customPreset))
        let view = settingsView(defaults, tab: .watchedApps, watchedApps: presets)
        XCTAssertThrowsError(try view.inspect().find(textWhere: { text, _ in text.hasPrefix("Helpers:") }))
        XCTAssertThrowsError(try view.inspect().find(textWhere: { text, _ in text.hasPrefix("Protected:") }))
        let toggle = try view.inspect().find(ViewType.Toggle.self, where: {
            try $0.accessibilityLabel().string() == "Notifications for Example"
        })
        XCTAssertEqual(try toggle.labelView().text().string(), "Notify")

        var withLists = customPreset
        withLists.helperProcessNames = ["Example Helper"]
        withLists.protectedProcessNames = ["Example Daemon"]
        XCTAssertTrue(presets.update(withLists))
        XCTAssertNoThrow(try view.inspect().find(text: "Helpers: Example Helper"))
        XCTAssertNoThrow(try view.inspect().find(text: "Protected: Example Daemon"))
    }

    // MARK: - A13-15: recovery mode keeps the read-only preset actions

    func testPresetRecoveryKeepsDryRunAndSelfCheckButLocksEditing() throws {
        let defaults = makeDefaults()
        let builtIn = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchedAppPreset.globalProtect))
        defaults.set(try JSONSerialization.data(withJSONObject: [builtIn, ["unexpected": true]]), forKey: "presets")
        let presets = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(presets.isReadOnlyAfterCorruption)
        XCTAssertEqual(presets.presets.map(\.id), [WatchedAppPreset.globalProtectID])

        let view = settingsView(defaults, tab: .watchedApps, watchedApps: presets)
        XCTAssertFalse(try button(labeled: "Dry run GlobalProtect", in: view).isDisabled())
        XCTAssertFalse(try view.inspect().find(GlobalProtectCompatibilityButton.self).isDisabled())
        XCTAssertTrue(try button(labeled: "Delete preset GlobalProtect", in: view).isDisabled())
        XCTAssertTrue(try view.inspect().find(ViewType.Toggle.self, where: {
            try $0.accessibilityLabel().string() == "Notifications for GlobalProtect"
        }).isDisabled())
    }

    // MARK: - A13-11 and A13-20: import, export and editor handlers

    private func archive(_ presets: [WatchedAppPreset]) throws -> Data {
        try JSONEncoder().encode(WatchedAppsStore.PresetArchive(presets: presets))
    }

    func testImportRefusesAnOversizedFileBeforeReadingIt() {
        let store = WatchedAppsStore(userDefaults: makeDefaults(), key: "presets")
        let actions = PresetSettingsActions()
        actions.fileSize = { _ in WatchedAppsStore.maximumPresetArchiveBytes + 1 }
        actions.readFile = { _ in XCTFail("An oversized archive must not be read"); return Data() }
        actions.loadImport(from: URL(fileURLWithPath: "/nonexistent/presets.json"), into: store)
        XCTAssertEqual(actions.importError, "Preset archives must be 1 MB or smaller.")
        XCTAssertNil(actions.preview)
    }

    func testImportErrorsClearWhenANewImportStartsAndACommitReportsANeutralSummary() throws {
        let store = WatchedAppsStore(userDefaults: makeDefaults(), key: "presets")
        let actions = PresetSettingsActions()
        actions.fileSize = { _ in 10 }
        actions.readFile = { _ in Data("{\"unexpected\": true}".utf8) }
        let url = URL(fileURLWithPath: "/nonexistent/presets.json")
        actions.loadImport(from: url, into: store)
        XCTAssertEqual(actions.importError, "The file is not a recognized TaskScope preset archive.")
        XCTAssertNil(actions.preview)

        // Opening the importer again forgets the stale error.
        let view = settingsView(makeDefaults(), tab: .watchedApps, watchedApps: store, actions: actions)
        try view.inspect().find(button: "Import…").tap()
        XCTAssertNil(actions.importError)

        let second = WatchedAppPreset(displayName: "Second", mainProcessName: "Second", helperProcessNames: [],
                                      protectedProcessNames: [], appPath: "/Applications/Second.app")
        var duplicate = customPreset
        duplicate.id = UUID()
        let data = try archive([customPreset, second, duplicate])
        actions.readFile = { _ in data }
        actions.loadImport(from: url, into: store)
        let preview = try XCTUnwrap(actions.preview)
        XCTAssertEqual(preview.importableCount, 2)
        XCTAssertEqual(preview.rejectedCount, 1)

        // The preview sheet's Import button commits through the same handler.
        try view.importPreviewSheet.inspect().find(button: "Import 2 Presets").tap()
        XCTAssertNil(actions.preview)
        XCTAssertEqual(store.presets.map(\.displayName), ["GlobalProtect", "Example", "Second"])
        XCTAssertNil(actions.importError)
        XCTAssertEqual(actions.importSummary, "Imported 2 presets. 1 was rejected by validation.")
        XCTAssertNoThrow(try view.inspect().find(text: "Imported 2 presets. 1 was rejected by validation."))

        // A later change to the list makes that outcome stale.
        let form = WatchedPresetFormState()
        form.prepareForEditing(second)
        form.helpers = "Second Helper"
        XCTAssertTrue(actions.saveEditor(form, into: store))
        XCTAssertNil(actions.importSummary)
    }

    func testCommittingAnImportThatAddsNothingIsReportedAsAnError() throws {
        let store = WatchedAppsStore(userDefaults: makeDefaults(), key: "presets")
        let actions = PresetSettingsActions()
        actions.preview = store.previewImport([customPreset])
        XCTAssertTrue(store.add(customPreset))
        actions.commitImport(into: store)
        XCTAssertNil(actions.importSummary)
        XCTAssertEqual(actions.importError, "No presets were imported. 1 was rejected by validation.")
    }

    func testExportIsRefusedForUnreadablePresetsAndWritesTheArchiveOtherwise() throws {
        let defaults = makeDefaults()
        defaults.set(Data([0xFF]), forKey: "corrupt")
        let corrupt = WatchedAppsStore(userDefaults: defaults, key: "corrupt")
        let actions = PresetSettingsActions()
        var written: Data?
        actions.saveArchive = { written = $0 }
        actions.export(from: corrupt)
        XCTAssertNil(written)
        XCTAssertEqual(actions.exportError, "Preset data is unreadable, so there is nothing to export. Recover the backup noted above before resetting.")

        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        actions.export(from: store)
        XCTAssertNil(actions.exportError)
        XCTAssertEqual(try WatchedAppsStore.decodePresetArchive(XCTUnwrap(written)), [.globalProtect])
    }

    func testPresetEditorAddsNewPresetsAndUpdatesEditedOnes() throws {
        let store = WatchedAppsStore(userDefaults: makeDefaults(), key: "presets")
        let actions = PresetSettingsActions()
        let form = WatchedPresetFormState()
        form.prepareForNewPreset()
        form.displayName = "Example"
        form.mainProcess = "Example"
        form.appPath = "/Applications/Example.app"
        XCTAssertTrue(actions.saveEditor(form, into: store))
        XCTAssertNil(actions.editorError)
        let added = try XCTUnwrap(store.presets.first { $0.displayName == "Example" })

        form.prepareForEditing(added)
        form.helpers = "Example Helper"
        XCTAssertTrue(actions.saveEditor(form, into: store))
        XCTAssertEqual(store.presets.count, 2, "An edit must update in place")
        XCTAssertEqual(store.presets.first { $0.id == added.id }?.helperProcessNames, ["Example Helper"])

        form.prepareForNewPreset()
        form.displayName = "Example"
        form.mainProcess = "Other"
        form.appPath = "/Applications/Other.app"
        XCTAssertFalse(actions.saveEditor(form, into: store))
        XCTAssertEqual(actions.editorError, "A preset named “Example” already exists.")
        XCTAssertEqual(store.presets.count, 2)

        form.prepareForNewPreset()
        form.mainProcess = "Third"
        form.appPath = "relative/Third.app"
        XCTAssertFalse(actions.saveEditor(form, into: store))
        XCTAssertNotNil(actions.editorError)
        XCTAssertEqual(store.presets.count, 2)
    }

    // MARK: - A13-19: About shows a selectable version, or says why there is none

    func testAboutVersionIsSelectableAndADevelopmentBuildSaysItHasNone() throws {
        _ = NSApplication.shared // AboutView reads NSApp's icon.
        let packaged = try AboutView(versionInfo: ("1.2.3", "45")).inspect().find(text: "Version 1.2.3 (45)")
        XCTAssertTrue(try packaged.textSelectability())
        let bare = try AboutView(versionInfo: nil).inspect().find(text: "Development build (no bundle version)")
        XCTAssertTrue(try bare.textSelectability())
    }

    // MARK: - A13-18: onboarding covers the menu bar, the shortcut and permissions

    func testOnboardingMentionsTheMenuBarTheShortcutAndGlobalProtectPermissions() throws {
        _ = NSApplication.shared // OnboardingView reads NSApp's icon.
        func text(_ view: OnboardingView) throws -> String {
            try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }.joined(separator: "\n")
        }
        let enabled = try text(OnboardingView(hotkeyShortcut: "⌃⌥⌘T", onComplete: {}))
        for expected in ["menu bar", "press ⌃⌥⌘T anywhere", "Settings > Hotkey", "Accessibility",
                         "administrator approval", "Settings > Health", "Help > Welcome to TaskScope"] {
            XCTAssertTrue(enabled.contains(expected), expected)
        }
        let disabled = try text(OnboardingView(hotkeyShortcut: nil, onComplete: {}))
        XCTAssertFalse(disabled.contains("⌃⌥⌘T"))
        XCTAssertTrue(disabled.contains("Turn on a global shortcut in Settings > Hotkey."))
    }

    // MARK: - A10-8: the runtime threshold can be typed

    func testEveryRuleFormAcceptsATypedRuntimeWithinTheLimit() throws {
        let control = RuntimeMinutesControl(minutes: .constant(5))
        let field = try control.inspect().find(ViewType.TextField.self)
        XCTAssertEqual(try field.labelView().text().string(), "Runtime minutes")
        XCTAssertNoThrow(try control.inspect().find(text: "1–1440"))
        XCTAssertEqual(RuntimeMinutesControl.clamped(0), 1)
        XCTAssertEqual(RuntimeMinutesControl.clamped(480), 480)
        XCTAssertEqual(RuntimeMinutesControl.clamped(5_000), AutoStopRulesStore.maximumRuntimeMinutes)

        let editor = AutoStopRuleEditorSheet(rule: AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt),
                                             onSave: { _ in }, onCancel: {})
        XCTAssertNoThrow(try editor.inspect().find(RuntimeMinutesControl.self))
        let quick = QuickAutoStopRuleSheet(process: process(), existingRule: nil,
                                          onSave: { _, _, _ in nil }, onCancel: {})
        XCTAssertNoThrow(try quick.inspect().find(RuntimeMinutesControl.self))
        XCTAssertNoThrow(try settingsView(makeDefaults(), tab: .autoStop).inspect().find(RuntimeMinutesControl.self))
    }

    // MARK: - L10-15: sheet keys and footers

    /// The footer row that holds Cancel, in order: button titles, "|" for a
    /// Spacer and "?" for anything else.
    private func footerLayout<V: View>(of view: V) throws -> [String] {
        for stack in try view.inspect().findAll(ViewType.HStack.self) {
            let items = stack.map { child -> String in
                if (try? child.spacer()) != nil { return "|" }
                return (try? child.button().labelView().text().string()) ?? "?"
            }
            if items.contains("Cancel") { return items }
        }
        throw NoDialog()
    }

    func testEditingSheetsPutCancelBesideTheirActionAtTheBottomRight() throws {
        var cancelled = 0
        let quickRule = QuickAutoStopRuleSheet(process: process(), existingRule: nil,
                                              onSave: { _, _, _ in nil }, onCancel: { cancelled += 1 })
        let quickPreset = QuickWatchedPresetSheet(draft: QuickWatchedPresetDraft(processes: [process()]),
                                                 onSave: { _ in nil }, onCancel: { cancelled += 1 })
        let save = SaveSelectionSheet(name: .constant("Name"), count: 1, validationError: nil,
                                      onSave: {}, onCancel: { cancelled += 1 })
        let rename = RenameSavedSelectionSheet(originalName: "Old", name: .constant("New"), validationError: nil,
                                               onSave: {}, onCancel: { cancelled += 1 })
        let editor = AutoStopRuleEditorSheet(rule: AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt),
                                             onSave: { _ in }, onCancel: { cancelled += 1 })
        XCTAssertEqual(Array(try footerLayout(of: quickRule).suffix(3)), ["|", "Cancel", "Add Rule"])
        XCTAssertEqual(Array(try footerLayout(of: quickPreset).suffix(3)), ["|", "Cancel", "Add Preset"])
        XCTAssertEqual(try footerLayout(of: save), ["|", "Cancel", "Save"])
        XCTAssertEqual(try footerLayout(of: rename), ["|", "Cancel", "Rename"])
        XCTAssertEqual(try footerLayout(of: editor), ["|", "Cancel", "Save"])
        for view in [try quickRule.inspect(), try quickPreset.inspect(), try save.inspect(),
                     try rename.inspect(), try editor.inspect()] {
            try view.find(button: "Cancel").tap()
        }
        XCTAssertEqual(cancelled, 5)
    }

    func testRuleEditorFieldsHaveVisibleLabels() throws {
        let editor = AutoStopRuleEditorSheet(rule: AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt),
                                             onSave: { _ in }, onCancel: {})
        // In a Form the title is a label beside the field, not a placeholder
        // that disappears once the field has text.
        let form = try editor.inspect().find(ViewType.Form.self)
        for label in ["Process name", "Executable path"] {
            XCTAssertNoThrow(try form.find(ViewType.TextField.self, where: {
                try $0.labelView().text().string() == label
            }), label)
        }
    }

    func testReadOnlySheetsCloseWithEscapeAsWellAsReturn() throws {
        let dryRun = settingsView(makeDefaults(), tab: .watchedApps).lifecycleDryRunSheet(for: .globalProtect)
        XCTAssertNoThrow(try dryRun.inspect().find(button: "Done"))
        XCTAssertThrowsError(try dryRun.inspect().find(button: "Close"))
        XCTAssertNoThrow(try dryRun.inspect().vStack().callOnExitCommand())

        var closed = 0
        let compatibility = GlobalProtectCompatibilitySheet(keepOffRequested: false, onClose: { closed += 1 })
        try compatibility.inspect().vStack().callOnExitCommand()
        XCTAssertEqual(closed, 1)

        let preview = try SupportDiagnosticsPreview(report: SupportDiagnosticsReport.batch11Sample())
        let diagnostics = SupportDiagnosticsPreviewSheet(preview: preview, onClose: { closed += 1 })
        try diagnostics.inspect().vStack().callOnExitCommand()
        XCTAssertEqual(closed, 2)
    }

    // MARK: - L09-17: the General sliders have names and units

    func testGeneralSlidersHaveNamesAndUnits() throws {
        let settings = SettingsStore(userDefaults: makeDefaults(), key: "settings")
        let sliders = try GeneralSettingsTab(settings: settings, notificationService: .shared)
            .inspect().findAll(ViewType.Slider.self)
        XCTAssertEqual(try sliders.map { try $0.accessibilityLabel().string() },
                       ["Watched status interval", "CPU highlight threshold", "Memory highlight threshold"])
        XCTAssertEqual(try sliders.map { try $0.accessibilityValue().string() },
                       ["10 seconds", "30 percent", "1024 megabytes"])
    }

    // MARK: - A11-11: safeguards that had no test

    func testGeneralTabIsLockedWhileSettingsAreReadOnly() throws {
        let defaults = makeDefaults()
        defaults.set(Data([0xFF]), forKey: "settings")
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        let tab = try GeneralSettingsTab(settings: settings, notificationService: .shared).inspect()
        let sliders = tab.findAll(ViewType.Slider.self)
        let toggles = tab.findAll(ViewType.Toggle.self)
        XCTAssertEqual(sliders.count, 3)
        XCTAssertFalse(toggles.isEmpty)
        for control in sliders { XCTAssertTrue(control.isDisabled()) }
        for control in toggles { XCTAssertTrue(control.isDisabled()) }
        XCTAssertTrue(try tab.find(ViewType.Stepper.self).isDisabled())
    }

    func testSearchTextIsCappedAndCPUThresholdIsClampedAtBothEnds() {
        let defaults = makeDefaults()
        let settings = SettingsStore(userDefaults: defaults, key: "settings", searchPersistenceDelay: 3_600)
        settings.cpuHighlightThreshold = 1_000
        XCTAssertEqual(settings.cpuHighlightThreshold, 100)
        settings.cpuHighlightThreshold = 0
        XCTAssertEqual(settings.cpuHighlightThreshold, 1)
        settings.searchText = String(repeating: "x", count: 600)
        XCTAssertEqual(settings.searchText.count, 500)
        // Debounced: nothing is written until the quiet period, or a flush at quit.
        XCTAssertEqual(SettingsStore(userDefaults: defaults, key: "settings").searchText, "")
        settings.flushPendingWrites()
        XCTAssertEqual(SettingsStore(userDefaults: defaults, key: "settings").searchText.count, 500)
    }

    func testSaveAndRenameStayDisabledForBlankOrUnchangedNames() throws {
        for blank in ["", "   ", "\n", " \t\n "] {
            let save = SaveSelectionSheet(name: .constant(blank), count: 1, validationError: nil, onSave: {}, onCancel: {})
            XCTAssertTrue(try save.inspect().find(button: "Save").isDisabled(), "Save with \(blank.debugDescription)")
            let rename = RenameSavedSelectionSheet(originalName: "Original", name: .constant(blank), validationError: nil,
                                                   onSave: {}, onCancel: {})
            XCTAssertTrue(try rename.inspect().find(button: "Rename").isDisabled(), "Rename with \(blank.debugDescription)")
        }
        let unchanged = RenameSavedSelectionSheet(originalName: "Original", name: .constant("Original"),
                                                  validationError: nil, onSave: {}, onCancel: {})
        XCTAssertTrue(try unchanged.inspect().find(button: "Rename").isDisabled())
        let save = SaveSelectionSheet(name: .constant("Name"), count: 1, validationError: nil, onSave: {}, onCancel: {})
        XCTAssertFalse(try save.inspect().find(button: "Save").isDisabled())
    }

    // MARK: - A11-10: a reset never promises a backup that does not exist

    private func fillEverySlot(of key: String, in defaults: UserDefaults) {
        defaults.set(Data([0xFF, 0x00]), forKey: key)
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            defaults.set(Data([UInt8(slot)]), forKey: "\(key).corruptBackup" + (slot == 1 ? "" : ".\(slot)"))
        }
    }

    func testEveryStoreReportsWhetherItsUnreadableDataIsBackedUp() {
        let full = makeDefaults()
        for key in ["settings", "presets", "rules", "events", "selections"] {
            fillEverySlot(of: key, in: full)
        }
        let hotkeyKey = "hotkey"
        full.set("unreadable", forKey: hotkeyKey)
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            full.set(Data([UInt8(slot)]), forKey: "\(hotkeyKey).corruptBackup" + (slot == 1 ? "" : ".\(slot)"))
        }
        let settings = SettingsStore(userDefaults: full, key: "settings")
        let presets = WatchedAppsStore(userDefaults: full, key: "presets")
        let autoStop = rules(full)
        let selections = SavedSelectionsStore(userDefaults: full, key: "selections")
        let hotkey = HotkeyManager(defaults: full, defaultsKey: hotkeyKey, backend: Batch11HotkeyBackend())
        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        XCTAssertFalse(settings.isRecoveryBackupPreserved)
        XCTAssertFalse(presets.isRecoveryBackupPreserved)
        XCTAssertFalse(autoStop.isRulesRecoveryBackupPreserved)
        XCTAssertFalse(autoStop.isEventsRecoveryBackupPreserved)
        XCTAssertFalse(selections.isRecoveryBackupPreserved)
        XCTAssertTrue(hotkey.isReadOnlyAfterCorruption)
        XCTAssertFalse(hotkey.isRecoveryBackupPreserved)

        let free = makeDefaults()
        for key in ["settings", "presets", "rules", "events", "selections"] {
            free.set(Data([0xFF, 0x00]), forKey: key)
        }
        free.set("unreadable", forKey: hotkeyKey)
        XCTAssertTrue(SettingsStore(userDefaults: free, key: "settings").isRecoveryBackupPreserved)
        XCTAssertTrue(WatchedAppsStore(userDefaults: free, key: "presets").isRecoveryBackupPreserved)
        XCTAssertTrue(rules(free).isRulesRecoveryBackupPreserved)
        XCTAssertTrue(rules(free).isEventsRecoveryBackupPreserved)
        XCTAssertTrue(SavedSelectionsStore(userDefaults: free, key: "selections").isRecoveryBackupPreserved)
        XCTAssertTrue(HotkeyManager(defaults: free, defaultsKey: hotkeyKey, backend: Batch11HotkeyBackend())
            .isRecoveryBackupPreserved)
    }

    func testResetWithoutABackupSaysSoAndAsksFirst() throws {
        var resets = 0
        let preserved = RecoveryResetButton(subject: "Settings", isBackupPreserved: true) { resets += 1 }
        try preserved.inspect().find(button: "Reset Settings After Backup").tap()
        XCTAssertEqual(resets, 1)

        let unpreserved = RecoveryResetButton(subject: "Settings", isBackupPreserved: false) { resets += 1 }
        XCTAssertThrowsError(try unpreserved.inspect().find(button: "Reset Settings After Backup"))
        try unpreserved.inspect().find(button: "Discard Unreadable Settings and Reset").tap()
        XCTAssertEqual(resets, 1, "Discarding needs confirmation")

        let confirming = RecoveryResetButton(subject: "Settings", isBackupPreserved: false,
                                             isConfirmingDiscard: true) { resets += 1 }
        let dialog = try confirming.inspect().button().confirmationDialog()
        XCTAssertEqual(try dialog.title().string(), "Discard the unreadable settings?")
        XCTAssertTrue(try dialog.message().text().string().hasPrefix("Nothing was backed up"))
        try dialog.actions().find(button: "Discard and Reset").tap()
        XCTAssertEqual(resets, 2)
    }

    func testSettingsRecoveryButtonFollowsTheBackupState() throws {
        let defaults = makeDefaults()
        fillEverySlot(of: "settings", in: defaults)
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let tab = try GeneralSettingsTab(settings: settings, notificationService: .shared).inspect()
        XCTAssertNoThrow(try tab.find(button: "Discard Unreadable Settings and Reset"))
        XCTAssertThrowsError(try tab.find(button: "Reset Settings After Backup"))
    }
}

private final class Batch11HotkeyBackend: HotkeyRegistrationBackend {
    func installEventHandler(for manager: HotkeyManager) -> OSStatus { noErr }
    func register(keyCode: UInt32, modifiers: UInt32, identifier: EventHotKeyID) -> (status: OSStatus, reference: EventHotKeyRef?) {
        (noErr, OpaquePointer(bitPattern: 1))
    }
    func unregister(_ reference: EventHotKeyRef) {}
}

private extension SupportDiagnosticsReport {
    static func batch11Sample() -> SupportDiagnosticsReport {
        .init(
            version: "1.0.0", build: "3", macOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            capturedAt: Date(timeIntervalSince1970: 1_000),
            permissions: .init(notifications: .denied, notificationsEnabledInApp: false,
                               accessibilityGranted: false, launchAtLogin: .off),
            selectedPreset: nil,
            recentLifecycleFailures: []
        )
    }
}
