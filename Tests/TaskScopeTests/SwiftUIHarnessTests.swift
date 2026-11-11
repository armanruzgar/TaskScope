import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class SwiftUIHarnessTests: XCTestCase {
    func testGlobalProtectQuitConfirmationsAndDryRunOnlyUnloadInterfaceAgent() {
        for action in [ProcessConfirmationState.PresetAction.quitApp, .quitHelpers] {
            let message = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: .globalProtect, action: action))
            XCTAssertTrue(message.contains("com.paloaltonetworks.gp.pangpa"))
            XCTAssertFalse(message.contains("com.paloaltonetworks.gp.pangps"))
        }
        let operations = SettingsView.lifecycleDryRunOperations(for: .globalProtect)
            .filter { $0.hasPrefix("Quit App, Quit Helpers") }
        XCTAssertEqual(operations.count, 1)
        XCTAssertTrue(operations[0].contains("com.paloaltonetworks.gp.pangpa"))
        XCTAssertFalse(operations[0].contains("com.paloaltonetworks.gp.pangps"))
    }

    func testQuickRuleEnablesMigratedAutoStopWhenSupplyingPath() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        let legacy = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .kill)
        let migrated = try XCTUnwrap(AutoStopRuleValidation.validateStored([legacy]).rules.first)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertTrue(store.add(migrated))
        let outcome = QuickAutoStopRuleSaver.save(
            into: store, processName: "Example", observedProcessName: "Example",
            observedExecutablePath: "/Applications/Example.app/Contents/MacOS/Example",
            runtimeMinutes: 5, action: .kill, existingRule: store.rules[0]
        )
        XCTAssertNil(outcome.error)
        XCTAssertTrue(store.rules[0].isEnabled)
        XCTAssertEqual(store.rules[0].executablePath, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(outcome.statusMessage, "Enabled auto-stop rule for Example.")
    }

    func testQuickRuleReportsWhenUpdatedRuleRemainsDisabled() async {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        for action in [AutoStopRule.Action.prompt, .kill] {
            let rule = AutoStopRule(processName: "Example", executablePath: "/Example",
                                   runtimeMinutes: 5, action: action, isEnabled: false)
            XCTAssertTrue(store.add(rule))
            let outcome = QuickAutoStopRuleSaver.save(
                into: store, processName: "Example", observedProcessName: "Example",
                observedExecutablePath: "/Example", runtimeMinutes: 9, action: action,
                existingRule: store.rules[0]
            )
            XCTAssertNil(outcome.error)
            XCTAssertFalse(store.rules[0].isEnabled)
            XCTAssertEqual(outcome.statusMessage, "Updated disabled auto-stop rule for Example.")
            XCTAssertTrue(store.remove(store.rules[0]))
        }
    }

    func testRecallReadFailureReportsErrorInsteadOfMissingProcesses() async throws {
        let target = process(pid: 71, parentPID: 1, name: "Example")
        for initial in [[], [target]] {
            let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
                .success(initial), .failure(.commandFailed("ps timed out"))
            ]))
            defer { fixture.stores.cleanup() }
            XCTAssertTrue(fixture.stores.savedSelections.save(name: "Saved", processes: [target]))
            let confirmation = ProcessConfirmationState()
            let view = makePopover(fixture: fixture, confirmationState: confirmation)
            try view.inspect().find(button: "Preview & Recall…").tap()
            await confirmation.waitForActions()
            XCTAssertEqual(fixture.manager.message, "Could not preview saved selection: ps timed out.")
            XCTAssertNil(confirmation.pendingRecallSelection)
            XCTAssertNil(confirmation.pendingRecallResult)
        }
    }

    func testBackgroundReadFailureKeepsUnloadedProcessesTabIdle() async throws {
        let inventory = UIScriptedInventory(results: [.failure(.commandFailed("ps timed out"))])
        let fixture = await makeFixture(inventory: inventory, loadList: false)
        defer { fixture.stores.cleanup() }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(fixture.manager.processLoadError, "ps timed out")
        XCTAssertFalse(fixture.manager.hasAttemptedProcessListLoad)
        let inspected = try makePopover(fixture: fixture, confirmationState: ProcessConfirmationState()).inspect()
        XCTAssertNoThrow(try inspected.find(text: "Idle Until Needed"))
        XCTAssertThrowsError(try inspected.find(text: "Process List Unavailable"))
    }

    /// A watched-status read does not replace the rows, so it must not hide the
    /// stale-list banner; only a list load that succeeds does.
    func testSuccessfulWatchedReadKeepsStaleListBannerUntilTheListReloads() async throws {
        let target = process(pid: 71, parentPID: 1, name: "Example")
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .success([target]), .failure(.commandFailed("ps timed out")), .success([target]), .success([target])
        ]))
        defer { fixture.stores.cleanup() }
        let loaded = await fixture.manager.loadProcessList(showMessage: false)
        XCTAssertFalse(loaded)
        let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState())
        XCTAssertNoThrow(try view.inspect().find(text: "Process list is stale"))
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        XCTAssertNil(fixture.manager.processLoadError)
        XCTAssertEqual(fixture.manager.processListLoadError, "ps timed out")
        XCTAssertNoThrow(try view.inspect().find(text: "Process list is stale"))
        let reloaded = await fixture.manager.loadProcessList(showMessage: false)
        XCTAssertTrue(reloaded)
        XCTAssertNil(fixture.manager.processListLoadError)
        XCTAssertThrowsError(try view.inspect().find(text: "Process list is stale"))
    }

    func testSuccessfulWatchedReadKeepsFailedFirstLoadState() async throws {
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .failure(.commandFailed("ps timed out")), .success([])
        ]))
        defer { fixture.stores.cleanup() }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        XCTAssertFalse(fixture.manager.hasLoadedProcessList)
        let inspected = try makePopover(fixture: fixture, confirmationState: ProcessConfirmationState()).inspect()
        XCTAssertNoThrow(try inspected.find(text: "Process List Unavailable"))
        XCTAssertNoThrow(try inspected.find(text: "ps timed out."))
    }

    /// Editing a preset while its confirmation is open must drop the pending
    /// action, so confirming cannot signal names removed from the preset.
    func testEditingAPresetWhileItsConfirmationIsPendingClearsIt() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.watchedApps
        var preset = WatchedAppPreset(displayName: "Editor", mainProcessName: "Editor",
                                      helperProcessNames: ["Editor Helper", "Editor Agent"], protectedProcessNames: [],
                                      appPath: "/Applications/Editor.app")
        XCTAssertTrue(store.add(preset))
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)

        confirmation.requestPresetAction(.quitHelpers, preset: try XCTUnwrap(store.presets.first { $0.id == preset.id }))
        let unchanged = store.presets
        try view.inspect().vStack().callOnChange(oldValue: unchanged, newValue: unchanged)
        XCTAssertNotNil(confirmation.pendingPresetAction, "an unrelated presets change keeps the confirmation")

        preset.helperProcessNames = ["Editor Helper"]
        XCTAssertTrue(store.update(preset))
        try view.inspect().vStack().callOnChange(oldValue: unchanged, newValue: store.presets)
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testConfiguredPresetsAndUnknownHeaderAppearBeforeTheFirstRead() async throws {
        let fixture = await makeFixture(inventory: UIInventory(processes: []), loadList: false)
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        for style in [TaskScopePresentationStyle.expandedWindow, .menuBarCompact] {
            let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState(), presentationStyle: style)
            let inspected = try view.inspect()
            XCTAssertEqual(inspected.findAll(PresetCard.self).count, fixture.stores.watchedApps.presets.count)
            XCTAssertNoThrow(try inspected.find(TaskScopeHeaderView.self).find(text: "Unknown"))
            XCTAssertThrowsError(try inspected.find(TaskScopeHeaderView.self).find(text: "Quiet"))
            XCTAssertThrowsError(try inspected.find(text: "No watched apps configured. Add presets in Settings."))
        }
    }

    func testFirstWatchedReadFailureOffersRetryAndClearsUnknownAfterSuccess() async throws {
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .failure(.commandFailed("ps unavailable")), .success([])
        ]), loadList: false)
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        XCTAssertEqual(try view.inspect().findAll(PresetCard.self).count, 1)
        XCTAssertNoThrow(try view.inspect().find(text: "ps unavailable."))
        XCTAssertNoThrow(try view.inspect().find(TaskScopeHeaderView.self).find(text: "Unknown"))
        try view.inspect().find(button: "Retry").tap()
        await confirmation.waitForActions()
        XCTAssertNil(fixture.manager.processLoadError)
        XCTAssertNoThrow(try view.inspect().find(TaskScopeHeaderView.self).find(text: "Quiet"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
    }

    func testVerificationFailureDoesNotShowAWatchedStatusBanner() async throws {
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .success([]), .failure(.commandFailed("verification failed"))
        ]), loadList: false)
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        await fixture.manager.batchTerminate([process(pid: 42, parentPID: 1, name: "Example").identity])
        XCTAssertNotNil(fixture.manager.processLoadError)
        let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState())
        XCTAssertThrowsError(try view.inspect().find(text: "Watched status is stale"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
    }

    func testFailedWatchedRefreshMarksLastObservationStale() async throws {
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .success([]), .failure(.commandFailed("later read failed")), .success([])
        ]), loadList: false)
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        XCTAssertNoThrow(try view.inspect().find(TaskScopeHeaderView.self).find(text: "Stale"))
        XCTAssertNoThrow(try view.inspect().find(text: "Watched status is stale"))
        XCTAssertNoThrow(try view.inspect().find(text: "later read failed."))
        XCTAssertEqual(try view.inspect().findAll(PresetCard.self).count, 1)
        try view.inspect().find(button: "Retry").tap()
        await confirmation.waitForActions()
        XCTAssertNoThrow(try view.inspect().find(TaskScopeHeaderView.self).find(text: "Quiet"))
        XCTAssertThrowsError(try view.inspect().find(text: "Watched status is stale"))
    }

    func testPresetCardsFollowEditsAndDeletionWhenRefreshFails() async throws {
        let fixture = await makeFixture(inventory: UIScriptedInventory(results: [
            .success([]), .failure(.commandFailed("ps unavailable"))
        ]), loadList: false)
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.watchedApps
        var preset = WatchedAppPreset(displayName: "Before", mainProcessName: "Before",
                                      helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Before.app")
        XCTAssertTrue(store.add(preset))
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { store.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        let oldCard = try XCTUnwrap(view.inspect().findAll(PresetCard.self).first {
            try $0.actualView().snapshot.preset.id == preset.id
        }).actualView()
        preset.displayName = "After"
        preset.mainProcessName = "After"
        preset.appPath = "/Applications/After.app"
        XCTAssertTrue(store.update(preset))
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        XCTAssertNoThrow(try view.inspect().find(text: "After"))
        XCTAssertThrowsError(try view.inspect().find(text: "Before"))
        oldCard.onQuitApp()
        XCTAssertEqual(confirmation.pendingPresetAction?.preset, preset)
        confirmation.clearPresetAction()
        oldCard.onQuitHelpers()
        XCTAssertEqual(confirmation.pendingPresetAction?.preset, preset)
        confirmation.clearPresetAction()
        XCTAssertTrue(store.remove(preset))
        XCTAssertThrowsError(try view.inspect().find(text: "After"))
        oldCard.onQuitAll()
        XCTAssertNil(confirmation.pendingPresetAction)
    }

    func testProcessCountRevealsTruncationWithAndWithoutSearch() async throws {
        let fixture = await makeFixture(processes: [
            process(pid: 81, parentPID: 1, name: "WorkerA"),
            process(pid: 82, parentPID: 1, name: "WorkerB"),
            process(pid: 83, parentPID: 1, name: "Other")
        ])
        defer { fixture.stores.cleanup() }
        fixture.manager.processListLimitProvider = { 1 }
        for style in [TaskScopePresentationStyle.expandedWindow, .menuBarCompact] {
            fixture.stores.settings.searchText = ""
            let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState(), presentationStyle: style)
            XCTAssertNoThrow(try view.inspect().find(text: "Showing 1 of 3 processes"))
            fixture.stores.settings.searchText = "Worker"
            XCTAssertNoThrow(try view.inspect().find(text: "Showing 1 of 2 matches"))
            fixture.stores.settings.searchText = "WorkerA"
            XCTAssertNoThrow(try view.inspect().find(text: "1 match"))
            XCTAssertThrowsError(try view.inspect().find(text: "Showing 1 of 1 match"))
        }
    }

    func testProcessToolbarSizesPickersToContentAndWrapsSelectionControls() async throws {
        let target = process(pid: 84, parentPID: 1, name: "Selected")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }
        fixture.manager.select([target])
        for style in [TaskScopePresentationStyle.expandedWindow, .menuBarCompact] {
            let inspected = try makePopover(
                fixture: fixture,
                confirmationState: ProcessConfirmationState(),
                presentationStyle: style
            ).inspect()

            // A fixed width shared with a visible label cut "CPU" to "C..." on macOS 26.
            let sort = try inspected.find(ViewType.Picker.self) {
                try $0.labelView().text().string() == "Sort"
            }
            XCTAssertTrue(sort.labelsHidden())
            XCTAssertTrue(try sort.fixedSize().horizontal)
            XCTAssertThrowsError(try sort.fixedWidth())
            XCTAssertEqual(try sort.help().string(), "Sort By")
            for key in ProcessSortKey.allCases {
                XCTAssertNoThrow(try sort.find(text: key.label))
            }

            let filter = try inspected.find(ViewType.Picker.self) {
                try $0.labelView().text().string() == "Filter"
            }
            XCTAssertTrue(try filter.fixedSize().horizontal)
            XCTAssertThrowsError(try filter.fixedWidth())

            // The fallback row keeps every selection control at full width.
            let wrapped = try inspected.find(ViewType.ViewThatFits.self).vStack(1).hStack(1)
            XCTAssertNoThrow(try wrapped.find(ViewType.Menu.self) {
                try $0.accessibilityLabel().string() == "Actions for 1 selected process"
            })
            XCTAssertNoThrow(try wrapped.find(button: "Clear"))
        }
    }

    func testUserProtectedProcessBadgeMatchesServicesHeader() throws {
        let snapshot = WatchedAppSnapshot(preset: .globalProtect, runningNames: [],
                                          unprivilegedProtectedNames: ["PanGPS"])
        let card = PresetCard(snapshot: snapshot, onOpen: {}, onQuitApp: {}, onQuitHelpers: {},
                              onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true,
                              onKeepOffChanged: { _ in })
        XCTAssertEqual([snapshot].aggregateStatus, .protectedOnly)
        XCTAssertNoThrow(try card.inspect().find(text: "Services"))
        XCTAssertThrowsError(try card.inspect().find(text: "Quiet"))
        XCTAssertEqual(try card.inspect().vStack().hStack(0).hStack(2).shape(0).fillShapeStyle(Color.self), .orange)
    }

    func testOwnProcessCannotRequestStopFromContextMenuOrReturn() async throws {
        let own = process(pid: ProcessInfo.processInfo.processIdentifier, parentPID: 1, name: "TaskScope")
        var other = process(pid: 71, parentPID: 1, name: "Example")
        // "Watch This Process…" is offered only for the user's own app processes.
        other.uid = getuid()
        let fixture = await makeFixture(processes: [own, other])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        for title in ["Stop…", "Force Stop…", "Create Auto-Stop Rule…", "Watch This Process…"] {
            XCTAssertTrue(try view.processContextMenu(for: own).inspect().find(button: title).isDisabled())
            XCTAssertFalse(try view.processContextMenu(for: other).inspect().find(button: title).isDisabled())
        }
        view.requestKeyboardTermination(pid: own.pid)
        XCTAssertNil(confirmation.pendingTermination)
        view.requestKeyboardTermination(pid: other.pid)
        XCTAssertEqual(confirmation.pendingTermination?.process.identity, other.identity)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testKeepOffBadgeShowsEnforcementWhileCurrentUserAgentRemains() throws {
        let snapshot = WatchedAppSnapshot(
            preset: .globalProtect,
            runningNames: [],
            unprivilegedProtectedNames: ["PanGPS"],
            hasCurrentUserLaunchAgent: true
        )
        let card = PresetCard(
            snapshot: snapshot,
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in }
        )
        XCTAssertNoThrow(try card.inspect().find(text: "Service running"))
        XCTAssertThrowsError(try card.inspect().find(text: "Enforcing"))
        XCTAssertThrowsError(try card.inspect().find(text: "Kept Off"))
    }

    func testKeepOffShowsRunningSystemServiceAndOffersExplicitRetry() throws {
        var requested = false
        let card = PresetCard(
            snapshot: WatchedAppSnapshot(preset: .globalProtect, runningNames: ["PanGPS"]),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { requested = $0 }
        )
        XCTAssertNoThrow(try card.inspect().find(text: "Service running"))
        XCTAssertThrowsError(try card.inspect().find(text: "Off requested"))
        try card.inspect().find(button: "Apply Keep Off…").tap()
        XCTAssertTrue(requested)
    }

    func testLifecycleDryRunListsConfiguredTargetsWithoutPerformingActions() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: ["ExampleDaemon"],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [
                UserLaunchAgentJob(
                    label: "example.agent",
                    plistPath: "/Library/LaunchAgents/example.agent.plist"
                )
            ]
        )

        let operations = SettingsView.lifecycleDryRunOperations(for: preset)

        XCTAssertTrue(operations.contains { $0.contains("/Applications/Example.app") })
        XCTAssertTrue(operations.contains { $0.contains("example.agent") })
        XCTAssertTrue(operations.contains { $0.contains("ExampleHelper") })
        XCTAssertTrue(operations.contains { $0.contains("Never signal") && $0.contains("ExampleDaemon") })

        let globalProtectOperations = SettingsView.lifecycleDryRunOperations(for: .globalProtect)
        XCTAssertTrue(globalProtectOperations.contains { $0.contains("Keep Off") })
        XCTAssertTrue(globalProtectOperations.contains {
            $0.contains("administrator approval only if needed") && $0.contains("system VPN service")
        })
        XCTAssertTrue(globalProtectOperations.contains { $0.contains("Open and turning Keep Off off restore the required VPN service and app") })
        XCTAssertTrue(globalProtectOperations.contains { $0.contains("preserve the separate system daemon disable override") })
    }

    func testQuickPresetPrefersTrustedExecutablePathOverReportedCommand() {
        var process = process(pid: 70, parentPID: 1, name: "Example")
        process.command = "/Applications/Forged.app/Contents/MacOS/Forged"
        process.executablePath = "/Applications/Real.app/Contents/MacOS/Real"

        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Example"),
            "/Applications/Real.app"
        )
        process.executablePath = nil
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Example"),
            ""
        )
    }

    /// The bundle is the last path component ending in `.app`, never the first
    /// `.app` substring, so `my.apps` and `Foo.application` do not truncate it.
    func testInferredAppPathMatchesTheLastBundleComponentNotTheFirstSubstring() {
        var process = process(pid: 70, parentPID: 1, name: "Tool")

        process.executablePath = "/Users/me/my.apps/Tool"
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Tool"),
            ""
        )
        process.executablePath = "/Applications/Foo.application/Bar.app/Contents/MacOS/Bar"
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Tool"),
            "/Applications/Foo.application/Bar.app"
        )
        process.executablePath = "/Applications/Outer.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Tool"),
            "/Applications/Outer.app/Contents/Frameworks/Helper.app"
        )
        process.executablePath = "/Applications/Weird.APP/Contents/MacOS/Weird"
        XCTAssertEqual(
            QuickWatchedPresetSheet.inferredAppPath(for: process, fallbackName: "Tool"),
            "/Applications/Weird.APP"
        )
    }

    /// The quick sheet opened in Create mode for one process must not rewrite
    /// another process's rule just because the typed name matches it.
    func testQuickRuleCreateWithACollidingNameDoesNotMutateTheExistingRule() async {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        let examplePath = "/Applications/Example.app/Contents/MacOS/Example"
        XCTAssertTrue(store.add(AutoStopRule(
            processName: "Example",
            executablePath: examplePath,
            runtimeMinutes: 5,
            action: .prompt
        )))
        let original = store.rules[0]
        let other = process(pid: 70, parentPID: 1, name: "Other")

        let collision = QuickAutoStopRuleSaver.save(
            into: store,
            processName: "Example",
            observedProcessName: other.name,
            observedExecutablePath: other.executablePath,
            runtimeMinutes: 9,
            action: .kill,
            existingRule: QuickAutoStopRuleSaver.existingRule(for: other, in: store)
        )

        XCTAssertEqual(
            collision.error,
            "An auto-stop rule for Example already exists. Right-click a process named Example to update it."
        )
        XCTAssertEqual(store.rules, [original], "Create mode must not overwrite the existing rule")

        let example = process(pid: 71, parentPID: 1, name: "Example")
        let update = QuickAutoStopRuleSaver.save(
            into: store,
            processName: "Example",
            observedProcessName: example.name,
            observedExecutablePath: example.executablePath,
            runtimeMinutes: 9,
            action: .kill,
            existingRule: QuickAutoStopRuleSaver.existingRule(for: example, in: store)
        )

        XCTAssertNil(update.error)
        XCTAssertEqual(update.statusMessage, "Updated auto-stop rule for Example.")
        XCTAssertEqual(store.rules.map(\.runtimeMinutes), [9])
        XCTAssertEqual(store.rules.map(\.executablePath), [examplePath])
    }

    /// Renaming the draft away from the right-clicked process must not bind the
    /// new rule to that process's binary, where it could never match.
    func testQuickRuleForARenamedProcessDoesNotCaptureTheObservedPath() async {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        let node = process(pid: 72, parentPID: 1, name: "node")

        let outcome = QuickAutoStopRuleSaver.save(
            into: store,
            processName: "python3",
            observedProcessName: node.name,
            observedExecutablePath: node.executablePath,
            runtimeMinutes: 5,
            action: .prompt,
            existingRule: nil
        )

        XCTAssertNil(outcome.error)
        XCTAssertEqual(store.rules.map(\.processName), ["python3"])
        XCTAssertEqual(store.rules.map(\.executablePath), [nil])
    }

    /// Updating only the minutes of a name-wide prompt rule must keep it
    /// name-wide instead of narrowing it to the right-clicked binary.
    func testQuickRuleUpdateKeepsANameWideRuleNameWide() async {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        let example = process(pid: 73, parentPID: 1, name: "Example")

        let outcome = QuickAutoStopRuleSaver.save(
            into: store,
            processName: "Example",
            observedProcessName: example.name,
            observedExecutablePath: example.executablePath,
            runtimeMinutes: 12,
            action: .prompt,
            existingRule: QuickAutoStopRuleSaver.existingRule(for: example, in: store)
        )

        XCTAssertNil(outcome.error)
        XCTAssertEqual(store.rules.map(\.runtimeMinutes), [12])
        XCTAssertEqual(store.rules.map(\.executablePath), [nil])
    }

    /// A stale list still has rows; when the filter matches none of them the
    /// filter empty state (with Clear Search & Filter) must show, not
    /// "Process List Unavailable".
    func testStaleListWithNoSearchMatchesShowsTheFilterEmptyState() async throws {
        let needle = process(pid: 71, parentPID: 1, name: "Needle")
        let inventory = UIScriptedInventory(results: [
            .success([needle]),
            .failure(.commandFailed("ps timed out"))
        ])
        let fixture = await makeFixture(inventory: inventory)
        defer { fixture.stores.cleanup() }
        await fixture.manager.loadProcessList(showMessage: false)
        XCTAssertEqual(fixture.manager.processLoadError, "ps timed out", "precondition: stale list")
        fixture.stores.settings.searchText = "nomatch"

        let inspected = try makePopover(fixture: fixture, confirmationState: ProcessConfirmationState()).inspect()

        XCTAssertNoThrow(try inspected.find(text: "No Matching Processes"))
        XCTAssertNoThrow(try inspected.find(button: "Clear Search & Filter"))
        XCTAssertNoThrow(try inspected.find(text: "Process list is stale"))
        XCTAssertThrowsError(try inspected.find(text: "Process List Unavailable"))
    }

    func testFailedFirstLoadShowsTheErrorAndRetryInsteadOfIdle() async throws {
        let inventory = UIScriptedInventory(results: [.failure(.commandFailed("ps timed out"))])
        let fixture = await makeFixture(inventory: inventory)
        defer { fixture.stores.cleanup() }
        XCTAssertFalse(fixture.manager.hasLoadedProcessList)
        XCTAssertEqual(fixture.manager.processLoadError, "ps timed out")

        let inspected = try makePopover(fixture: fixture, confirmationState: ProcessConfirmationState()).inspect()

        XCTAssertNoThrow(try inspected.find(text: "Process List Unavailable"))
        XCTAssertNoThrow(try inspected.find(text: "ps timed out."))
        XCTAssertNoThrow(try inspected.find(button: "Retry"))
        XCTAssertThrowsError(try inspected.find(text: "Idle Until Needed"))
    }

    func testRuleEditorSheetRendersTheValidationErrorItWasGiven() throws {
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .kill)
        let sheet = AutoStopRuleEditorSheet(
            rule: rule,
            validationError: "Auto Stop requires a trusted executable path.",
            onSave: { _ in },
            onCancel: {}
        )

        XCTAssertNoThrow(try sheet.inspect().find(text: "Auto Stop requires a trusted executable path."))
        XCTAssertNoThrow(try sheet.inspect().find(button: "Cancel"))
    }

    /// Deleting the built-in preset while Keep Off is on would orphan its
    /// persistent launchd override; the refusal names the way out.
    func testDeletingTheGlobalProtectPresetIsRefusedWhileKeepOffIsOn() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.keepGlobalProtectOff = true
        let interactions = SettingsInteractionState()
        let view = SettingsView(
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules,
            processManager: fixture.manager,
            selectedTab: .watchedApps,
            interactions: interactions
        )

        try view.inspect().find(button: "Delete…").tap()
        XCTAssertEqual(fixture.stores.watchedApps.presets.map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertTrue(interactions.pendingPresetDeletions.isEmpty, "A refused deletion is not offered for confirmation")
        XCTAssertTrue(
            SettingsView.presetDeletionRefusal(for: .globalProtect, keepGlobalProtectOff: true)?
                .contains("Turn off Keep GlobalProtect Off") == true
        )
        XCTAssertNil(SettingsView.presetDeletionRefusal(for: .globalProtect, keepGlobalProtectOff: false))

        fixture.stores.settings.keepGlobalProtectOff = false
        try view.inspect().find(button: "Delete…").tap()
        // Deletion is confirmed first (audit L11-9); confirming deletes it.
        XCTAssertEqual(interactions.pendingPresetDeletions.map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(fixture.stores.watchedApps.presets.map(\.id), [WatchedAppPreset.globalProtectID])
        let tabView = try view.inspect().tabView()
        let dialog = try XCTUnwrap((0..<3).lazy.compactMap { try? tabView.confirmationDialog($0) }.first)
        try dialog.actions().find(button: "Delete Preset").tap()
        XCTAssertTrue(fixture.stores.watchedApps.presets.isEmpty)
    }
    func testDeletingGlobalProtectIsRefusedWhenKeepOffSettingsAreUnreadable() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let corrupt = Data([0xFF, 0x04])
        fixture.stores.defaults.set(corrupt, forKey: "settings")
        let settings = SettingsStore(userDefaults: fixture.stores.defaults, key: "settings")
        XCTAssertFalse(settings.keepGlobalProtectOff)
        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        let view = SettingsView(
            settings: settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules,
            processManager: fixture.manager,
            selectedTab: .watchedApps
        )
        try view.inspect().find(button: "Delete…").tap()
        XCTAssertEqual(fixture.stores.watchedApps.presets.map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(fixture.stores.defaults.data(forKey: "settings"), corrupt)
        XCTAssertTrue(SettingsView.presetDeletionRefusal(
            for: .globalProtect,
            keepGlobalProtectOff: false,
            isSettingsReadOnlyAfterCorruption: true
        )?.contains("Settings are unreadable") == true)
    }

    func testProcessRowScopesAccessibilitySummaryAndPreservesActions() throws {
        let target = process(
            pid: 70,
            parentPID: 1,
            name: "Accessible",
            cpu: 42.5,
            memoryMB: 2_048
        )
        let row = ProcessRow(
            process: target,
            isCurrentProcess: false,
            isSelected: false,
            isKeyboardSelected: false,
            isHighlightedCPU: true,
            isHighlightedMEM: true,
            showsExpandedMetrics: true,
            stopAction: {},
            toggleSelection: {}
        )
        let inspected = try row.inspect()
        let stack = try inspected.find(ViewType.HStack.self)

        XCTAssertThrowsError(
            try stack.accessibilityValue(),
            "The row container must not propagate its summary to every child element"
        )

        let identity = try stack.find(ViewType.VStack.self)
        XCTAssertEqual(try identity.accessibilityLabel().string(), "Accessible, PID 70")
        XCTAssertEqual(
            try identity.accessibilityValue().string(),
            "CPU 42.5 percent, memory 2,048 megabytes, high CPU, high memory"
        )
        XCTAssertEqual(
            try identity.accessibilityHint().string(),
            "Command: /Applications/Accessible.app/Contents/MacOS/Accessible"
        )

        let buttons = stack.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 2)
        guard buttons.count == 2 else { return }
        // Same-named processes are told apart by PID on every control.
        XCTAssertEqual(try buttons[0].accessibilityLabel().string(), "Add Accessible, PID 70 to selection")
        XCTAssertEqual(try buttons[1].accessibilityLabel().string(), "Stop Accessible, PID 70")
    }

    func testFilteredProcessViewRendersAndSelectsOnlyMatchingRow() async throws {
        let needle = process(pid: 71, parentPID: 1, name: "Needle", cpu: 42)
        let hidden = process(pid: 72, parentPID: 1, name: "Hidden", cpu: 3)
        let fixture = await makeFixture(processes: [needle, hidden])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.searchText = "Needle"

        let confirmation = ProcessConfirmationState()
        let view = makePopover(
            fixture: fixture,
            confirmationState: confirmation
        )
        let rows = try view.inspect().findAll(ProcessRow.self)

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try row.actualView().process.identity, needle.identity)

        // The row's own controls; the row's VoiceOver actions are attached
        // outside `ProcessRow` and are checked in Batch10WiringTests.
        let rowButtons = try row.actualView().inspect().findAll(ViewType.Button.self)
        XCTAssertEqual(rowButtons.count, 2)
        guard rowButtons.count == 2 else { return }

        try rowButtons[0].tap()
        XCTAssertEqual(fixture.manager.selectedPids, [needle.pid])
        XCTAssertFalse(fixture.manager.selectedPids.contains(hidden.pid))

        try rowButtons[1].tap()
        XCTAssertEqual(confirmation.pendingTermination?.process.identity, needle.identity)
        XCTAssertEqual(confirmation.pendingTermination?.mode, .normal)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        let presented = try view.inspect()
        XCTAssertNoThrow(try presented.find(text: "Stop Process?"))
        XCTAssertNoThrow(try presented.find(text: "Stop Needle"))
        XCTAssertThrowsError(
            try presented.find(button: "Force Stop Needle"),
            "A normal Stop confirmation must not expose SIGKILL"
        )
        XCTAssertNoThrow(
            try presented.find(
                text: "Send SIGTERM to PID 71. Apps may close without asking to save changes."
            )
        )

        try presented.find(button: "Cancel").tap()
        await confirmation.waitForActions()
        XCTAssertNil(confirmation.pendingTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testWindowCancelNeverSignalsForSingleOrBatchNormalOrForce() async throws {
        try await assertCancelledStops(menuBar: false)
    }

    func testMenuBarCancelNeverSignalsForSingleOrBatchNormalOrForce() async throws {
        try await assertCancelledStops(menuBar: true)
    }

    private func assertCancelledStops(menuBar: Bool) async throws {
        for mode in [ProcessConfirmationState.TerminationMode.normal, .force] {
            for batch in [false, true] {
                let target = process(pid: 75, parentPID: 1, name: "CancelledTarget")
                let fixture = await makeFixture(processes: [target])
                defer { fixture.stores.cleanup() }
                let confirmation = ProcessConfirmationState()
                let presenter = menuBar ? UIMenuBarConfirmation(answer: false) : nil
                let view = makePopover(fixture: fixture, confirmationState: confirmation, menuBarConfirmation: presenter)
                if batch {
                    confirmation.requestBatch([target.identity], mode: mode)
                } else {
                    confirmation.requestTermination(target, mode: mode)
                }
                if menuBar {
                    if batch {
                        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingBatchTermination)
                    } else {
                        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingTermination)
                    }
                } else {
                    try view.inspect().find(button: "Cancel").tap()
                }
                await confirmation.waitForActions()
                XCTAssertNil(confirmation.pendingTermination)
                XCTAssertNil(confirmation.pendingBatchTermination)
                XCTAssertTrue(fixture.signaler.sent.isEmpty, "Cancel must not signal: menuBar=\(menuBar), batch=\(batch), mode=\(mode)")
            }
        }
    }

    func testWindowConfirmsNormalProcessStopWithSIGTERM() async throws {
        try await assertConfirmedStop(mode: .normal, batch: false, menuBar: false)
    }

    func testWindowConfirmsForceProcessStopWithSIGKILL() async throws {
        try await assertConfirmedStop(mode: .force, batch: false, menuBar: false)
    }

    func testWindowConfirmsNormalBatchStopWithSIGTERM() async throws {
        try await assertConfirmedStop(mode: .normal, batch: true, menuBar: false)
    }

    func testWindowConfirmsForceBatchStopWithSIGKILL() async throws {
        try await assertConfirmedStop(mode: .force, batch: true, menuBar: false)
    }

    func testMenuBarConfirmsNormalProcessStopWithSIGTERM() async throws {
        try await assertConfirmedStop(mode: .normal, batch: false, menuBar: true)
    }

    func testMenuBarConfirmsForceProcessStopWithSIGKILL() async throws {
        try await assertConfirmedStop(mode: .force, batch: false, menuBar: true)
    }

    func testMenuBarConfirmsNormalBatchStopWithSIGTERM() async throws {
        try await assertConfirmedStop(mode: .normal, batch: true, menuBar: true)
    }

    func testMenuBarConfirmsForceBatchStopWithSIGKILL() async throws {
        try await assertConfirmedStop(mode: .force, batch: true, menuBar: true)
    }

    private func assertConfirmedStop(
        mode: ProcessConfirmationState.TerminationMode,
        batch: Bool,
        menuBar: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let target = process(pid: 75, parentPID: 1, name: "ConfirmedTarget")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        let presenter = menuBar ? UIMenuBarConfirmation(answer: true) : nil
        let view = makePopover(fixture: fixture, confirmationState: confirmation, menuBarConfirmation: presenter)
        let title: String
        if batch {
            confirmation.requestBatch([target.identity], mode: mode)
            title = try XCTUnwrap(confirmation.pendingBatchTermination).confirmTitle
        } else {
            confirmation.requestTermination(target, mode: mode)
            title = try XCTUnwrap(confirmation.pendingTermination).confirmTitle
        }
        XCTAssertTrue(fixture.signaler.sent.isEmpty, file: file, line: line)
        if menuBar {
            if batch {
                try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingBatchTermination)
            } else {
                try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingTermination)
            }
        } else {
            try view.inspect().find(button: title).tap()
        }
        await confirmation.waitForActions()
        XCTAssertNil(confirmation.pendingTermination, file: file, line: line)
        XCTAssertNil(confirmation.pendingBatchTermination, file: file, line: line)
        if let presenter {
            XCTAssertEqual(presenter.requests.map(\.confirmTitle), [title], file: file, line: line)
        }
        XCTAssertEqual(
            fixture.signaler.sent,
            [.init(signal: mode == .force ? SIGKILL : SIGTERM, pid: target.pid)],
            file: file, line: line
        )
    }

    func testConfirmedWindowPresetActionShowsOnlyTheCompletedResult() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        confirmation.requestPresetAction(.quitAll, preset: .globalProtect)
        var windowRequests = 0
        let view = makePopover(fixture: fixture, confirmationState: confirmation, openFullWindow: {
            XCTAssertNil(confirmation.pendingPresetAction)
            XCTAssertEqual(fixture.manager.message, "Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
            windowRequests += 1
        })
        try view.inspect().find(ViewType.ConfirmationDialog.self).actions().find(button: "Quit All").tap()
        await confirmation.waitForActions()
        XCTAssertEqual(windowRequests, 1)
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testForceStopUsesDistinctConfirmationWithoutNormalStopAction() async throws {
        let target = process(pid: 72, parentPID: 1, name: "ForceTarget")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        confirmation.requestTermination(target, mode: .force)

        let presented = try makePopover(
            fixture: fixture,
            confirmationState: confirmation
        ).inspect()

        XCTAssertEqual(confirmation.pendingTermination?.process.identity, target.identity)
        XCTAssertEqual(confirmation.pendingTermination?.mode, .force)
        XCTAssertNoThrow(try presented.find(text: "Force Stop Process?"))
        XCTAssertNoThrow(try presented.find(button: "Force Stop ForceTarget"))
        XCTAssertThrowsError(try presented.find(button: "Stop ForceTarget"))
        XCTAssertNoThrow(
            try presented.find(
                text: "Immediately send a kill signal to PID 72. The process cannot clean up before it exits."
            )
        )
    }

    func testBatchConfirmationUsesImmutableTargetSnapshotAndExposesActions() async throws {
        let first = process(pid: 73, parentPID: 1, name: "First")
        let second = process(pid: 74, parentPID: 1, name: "Second")
        let fixture = await makeFixture(processes: [first, second])
        defer { fixture.stores.cleanup() }

        let confirmation = ProcessConfirmationState()
        var requestedTargets = [first.identity, second.identity]
        confirmation.requestBatch(requestedTargets)
        requestedTargets.removeAll()

        XCTAssertEqual(
            confirmation.pendingBatchTermination?.targets,
            [first.identity, second.identity]
        )
        XCTAssertEqual(confirmation.pendingBatchTermination?.mode, .normal)
        XCTAssertEqual(
            confirmation.batchMessage,
            "Stop 2 selected processes.\nFirst (PID 73) — /Applications/First.app/Contents/MacOS/First\nSecond (PID 74) — /Applications/Second.app/Contents/MacOS/Second\nSends SIGTERM. Apps may close without asking to save changes."
        )

        let view = makePopover(
            fixture: fixture,
            confirmationState: confirmation
        )
        let presented = try view.inspect()

        // The window reviews the batch in a sheet that lists every target.
        let review = try presented.find(BatchStopReviewSheet.self)
        XCTAssertNoThrow(try review.find(text: "Stop Selected Processes?"))
        XCTAssertNoThrow(try review.find(text: "Stop 2 selected processes."))
        XCTAssertNoThrow(try review.find(button: "Stop Selected"))
        XCTAssertThrowsError(try review.find(button: "Force Stop Selected"))
        for (name, pid) in [("First", "PID 73"), ("Second", "PID 74")] {
            XCTAssertNoThrow(try review.find(text: name))
            XCTAssertNoThrow(try review.find(text: pid))
        }
        XCTAssertNoThrow(try review.find(text: "Sends SIGTERM. Apps may close without asking to save changes."))

        try presented.find(button: "Cancel").tap()
        await confirmation.waitForActions()
        XCTAssertNil(confirmation.pendingBatchTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        confirmation.requestBatch([first.identity, second.identity], mode: .force)
        let forcePresented = try makePopover(
            fixture: fixture,
            confirmationState: confirmation
        ).inspect()
        XCTAssertEqual(confirmation.pendingBatchTermination?.mode, .force)
        let forceReview = try forcePresented.find(BatchStopReviewSheet.self)
        XCTAssertNoThrow(try forceReview.find(text: "Force Stop Selected Processes?"))
        XCTAssertNoThrow(try forceReview.find(button: "Force Stop Selected"))
        XCTAssertThrowsError(try forceReview.find(button: "Stop Selected"))
        XCTAssertEqual(
            confirmation.batchMessage,
            "Force stop 2 selected processes.\nFirst (PID 73) — /Applications/First.app/Contents/MacOS/First\nSecond (PID 74) — /Applications/Second.app/Contents/MacOS/Second\nSends SIGKILL immediately; the processes cannot clean up."
        )
    }

    func testPresetCardDestructiveActionRequiresVisibleConfirmation() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        let card = try view.inspect().find(PresetCard.self)

        XCTAssertNoThrow(try card.find(text: "Keep GlobalProtect Off"))
        XCTAssertNoThrow(
            try card.find(
                text: "Quit All disconnects and stops GlobalProtect. Open or turning this switch off restores it."
            )
        )

        try card.find(button: "Quit All…").tap()

        XCTAssertEqual(confirmation.pendingPresetAction?.action, .quitAll)
        XCTAssertEqual(
            confirmation.pendingPresetAction?.preset.id,
            WatchedAppPreset.globalProtectID
        )
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
        let presented = try view.inspect()
        XCTAssertNoThrow(try presented.find(ViewType.ConfirmationDialog.self).actions().find(button: "Quit All"))
        XCTAssertNoThrow(
            try presented.find(
                text: "TaskScope will disconnect the VPN, stop GlobalProtect and its services, and keep them off until you choose Open. Accessibility permission lets TaskScope press Disconnect for you; administrator approval is requested only when needed to stop the system service. Sends SIGTERM. Apps may close without asking to save changes. A process still running 3 seconds after the stop request is force stopped."
            )
        )

        let previousMessage = fixture.manager.message
        try presented.find(button: "Cancel").tap()
        await confirmation.waitForActions()
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertEqual(fixture.manager.message, previousMessage)
    }

    func testConfirmedMenuBarFullStopOpensPersistentWindowAndRetainsFailure() async throws {
        for action in [ProcessConfirmationState.PresetAction.quitAll, .keepOff] {
            let fixture = await makeFixture(processes: [])
            defer { fixture.stores.cleanup() }
            fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
            let confirmation = ProcessConfirmationState()
            confirmation.requestPresetAction(action, preset: .globalProtect)
            var windowRequests = 0
            let view = makePopover(fixture: fixture, confirmationState: confirmation, openFullWindow: {
                XCTAssertNil(confirmation.pendingPresetAction)
                XCTAssertFalse(fixture.manager.isWorking, "Present before disconnect can dismiss the menu")
                windowRequests += 1
            }, menuBarConfirmation: UIMenuBarConfirmation(answer: true))
            try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingPresetAction)
            await confirmation.waitForActions()
            XCTAssertEqual(windowRequests, 2, "Show progress before the menu closes and return focus to the result")
            XCTAssertNil(confirmation.pendingPresetAction)
            XCTAssertEqual(fixture.stores.settings.selectedSection, .presets)
            XCTAssertEqual(fixture.manager.message, "Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
            XCTAssertTrue(fixture.signaler.sent.isEmpty)
        }
    }

    func testCancellingMenuBarFullStopDoesNotOpenWindowOrRunAction() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        confirmation.requestPresetAction(.quitAll, preset: .globalProtect)
        var windowRequests = 0
        let view = makePopover(fixture: fixture, confirmationState: confirmation, openFullWindow: { windowRequests += 1 }, menuBarConfirmation: UIMenuBarConfirmation(answer: false))
        let previousMessage = fixture.manager.message
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingPresetAction)
        await confirmation.waitForActions()
        XCTAssertEqual(windowRequests, 0)
        XCTAssertEqual(fixture.manager.message, previousMessage)
        XCTAssertNil(confirmation.pendingPresetAction)
    }

    func testMenuBarConfirmsGlobalProtectKeepOffOutsideTheMenuWindow() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        let confirmation = ProcessConfirmationState()
        let presenter = UIMenuBarConfirmation(answer: true)
        var windowRequests = 0
        let view = makePopover(fixture: fixture, confirmationState: confirmation, openFullWindow: {
            XCTAssertNil(confirmation.pendingPresetAction)
            windowRequests += 1
        }, menuBarConfirmation: presenter)

        confirmation.requestPresetAction(.keepOff, preset: .globalProtect)
        let pending = try XCTUnwrap(confirmation.pendingPresetAction)
        XCTAssertThrowsError(
            try view.inspect().find(ViewType.ConfirmationDialog.self),
            "A dialog on the menu window stops taking clicks once GlobalProtect takes focus"
        )
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingPresetAction)
        await confirmation.waitForActions()

        XCTAssertEqual(presenter.requests, [MenuBarConfirmationRequest(
            title: "Keep GlobalProtect Off?",
            message: TaskScopePopoverView.presetConfirmationMessage(for: pending),
            confirmTitle: "Keep GlobalProtect Off"
        )])
        XCTAssertEqual(windowRequests, 2)
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertEqual(fixture.manager.message, "Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testCancellingMenuBarConfirmationRunsNothing() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        let presenter = UIMenuBarConfirmation(answer: false)
        var windowRequests = 0
        let view = makePopover(fixture: fixture, confirmationState: confirmation, openFullWindow: {
            windowRequests += 1
        }, menuBarConfirmation: presenter)
        let previousMessage = fixture.manager.message

        confirmation.requestPresetAction(.quitAll, preset: .globalProtect)
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingPresetAction)
        await confirmation.waitForActions()

        XCTAssertEqual(presenter.requests.map(\.confirmTitle), ["Quit All"])
        XCTAssertEqual(windowRequests, 0)
        XCTAssertEqual(fixture.manager.message, previousMessage)
        XCTAssertNil(confirmation.pendingPresetAction)
    }

    func testMenuBarConfirmsProcessStopsOutsideTheMenuWindow() async throws {
        let target = process(pid: 75, parentPID: 1, name: "MenuTarget")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let confirmation = ProcessConfirmationState()
        let presenter = UIMenuBarConfirmation(answer: false)
        let view = makePopover(fixture: fixture, confirmationState: confirmation, menuBarConfirmation: presenter)

        confirmation.requestTermination(target)
        XCTAssertThrowsError(try view.inspect().find(ViewType.ConfirmationDialog.self))
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingTermination)
        await confirmation.waitForActions()
        XCTAssertEqual(presenter.requests, [MenuBarConfirmationRequest(
            title: "Stop Process?",
            message: "Send SIGTERM to PID 75. Apps may close without asking to save changes.",
            confirmTitle: "Stop MenuTarget"
        )])
        XCTAssertNil(confirmation.pendingTermination)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        presenter.answer = true
        confirmation.requestBatch([target.identity], mode: .force)
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: confirmation.pendingBatchTermination)
        await confirmation.waitForActions()
        XCTAssertEqual(presenter.requests.last?.confirmTitle, "Force Stop Selected")
        XCTAssertNil(confirmation.pendingBatchTermination)
        XCTAssertEqual(fixture.signaler.sent, [.init(signal: SIGKILL, pid: 75)])
    }

    func testReportsWaitForTheirWindowSoTheDockIconDoesNotBounce() {
        let report = LifecycleReport(title: "GlobalProtect Keep Off", jobs: [])

        XCTAssertNil(TaskScopePopoverView.presentedReport(report, alreadyShown: nil, windowState: .inactive))
        XCTAssertEqual(TaskScopePopoverView.presentedReport(report, alreadyShown: nil, windowState: .key), report)
        XCTAssertEqual(TaskScopePopoverView.presentedReport(report, alreadyShown: nil, windowState: .active), report)
        XCTAssertEqual(
            TaskScopePopoverView.presentedReport(report, alreadyShown: report.id, windowState: .inactive),
            report,
            "A report already on screen stays while the user switches apps"
        )
        XCTAssertNil(TaskScopePopoverView.presentedReport(LifecycleReport?.none, alreadyShown: report.id, windowState: .key))
    }

    func testFailedDisconnectOffersASeparateConfirmedServiceStop() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { [.globalProtect] }
        // Record the Keep Off intent in settings as the app does, so the
        // keepGlobalProtectOff assertion below can fail if Cancel ran the stop.
        let settings = fixture.stores.settings
        fixture.manager.setPresetKeptOffHandler = { preset, keptOff in
            guard preset.id == WatchedAppPreset.globalProtectID else { return }
            settings.keepGlobalProtectOff = keptOff
        }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        XCTAssertThrowsError(try view.inspect().find(button: "Stop Services Anyway…"))

        _ = await fixture.manager.keepOff(.globalProtect)
        let failureID = try XCTUnwrap(fixture.manager.globalProtectDisconnectFailureID)
        try view.inspect().find(button: "Stop Services Anyway…").tap()
        XCTAssertEqual(confirmation.pendingPresetAction?.action, .stopServices)
        XCTAssertEqual(confirmation.pendingPresetAction?.disconnectFailureID, failureID)
        let message = TaskScopePopoverView.presetConfirmationMessage(for: try XCTUnwrap(confirmation.pendingPresetAction))
        XCTAssertTrue(message.contains("leave VPN DNS settings behind"))
        XCTAssertTrue(message.contains("choose Open"))
        XCTAssertTrue(fixture.signaler.sent.isEmpty)

        try view.inspect().find(ViewType.ConfirmationDialog.self).actions().find(button: "Cancel").tap()
        await confirmation.waitForActions()
        XCTAssertNil(confirmation.pendingPresetAction)
        XCTAssertEqual(fixture.manager.globalProtectDisconnectFailureID, failureID)
        XCTAssertFalse(fixture.stores.settings.keepGlobalProtectOff)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testPresetFooterShowsTheActiveStepAndFullFailureMessage() throws {
        let step = "Disconnecting GlobalProtect before stopping its services…"
        let working = TaskScopeFooterView(isWorking: true, message: step, workingMessage: step, expandsMessage: true, summary: nil, quitAction: {})
        XCTAssertNoThrow(try working.inspect().find(text: step))
        XCTAssertThrowsError(try working.inspect().find(text: "Working..."))
        let detail = "GlobalProtect did not finish disconnecting. Complete any request in GlobalProtect and try Quit All again; its services were left running."
        let failed = TaskScopeFooterView(isWorking: false, message: detail, expandsMessage: true, summary: nil, quitAction: {})
        XCTAssertNil(try failed.inspect().find(text: detail).lineLimit())
    }

    /// The Open button must address the preset it belongs to by identity. A
    /// display-name lookup also matches other presets' main process names, so a
    /// cross-field collision used to open a different preset than the one clicked.
    func testPresetCardOpenSubmitsTheClickedPresetIdentityNotItsDisplayName() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.watchedApps
        for preset in store.presets { XCTAssertTrue(store.remove(preset)) }
        let alpha = WatchedAppPreset(
            displayName: "Alpha",
            mainProcessName: "Beta",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Alpha.app"
        )
        let beta = WatchedAppPreset(
            displayName: "Beta",
            mainProcessName: "Gamma",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Beta.app"
        )
        XCTAssertTrue(store.add(alpha))
        XCTAssertTrue(store.add(beta))
        // The removed name-based commands matched a display name or a main
        // process name and took the first hit.
        XCTAssertEqual(
            store.presets.first {
                $0.displayName.caseInsensitiveCompare("Beta") == .orderedSame
                    || $0.mainProcessName.caseInsensitiveCompare("Beta") == .orderedSame
            }?.id,
            alpha.id,
            "precondition: a name lookup for Beta resolves to Alpha"
        )
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { store.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)

        let recorder = CommandRecorder()
        AppCommandBus.shared.install { command in
            recorder.record(command)
            return TaskScopeCommandResult(status: .completed, message: "recorded")
        }
        defer {
            AppCommandBus.shared.install { _ in
                TaskScopeCommandResult(status: .rejected, message: "No handler installed by this test.")
            }
        }

        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        let cards = try view.inspect().findAll(PresetCard.self)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(try cards[1].actualView().snapshot.preset.id, beta.id)

        try cards[1].find(button: "Open").tap()
        await confirmation.waitForActions()

        // The card's Open goes straight to the manager (and its operation
        // gate) in click order, like the card's other actions, instead of
        // waiting in the command bus behind actions confirmed after it.

        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertEqual(fixture.lifecycle.events.filter { $0.hasPrefix("open:") }, ["open:/Applications/Beta.app"])
    }

    func testManualProcessSnapshotDisplaysItsSuccessfulUpdateTime() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.autoRefreshProcessList = false
        let updated = try XCTUnwrap(fixture.manager.lastSuccessfulInventoryAt)
        let view = makePopover(fixture: fixture, confirmationState: ProcessConfirmationState())
        XCTAssertNoThrow(try view.inspect().find(text: "Updated \(updated.formatted(date: .omitted, time: .standard))"))
    }

    func testTurningKeepOffOffSubmitsFullRestoreCommand() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.keepGlobalProtectOff = true
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.watchedAppsProvider = { fixture.stores.watchedApps.presets }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let recorder = CommandRecorder()
        AppCommandBus.shared.install { command in
            recorder.record(command)
            return TaskScopeCommandResult(status: .completed, message: "recorded")
        }
        defer {
            AppCommandBus.shared.install { _ in
                TaskScopeCommandResult(status: .rejected, message: "No handler installed by this test.")
            }
        }
        let confirmation = ProcessConfirmationState()
        let view = makePopover(fixture: fixture, confirmationState: confirmation)
        let card = try view.inspect().find(PresetCard.self).actualView()
        card.onKeepOffChanged(false)
        await confirmation.waitForActions()
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(fixture.lifecycle.events.contains("restore:GlobalProtect"))
        XCTAssertTrue(fixture.lifecycle.events.contains("open:/Applications/GlobalProtect.app"))
    }

    /// A row can be on screen purely because the search filter surfaced it, even
    /// though it ranks below the display limit. The preset draft must be built from
    /// the full inventory (`selectedProcessesSnapshot()`), not from the limited,
    /// unfiltered display slice — the two sets are not nested.
    func testSaveSelectionAsPresetDraftKeepsSearchSurfacedSelection() async throws {
        let hotA = process(pid: 91, parentPID: 1, name: "HotA", cpu: 90)
        let hotB = process(pid: 92, parentPID: 1, name: "HotB", cpu: 80)
        let needle = process(pid: 93, parentPID: 1, name: "Needle", cpu: 1)
        let fixture = await makeFixture(processes: [hotA, hotB, needle])
        defer { fixture.stores.cleanup() }

        // Production wires this provider from settings.processListLimit and
        // republishes via applyCurrentDisplayLimit(). A limit of 2 keeps the fixture
        // small; all that matters is that the inventory exceeds it.
        fixture.manager.processListLimitProvider = { 2 }
        fixture.manager.applyCurrentDisplayLimit()
        fixture.stores.settings.searchText = "Needle"

        // Filtering runs before the limit, so the search surfaces a row that the
        // unfiltered display slice drops.
        XCTAssertEqual(fixture.manager.displayProcesses().map(\.pid), [hotA.pid, hotB.pid])

        let view = makePopover(
            fixture: fixture,
            confirmationState: ProcessConfirmationState()
        )
        let rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(try row.actualView().process.identity, needle.identity)

        try XCTUnwrap(row.findAll(ViewType.Button.self).first).tap()
        XCTAssertEqual(fixture.manager.selectedPids, [needle.pid])

        // Exercise the exact accessor used by the context-menu draft action.
        let draftProcesses = view.selectedProcessesForPreset()
        XCTAssertEqual(draftProcesses.map(\.pid), [needle.pid])

        // The collection this used to read from would have dropped it entirely.
        let displaySliceOnly = fixture.manager.displayProcesses().filter {
            fixture.manager.selectedPids.contains($0.pid)
        }
        XCTAssertTrue(
            displaySliceOnly.isEmpty,
            "guards the regression: the display slice does not contain the selected row"
        )

        let sheet = QuickWatchedPresetSheet(
            draft: QuickWatchedPresetDraft(processes: draftProcesses),
            onSave: { _ in nil },
            onCancel: {}
        )
        XCTAssertNoThrow(
            try sheet.inspect().find(text: "Needle"),
            "Preset sheet should summarise the selected process, not report it as empty"
        )
    }

    /// A saved entry without a kernel executable path can only match by name.
    /// The recall preview must say so next to every such entry.
    func testRecallSheetMarksLegacyNameMatches() throws {
        let matched = process(pid: 20, parentPID: 1, name: "Example")
        let legacyMatched = SavedSelectionsStore.SavedProcess(
            pid: 10,
            command: "Example",
            executableName: "Example"
        )
        let legacyMissing = SavedSelectionsStore.SavedProcess(
            pid: 11,
            command: "Other",
            executableName: "Other"
        )
        let pathBound = SavedSelectionsStore.SavedProcess(
            pid: 12,
            command: "/Applications/Bound.app/Contents/MacOS/Bound",
            executableName: "Bound",
            executablePath: "/Applications/Bound.app/Contents/MacOS/Bound"
        )
        let selection = SavedSelectionsStore.SavedSelection(
            name: "Mixed",
            pids: [10, 11, 12],
            processes: [legacyMatched, legacyMissing, pathBound]
        )
        let result = SavedSelectionsStore.RecallResult(
            matched: [matched],
            unmatched: [legacyMissing, pathBound],
            ambiguous: [],
            legacyUnsupported: false,
            legacyNameMatches: [matched.identity]
        )
        let sheet = SavedSelectionRecallSheet(
            selection: selection,
            result: result,
            onApply: {},
            onCancel: {}
        )

        let inspected = try sheet.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Example — PID 20 · legacy name match"))
        XCTAssertNoThrow(try inspected.find(text: "Other · legacy name match"))
        XCTAssertNoThrow(try inspected.find(text: "Bound"))
        XCTAssertThrowsError(try inspected.find(text: "Bound · legacy name match"))
    }

    func testQuickPresetSheetKeepsRejectedDraftAndShowsStoreError() throws {
        var target = process(pid: 94, parentPID: 1, name: "Rejected")
        target.uid = getuid()
        var saveAttempts = 0
        let form = QuickWatchedPresetFormState(
            displayName: target.name,
            mainProcessName: target.name,
            helperNames: "",
            appPath: "/Applications/Rejected.app"
        )
        let sheet = QuickWatchedPresetSheet(
            draft: QuickWatchedPresetDraft(processes: [target]),
            onSave: { _ in
                saveAttempts += 1
                return "A watched preset with that display name already exists."
            },
            onCancel: {},
            form: form
        )

        let inspected = try sheet.inspect()
        try inspected.find(button: "Add Preset").tap()

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(
            form.validationError,
            "A watched preset with that display name already exists."
        )
        XCTAssertNoThrow(
            try sheet.inspect().find(
                text: "A watched preset with that display name already exists."
            )
        )
        XCTAssertNoThrow(try sheet.inspect().find(button: "Add Preset"))
    }

    func testQuickRuleExecutablePathMatchesCreateAndUpdateScope() {
        let observedPath = "/Applications/Example.app/Contents/MacOS/Example"
        let nameWide = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)
        var pathBound = nameWide
        pathBound.executablePath = "/opt/Example"
        func path(_ name: String, _ action: AutoStopRule.Action, _ existing: AutoStopRule? = nil, observed: String? = "/Applications/Example.app/Contents/MacOS/Example") -> String? {
            QuickAutoStopRuleSaver.executablePath(
                processName: name, observedProcessName: "Example", observedExecutablePath: observed,
                action: action, existingRule: existing
            )
        }

        XCTAssertEqual(path(" example \n", .prompt), observedPath)
        XCTAssertNil(path("Other", .prompt))
        XCTAssertNil(path("Other", .kill))
        XCTAssertNil(path("Example", .prompt, nameWide))
        XCTAssertNil(path("Example", .silent, nameWide))
        XCTAssertEqual(path("Example", .kill, nameWide), observedPath)
        XCTAssertEqual(path("Example", .prompt, pathBound), observedPath)
        // A renamed path-bound rule cannot keep the old name's binary: it would
        // match nothing (audit A13-5), so Auto Stop has no path and is refused.
        XCTAssertNil(path("Other", .kill, pathBound))
        XCTAssertEqual(path("Example", .kill, pathBound, observed: nil), pathBound.executablePath)
        XCTAssertNil(path("Example", .kill, nameWide, observed: nil))
    }

    func testQuickAutoStopSheetShowsLiveExecutableScopeAndMissingPathExplanation() throws {
        let target = process(pid: 96, parentPID: 1, name: "Example")
        let path = try XCTUnwrap(target.executablePath)
        let form = QuickAutoStopRuleFormState(processName: target.name, runtimeMinutes: 5, action: .prompt)
        let sheet = QuickAutoStopRuleSheet(process: target, existingRule: nil, onSave: { _, _, _ in nil }, onCancel: {}, form: form)
        let explanation = "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules."

        XCTAssertNoThrow(try sheet.inspect().find(ViewType.Form.self).find(text: path))
        form.processName = " Other "
        XCTAssertNoThrow(try sheet.inspect().find(text: "Any process named Other"))
        XCTAssertThrowsError(try sheet.inspect().find(ViewType.Form.self).find(text: path))
        form.action = .kill
        XCTAssertNoThrow(try sheet.inspect().find(text: explanation))
        form.processName = target.name
        XCTAssertNoThrow(try sheet.inspect().find(ViewType.Form.self).find(text: path))
        XCTAssertThrowsError(try sheet.inspect().find(text: explanation))

        let existing = AutoStopRule(processName: target.name, runtimeMinutes: 5, action: .prompt)
        let update = QuickAutoStopRuleSheet(process: target, existingRule: existing, onSave: { _, _, _ in nil }, onCancel: {}, form: form)
        form.action = .prompt
        XCTAssertNoThrow(try update.inspect().find(text: "Any process named Example"))
        form.action = .kill
        XCTAssertNoThrow(try update.inspect().find(ViewType.Form.self).find(text: path))
        form.action = .silent
        XCTAssertNoThrow(try update.inspect().find(text: "Any process named Example"))
    }

    func testQuickAutoStopSheetKeepsRejectedDraftAndShowsStoreError() throws {
        var target = process(pid: 96, parentPID: 1, name: "Rejected")
        target.uid = getuid()
        var saveAttempts = 0
        let form = QuickAutoStopRuleFormState(
            processName: target.name,
            runtimeMinutes: 5,
            action: .prompt
        )
        let sheet = QuickAutoStopRuleSheet(
            process: target,
            existingRule: nil,
            onSave: { _, _, _ in
                saveAttempts += 1
                return "Auto-stop rule data is in recovery mode."
            },
            onCancel: {},
            form: form
        )

        try sheet.inspect().find(button: "Add Rule").tap()

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertEqual(form.validationError, "Auto-stop rule data is in recovery mode.")
        XCTAssertNoThrow(
            try sheet.inspect().find(text: "Auto-stop rule data is in recovery mode.")
        )
        XCTAssertNoThrow(try sheet.inspect().find(button: "Add Rule"))
    }

    func testCurrentProcessSelectionControlIsDisabledAndExplainsProtection() throws {
        let target = process(pid: 95, parentPID: 1, name: "TaskScope")
        var selectionAttempts = 0
        let row = ProcessRow(
            process: target,
            isCurrentProcess: true,
            isSelected: false,
            isKeyboardSelected: false,
            isHighlightedCPU: false,
            isHighlightedMEM: false,
            stopAction: {},
            toggleSelection: { selectionAttempts += 1 }
        )

        let selectionButton = try XCTUnwrap(row.inspect().findAll(ViewType.Button.self).first)
        XCTAssertTrue(selectionButton.isDisabled())
        XCTAssertEqual(
            try selectionButton.accessibilityLabel().string(),
            "TaskScope cannot be selected"
        )
        XCTAssertEqual(
            try selectionButton.accessibilityHint().string(),
            "TaskScope protects its own process"
        )
        XCTAssertThrowsError(try selectionButton.tap())
        let stopButton = try row.inspect().findAll(ViewType.Button.self)[1]
        XCTAssertTrue(stopButton.isDisabled())
        XCTAssertThrowsError(try stopButton.tap())
        XCTAssertEqual(selectionAttempts, 0)
    }

    func testTreeRowTapsRequestFocusEvenWhenSelectionIsUnchangedIncludingChildren() async throws {
        let parent = process(pid: 81, parentPID: 1, name: "Parent")
        let child = process(pid: 82, parentPID: parent.pid, name: "Child")
        let fixture = await makeFixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        var requests = 0
        let row = ProcessTreeRow(
            node: ProcessTreeNode(process: parent, children: [ProcessTreeNode(process: child, children: [])]),
            depth: 0,
            settings: fixture.stores.settings,
            processManager: fixture.manager,
            keyboardSelectedPid: .constant(parent.pid),
            pendingTermination: .constant(nil),
            expandedPids: .constant([parent.pid]),
            showsExpandedMetrics: false,
            requestListFocus: { requests += 1 },
            contextMenuContent: { _ in EmptyView() }
        )
        try row.inspect().vStack().zStack(0).callOnTapGesture()
        try row.inspect().vStack().zStack(0).callOnTapGesture()
        XCTAssertEqual(requests, 2, "Every tap must request focus even with an unchanged highlighted PID")
        let nested = try row.inspect().vStack().forEach(1).view(ProcessTreeRow<EmptyView>.self, 0)
        try nested.vStack().zStack(0).callOnTapGesture()
        XCTAssertEqual(requests, 3, "Recursive children must receive the same focus request")
    }

    func testTreeDisclosureControlsRenderedChildVisibility() async throws {
        let parent = process(pid: 81, parentPID: 1, name: "Parent")
        let child = process(pid: 82, parentPID: parent.pid, name: "Child")
        let fixture = await makeFixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        let root = ProcessTreeNode(
            process: parent,
            children: [ProcessTreeNode(process: child, children: [])]
        )
        let disclosure = TreeDisclosureModel()
        let view = TreeVisibilityHarness(
            root: root,
            manager: fixture.manager,
            settings: fixture.stores.settings,
            disclosure: disclosure
        )

        var rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(try rows.map { try $0.actualView().process.pid }, [parent.pid])

        // The disclosure overlays the row's selection and Stop buttons.
        let disclosureButton = try view.inspect().findAll(ViewType.Button.self)[2]
        try disclosureButton.tap()
        XCTAssertEqual(disclosure.expandedPIDs, [parent.pid])

        rows = try view.inspect().findAll(ProcessRow.self)
        XCTAssertEqual(
            try rows.map { try $0.actualView().process.pid },
            [parent.pid, child.pid]
        )

        try view.inspect().findAll(ViewType.Button.self)[2].tap()
        XCTAssertTrue(disclosure.expandedPIDs.isEmpty)
        XCTAssertEqual(try view.inspect().findAll(ProcessRow.self).count, 1)
    }

    func testSettingsViewHasFixedLayoutAndPrimaryTabContent() async throws {
        let fixture = await makeFixture(processes: [])
        defer { fixture.stores.cleanup() }
        let view = SettingsView(
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules,
            processManager: fixture.manager
        )
        let inspected = try view.inspect()
        let tabView = try inspected.find(ViewType.TabView.self)
        let frame = try tabView.fixedFrame()

        XCTAssertEqual(frame.width, SettingsView.windowSize.width)
        XCTAssertEqual(frame.height, SettingsView.windowSize.height)
        // Every sheet must fit inside the window that presents it.
        for sheet in [SettingsView.presetEditorSheetSize, SettingsView.importPreviewSheetSize, SettingsView.dryRunSheetSize] {
            XCTAssertLessThanOrEqual(sheet.width, SettingsView.windowSize.width)
            XCTAssertLessThanOrEqual(sheet.height, SettingsView.windowSize.height)
        }

        let contents: [SettingsView.Tab: [String]] = [
            .general: ["General", "Auto-refresh process list", "Notify on watched process changes"],
            .watchedApps: ["Watched Apps", "GlobalProtect", "Add…", "Export…", "Import…", "Built-in",
                           "Built-in lifecycle: 1 protected system daemon", SettingsView.builtInDaemonGuidance],
            .autoStop: ["Auto-Stop"], .hotkey: ["Hotkey", "Global Hotkey"],
            .health: ["Health", "Permission and Installation Health", "Refresh Health"],
            .support: ["Support", "Preview Diagnostics", "Clear Failure History"]
        ]
        XCTAssertEqual(Set(contents.keys), Set(SettingsView.Tab.allCases))
        for (tab, expectedTexts) in contents {
            let selectedView = SettingsView(
                settings: fixture.stores.settings, watchedApps: fixture.stores.watchedApps,
                autoStopRules: fixture.stores.autoStopRules, processManager: fixture.manager,
                selectedTab: tab
            )
            for expectedText in expectedTexts {
                XCTAssertNoThrow(try selectedView.inspect().find(text: expectedText),
                                 "Missing Settings UI content: \(expectedText)")
            }
            if tab == .watchedApps {
                XCTAssertThrowsError(try selectedView.inspect().find(button: "Edit…"),
                                     "The built-in GlobalProtect identity must not expose an editor.")
            }
        }
    }

    func testSettingsRecoveryUIRequiresExplicitReset() throws {
        let suiteName = "TaskScope.SettingsRecoveryUI.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = Data([0xFF, 0x04])
        defaults.set(corrupt, forKey: "settings")

        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let view = SettingsView(
            settings: settings,
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults,
                key: "rules",
                eventsKey: "events",
                inventory: UIInventory(processes: [])
            ),
            processManager: ProcessManager(
                processInventory: UIInventory(processes: []),
                verificationInventory: UIInventory(processes: []),
                processSignaler: UIRecordingSignaler(),
                lifecycle: UILifecycle(),
                settleAfterProcessChange: {}
            )
        )
        let inspected = try view.inspect()

        XCTAssertTrue(settings.isReadOnlyAfterCorruption)
        XCTAssertNoThrow(try inspected.find(text: "Recovered Settings"))
        try inspected.find(button: "Reset Settings After Backup").tap()

        XCTAssertFalse(settings.isReadOnlyAfterCorruption)
        XCTAssertNil(settings.recoveryMessage)
        XCTAssertNotEqual(defaults.data(forKey: "settings"), corrupt)
    }

    private func process(
        pid: Int32,
        parentPID: Int32,
        name: String,
        cpu: Double = 1,
        memoryMB: Double = 128
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: parentPID,
            cpu: cpu,
            memoryMB: memoryMB,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "00:10",
            startTime: "Sun Jul 26 12:00:00 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    private func makeFixture(processes: [AppProcess]) async -> UIFixture {
        await makeFixture(inventory: UIInventory(processes: processes))
    }

    private func makeFixture(inventory: any ProcessInventoryProviding, loadList: Bool = true) async -> UIFixture {
        let signaler = UIRecordingSignaler()
        let lifecycle = UILifecycle()
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false

        let stores = makeStores(inventory: inventory)
        if loadList { await manager.loadProcessList(showMessage: false) }

        return UIFixture(
            manager: manager,
            signaler: signaler,
            stores: stores,
            lifecycle: lifecycle
        )
    }

    private func makePopover(
        fixture: UIFixture,
        confirmationState: ProcessConfirmationState,
        openFullWindow: (() -> Void)? = nil,
        menuBarConfirmation: (any MenuBarConfirming)? = nil,
        presentationStyle: TaskScopePresentationStyle = .expandedWindow
    ) -> TaskScopePopoverView {
        TaskScopePopoverView(
            processManager: fixture.manager,
            loginItemManager: LoginItemManager(service: UILoginItemService()),
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            savedSelections: fixture.stores.savedSelections,
            autoStopRules: fixture.stores.autoStopRules,
            history: fixture.stores.history,
            presentationStyle: menuBarConfirmation == nil ? presentationStyle : .menuBarCompact,
            openFullWindow: openFullWindow,
            confirmationState: confirmationState,
            activityMonitor: UIActivityMonitor(),
            menuBarConfirmation: menuBarConfirmation
        )
    }

    private func makeStores(inventory: any ProcessInventoryProviding) -> UIStores {
        let suiteName = "TaskScope.UI.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UIStores(
            suiteName: suiteName,
            defaults: defaults,
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "selections"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults,
                key: "rules",
                eventsKey: "events",
                inventory: inventory
            ),
            history: ProcessHistory(inventory: inventory)
        )
    }
}

@MainActor
private final class CommandRecorder {
    private(set) var commands: [TaskScopeCommand] = []

    func record(_ command: TaskScopeCommand) {
        commands.append(command)
    }
}

@MainActor
private struct TreeVisibilityHarness: View {
    let root: ProcessTreeNode
    let manager: ProcessManager
    let settings: SettingsStore
    @ObservedObject var disclosure: TreeDisclosureModel

    @State private var keyboardSelectedPID: Int32?
    @State private var pendingTermination: AppProcess?

    var body: some View {
        ProcessTreeRow(
            node: root,
            depth: 0,
            settings: settings,
            processManager: manager,
            keyboardSelectedPid: $keyboardSelectedPID,
            pendingTermination: $pendingTermination,
            expandedPids: Binding(
                get: { disclosure.expandedPIDs },
                set: { disclosure.expandedPIDs = $0 }
            ),
            showsExpandedMetrics: false,
            contextMenuContent: { _ in EmptyView() }
        )
    }
}

@MainActor
private final class TreeDisclosureModel: ObservableObject {
    @Published var expandedPIDs: Set<Int32> = []
}

final class UIScriptedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            guard !results.isEmpty else { return .failure(.commandFailed("exhausted")) }
            return results.count == 1 ? results[0] : results.removeFirst()
        }
    }
}

struct UIInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

@MainActor
final class UIMenuBarConfirmation: MenuBarConfirming {
    var answer: Bool
    private(set) var requests: [MenuBarConfirmationRequest] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool {
        requests.append(request)
        return answer
    }
}

final class UIRecordingSignaler: ProcessSignaling {
    struct Signal: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private(set) var sent: [Signal] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(Signal(signal: signal, pid: pid))
        return true
    }

    func isAlive(_ pid: Int32) -> Bool {
        false
    }
}

final class UILifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    private func record(_ event: String) { lock.withLock { recorded.append(event) } }
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { record("main:\(preset.displayName)"); return .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { record("helper:\(name)"); return .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("unload:\(preset.displayName)"); return .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { record("preserve:\(preset.displayName)"); return .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("enable:\(preset.displayName)"); return .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("restore:\(preset.displayName)"); return .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { record("open:\(path)"); return .opened }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { record("disableAgents:\(preset.displayName)"); return .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { record("disableDaemons:\(preset.displayName):admin=\(allowAdministratorPrompt)"); return .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}

struct UILoginItemService: LoginItemServicing {
    var state: LoginItemState = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
struct UIActivityMonitor: ActivityMonitorCoordinating {
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        .missingProcess
    }
}

@MainActor
struct UIFixture {
    var manager: ProcessManager
    var signaler: UIRecordingSignaler
    var stores: UIStores
    var lifecycle: UILifecycle
}

@MainActor
struct UIStores {
    var suiteName: String
    var defaults: UserDefaults
    var settings: SettingsStore
    var watchedApps: WatchedAppsStore
    var savedSelections: SavedSelectionsStore
    var autoStopRules: AutoStopRulesStore
    var history: ProcessHistory

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
