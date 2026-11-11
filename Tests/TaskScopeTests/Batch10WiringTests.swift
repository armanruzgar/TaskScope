import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Batch 10: what the main window and the menu-bar popover wire their controls
/// to. Every test uses fakes; nothing is signalled outside the fakes.
@MainActor
final class Batch10WiringTests: XCTestCase {
    // MARK: Auto Stop prompts (A10-1, L01-7, L10-8, L01-5)

    func testPromptsAreAskedWithoutAnyOpenViewAndAnswersReachTheStore() async throws {
        let example = Batch10.process(41, name: "Example")
        let other = Batch10.process(42, name: "Other")
        let inventory = Batch10MutableInventory(processes: [example, other])
        let stores = Batch10.stores(inventory: inventory)
        defer { stores.cleanup() }
        let store = stores.autoStopRules
        let stopped = Batch10StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt)))

        // No TaskScope view exists in this test: the coordinator alone asks.
        let presenter = Batch10HeldConfirmation()
        let coordinator = AutoStopPromptCoordinator(rules: store, confirmation: presenter)
        XCTAssertTrue(store.hasAppPromptPresenter)
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42])

        await presenter.waitUntilPresented(count: 1)
        let first = try XCTUnwrap(presenter.requests.first)
        XCTAssertEqual(first.title, "Auto-Stop: Example")
        XCTAssertEqual(first.confirmTitle, "Stop Now")
        XCTAssertEqual(first.cancelTitle, "Dismiss", "Dismiss is permanent for this occurrence, so it is not labelled Cancel")
        XCTAssertTrue(first.message.contains("Dismiss stops reminders for this process until it restarts."))
        presenter.answer(true)

        await presenter.waitUntilPresented(count: 2)
        XCTAssertEqual(stopped.pids, [41])
        XCTAssertEqual(presenter.requests.last?.title, "Auto-Stop: Other")
        let task = coordinator.task
        presenter.answer(false)
        await task?.value
        XCTAssertEqual(stopped.pids, [41], "Dismiss never stops")
        XCTAssertTrue(store.pendingPrompts.isEmpty)
        // Events are kept newest first.
        XCTAssertEqual(store.events.map(\.outcome), [.dismissed, .stopped])
    }

    func testPromptAnsweredAfterItsProcessExitedStopsNothing() async throws {
        let example = Batch10.process(41, name: "Example")
        let inventory = Batch10MutableInventory(processes: [example])
        let stores = Batch10.stores(inventory: inventory)
        defer { stores.cleanup() }
        let store = stores.autoStopRules
        let stopped = Batch10StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        let presenter = Batch10HeldConfirmation()
        let coordinator = AutoStopPromptCoordinator(rules: store, confirmation: presenter)
        await store.evaluateNow()
        await presenter.waitUntilPresented()

        // The process exits while the alert is open; the next pass drops it.
        await inventory.setProcesses([])
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty)
        let task = coordinator.task
        presenter.answer(true)
        await task?.value
        XCTAssertTrue(stopped.pids.isEmpty)
    }

    func testMenuBarAndAppPresenterAttachNoInViewPromptAlert() async throws {
        let example = Batch10.process(41, name: "Example")
        let fixture = await Batch10.fixture(processes: [example])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        store.start(cadence: 60) { _, _ in .stopped }
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        await store.evaluateNow()
        XCTAssertNotNil(store.currentPrompt)

        // The menu-bar window never attaches a SwiftUI alert; such a dialog
        // stops taking clicks once another app takes focus.
        let menu = Batch10.popover(fixture, confirmer: UIMenuBarConfirmation(answer: false))
        XCTAssertThrowsError(try menu.inspect().find(AutoStopPromptAlert.self))
        // The window keeps one only as a fallback when no app-level owner exists.
        XCTAssertNoThrow(try Batch10.popover(fixture).inspect().find(AutoStopPromptAlert.self))
        store.hasAppPromptPresenter = true
        XCTAssertThrowsError(try Batch10.popover(fixture).inspect().find(AutoStopPromptAlert.self))
    }

    func testQueuedPromptShowsTheCurrentRuntimeAsADuration() async throws {
        var example = Batch10.process(41, name: "Example")
        example.elapsedTime = "07:31"
        let inventory = Batch10MutableInventory(processes: [example])
        let stores = Batch10.stores(inventory: inventory)
        defer { stores.cleanup() }
        let store = stores.autoStopRules
        store.start(cadence: 60) { _, _ in .stopped }
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)))
        await store.evaluateNow()
        let queued = try XCTUnwrap(store.currentPrompt)
        // 07:31 is seven minutes, not seven hours.
        XCTAssertTrue(AutoStopPromptAlert.message(for: queued).contains("has run for 7m 31s"), AutoStopPromptAlert.message(for: queued))

        example.elapsedTime = "02:00:05"
        await inventory.setProcesses([example])
        await store.evaluateNow()
        let refreshed = try XCTUnwrap(store.currentPrompt)
        XCTAssertEqual(refreshed.id, queued.id, "Still the same occurrence")
        XCTAssertTrue(AutoStopPromptAlert.message(for: refreshed).contains("has run for 2h 5s"), AutoStopPromptAlert.message(for: refreshed))
    }

    // MARK: GlobalProtect confirmations through the real card (T02-4)

    func testConfirmedStopServicesAnywayRunsTheConfirmedServiceStop() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let settings = fixture.stores.settings
        settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        fixture.manager.setPresetKeptOffHandler = { preset, keptOff in
            guard preset.id == WatchedAppPreset.globalProtectID else { return }
            settings.keepGlobalProtectOff = keptOff
        }
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        _ = await fixture.manager.keepOff(.globalProtect)
        let failureID = try XCTUnwrap(fixture.manager.globalProtectDisconnectFailureID)
        XCTAssertFalse(settings.keepGlobalProtectOff, "A failed disconnect records nothing")
        let eventsBefore = fixture.lifecycle.events

        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)
        try view.inspect().find(button: "Stop Services Anyway…").tap()
        XCTAssertEqual(state.pendingPresetAction?.disconnectFailureID, failureID)
        XCTAssertEqual(fixture.lifecycle.events, eventsBefore, "The card only asks")
        try view.inspect().find(ViewType.ConfirmationDialog.self).actions().find(button: "Stop Services Anyway").tap()
        await state.waitForActions()

        XCTAssertNil(fixture.manager.globalProtectDisconnectFailureID, "The confirmed failure is consumed")
        XCTAssertTrue(settings.keepGlobalProtectOff, "The confirmed stop records Keep Off")
        let ran = Array(fixture.lifecycle.events.dropFirst(eventsBefore.count))
        XCTAssertTrue(ran.contains("disableAgents:GlobalProtect"), "\(ran)")
        XCTAssertTrue(ran.contains("disableDaemons:GlobalProtect:admin=true"), "The confirmed stop may ask for administrator approval: \(ran)")
    }

    // MARK: Controls while another action holds the operation gate
    // (L10-3, A12-17, A12-7, T02-9)

    func testCardActionsAndQuitAreUnavailableWhileAMutationRuns() async throws {
        let gate = Batch10Gate()
        let fixture = await heldFixture(gate: gate)
        defer { fixture.stores.cleanup() }
        let preset = WatchedAppPreset(displayName: "Editor", mainProcessName: "Editor", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Editor.app")
        XCTAssertTrue(fixture.stores.watchedApps.add(preset))
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue

        let opening = Task { await fixture.manager.openApp(preset) }
        let entered = await Batch10.waitUntilAsync { await gate.hasEntered() }
        XCTAssertTrue(entered, "setup: Open must reach the held launch")
        defer { Task { await gate.release() } }
        XCTAssertTrue(fixture.manager.isMutationActive)

        let busy = try Batch10.popover(fixture).inspect()
        let card = try busy.find(PresetCard.self) { try $0.actualView().snapshot.preset.id == preset.id }
        XCTAssertTrue(try card.actualView().isMutationActive)
        XCTAssertTrue(try card.find(button: "Open").isDisabled())
        let footer = try busy.find(TaskScopeFooterView.self).actualView()
        XCTAssertTrue(footer.isWorking)
        XCTAssertTrue(footer.quitDisabled, "Quitting now would abandon the action half done")

        await gate.release()
        _ = await opening.value
        let idle = try Batch10.popover(fixture).inspect()
        XCTAssertFalse(try idle.find(PresetCard.self) { try $0.actualView().snapshot.preset.id == preset.id }.find(button: "Open").isDisabled())
        XCTAssertFalse(try idle.find(TaskScopeFooterView.self).actualView().quitDisabled)
    }

    func testSilentReadsDoNotTurnTheFooterIntoAProgressIndicator() async throws {
        let inventory = Batch10HeldInventory(processes: [Batch10.process(51)])
        let fixture = await Batch10.fixture(processes: [], inventory: inventory)
        defer { fixture.stores.cleanup() }
        fixture.manager.setMessage("Could not send stop to Example.")
        await inventory.holdNextLoad()
        let reading = Task { await fixture.manager.refreshWatchedStatus(showMessage: false) }
        let entered = await Batch10.waitUntilAsync { await inventory.gate.hasEntered() }
        XCTAssertTrue(entered, "setup: the read must be in flight")

        let footer = try Batch10.popover(fixture).inspect().find(TaskScopeFooterView.self).actualView()
        XCTAssertFalse(footer.isWorking, "A poll is not user-visible work")
        XCTAssertFalse(footer.quitDisabled)
        XCTAssertEqual(footer.message, "Could not send stop to Example.")

        await inventory.gate.release()
        _ = await reading.value
    }

    func testGlobalProtectCannotBeDeletedWhileItsKeepOffIsPending() async throws {
        let gate = Batch10Gate()
        let fixture = await heldFixture(gate: gate)
        defer { fixture.stores.cleanup() }
        let preset = WatchedAppPreset(displayName: "Editor", mainProcessName: "Editor", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Editor.app")
        XCTAssertTrue(fixture.stores.watchedApps.add(preset))
        let opening = Task { await fixture.manager.openApp(preset) }
        let entered = await Batch10.waitUntilAsync { await gate.hasEntered() }
        XCTAssertTrue(entered, "setup: Open must hold the operation gate")
        defer { Task { await gate.release() } }

        // Keep Off marks itself pending at once and then waits for the gate.
        let keepingOff = Task { await fixture.manager.keepOff(.globalProtect) }
        let pending = await Batch10.waitUntil { fixture.manager.isGlobalProtectKeepOffPending }
        XCTAssertTrue(pending, "setup: Keep Off must be pending")
        XCTAssertFalse(fixture.stores.settings.keepGlobalProtectOff)

        let settingsView = SettingsView(
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules,
            processManager: fixture.manager,
            selectedTab: .watchedApps
        )
        try settingsView.inspect().find(button: "Delete…").tap()
        XCTAssertTrue(
            fixture.stores.watchedApps.presets.contains { $0.id == WatchedAppPreset.globalProtectID },
            "Deleting the built-in preset while its Keep Off is pending would orphan its launchd overrides"
        )

        await gate.release()
        _ = await opening.value
        _ = await keepingOff.value
    }

    // MARK: Reports (A12-14)

    func testReportOnScreenSurvivesALaterReportUntilDone() async throws {
        let alpha = Batch10.process(61, name: "Alpha")
        let beta = Batch10.process(62, name: "Beta")
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let reports = ProcessReportPresentationState()
        await fixture.manager.batchTerminate([alpha.identity])
        let shown = try Batch10.popover(fixture, reportState: reports).inspect().find(ProcessBatchActionReportSheet.self).actualView()
        XCTAssertEqual(shown.report.targets.map(\.name), ["Alpha"])

        // A later action (another window, Shortcuts) replaces the manager's slot.
        await fixture.manager.batchTerminate([beta.identity])
        let still = try Batch10.popover(fixture, reportState: reports).inspect().find(ProcessBatchActionReportSheet.self).actualView()
        XCTAssertEqual(still.report.targets.map(\.name), ["Alpha"], "The report being read stays on screen")

        try Batch10.popover(fixture, reportState: reports).inspect().find(ProcessBatchActionReportSheet.self).find(button: "Done").tap()
        XCTAssertEqual(fixture.manager.batchActionReport?.targets.map(\.name), ["Beta"], "Done on the old report keeps the newer one")
        let next = try Batch10.popover(fixture, reportState: reports).inspect().find(ProcessBatchActionReportSheet.self).actualView()
        XCTAssertEqual(next.report.targets.map(\.name), ["Beta"])

        // A view that loses ownership (the regular window took over) forgets
        // what it kept, so it cannot show a stale report later.
        XCTAssertThrowsError(try Batch10.popover(fixture, reportState: reports, style: .menuBarCompact, mainWindowVisible: { true }).inspect().find(ProcessBatchActionReportSheet.self))
        XCTAssertNil(reports.batch)
    }

    func testReportSheetsSummariseAndCopyTheirDetails() throws {
        var copied: String?
        let lifecycle = LifecycleReport(title: "GlobalProtect Service Results", jobs: [
            .init(label: "com.example.agent", state: .failed, detail: "Boot-out failed: 5: Input/output error"),
            .init(label: "com.example.daemon", state: .changed, detail: "Disabled")
        ])
        let sheet = LifecycleReportSheet(report: lifecycle, copyReport: { copied = $0 }, onClose: {})
        XCTAssertNoThrow(try sheet.inspect().find(text: "1 succeeded, 1 failed"))
        try sheet.inspect().find(button: "Copy Report").tap()
        let text = try XCTUnwrap(copied)
        XCTAssertTrue(text.hasPrefix("GlobalProtect Service Results\n1 succeeded, 1 failed"))
        XCTAssertTrue(text.contains("com.example.agent: Failed — Boot-out failed: 5: Input/output error"))

        let empty = LifecycleReportSheet(report: LifecycleReport(title: "Nothing", jobs: []), onClose: {})
        XCTAssertNoThrow(try empty.inspect().find(text: "0 succeeded, 0 failed"))

        copied = nil
        let identity = Batch10.process(51).identity
        let batch = ProcessBatchActionReport(title: "Stop Results", targets: [
            ProcessTargetActionResult(identity: identity, name: "Example", state: .stopped),
            ProcessTargetActionResult(identity: identity, name: "Gone", state: .stale)
        ])
        let batchSheet = ProcessBatchActionReportSheet(report: batch, copyReport: { copied = $0 }, onClose: {})
        XCTAssertNoThrow(try batchSheet.inspect().find(text: "1 stopped, 0 still running, 1 not stopped"))
        try batchSheet.inspect().find(button: "Copy Report").tap()
        XCTAssertTrue(copied?.contains("Example (PID 51): Stopped") == true)
    }

    // MARK: Menu-bar alert (A12-2, A12-16, T02-12)

    func testMenuBarAlertListsEveryTargetAndKeepsReturnAwayFromTheDestructiveButton() {
        let details = (1...40).map { "Example \($0) (PID \($0)) — /Applications/Example.app/Contents/MacOS/Example" }.joined(separator: "\n")
        let alert = AppModalMenuBarConfirmation.makeAlert(MenuBarConfirmationRequest(
            title: "Stop Selected Processes?",
            message: "Stop 40 selected processes. Sends SIGTERM. Apps may close without asking to save changes.",
            confirmTitle: "Stop Selected",
            details: details
        ))
        XCTAssertEqual(alert.informativeText, "Stop 40 selected processes. Sends SIGTERM. Apps may close without asking to save changes.")
        let list = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView
        XCTAssertEqual(list?.string, details)
        XCTAssertEqual(alert.buttons.map(\.title), ["Stop Selected", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")

        let dismiss = AppModalMenuBarConfirmation.makeAlert(MenuBarConfirmationRequest(
            title: "Auto-Stop: Example", message: "Stop it now?", confirmTitle: "Stop Now", cancelTitle: "Dismiss"
        ))
        XCTAssertEqual(dismiss.buttons.map(\.title), ["Stop Now", "Dismiss"])
        XCTAssertNil(dismiss.accessoryView)
    }

    func testMenuBarBatchRequestCarriesTheFullTargetList() async throws {
        let targets = (1...5).map { Batch10.process(Int32(70 + $0), name: "Batch\($0)") }
        let fixture = await Batch10.fixture(processes: targets)
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let presenter = UIMenuBarConfirmation(answer: false)
        let view = Batch10.popover(fixture, state: state, confirmer: presenter)
        state.requestBatch(targets.map(\.identity), mode: .force, hiddenCount: 2)
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingBatchTermination)
        await state.waitForActions()
        let request = try XCTUnwrap(presenter.requests.first)
        XCTAssertEqual(request.confirmTitle, "Force Stop Selected")
        XCTAssertTrue(request.message.hasPrefix("Force stop 5 selected processes. 2 of these are not currently shown."))
        for target in targets {
            XCTAssertTrue(request.details?.contains("Batch\(target.pid - 70) (PID \(target.pid))") == true)
        }
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    func testWindowBatchReviewOrdersShownTargetsFirstAndCountsHiddenOnes() async throws {
        let shown = Batch10.process(81, name: "Shown", cpu: 50)
        let hidden = Batch10.process(82, name: "Hidden", cpu: 1)
        let fixture = await Batch10.fixture(processes: [hidden, shown])
        defer { fixture.stores.cleanup() }
        fixture.manager.select([shown, hidden])
        fixture.stores.settings.searchText = "Shown"
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)
        try view.inspect().find(button: "Stop Selected…").tap()
        let pending = try XCTUnwrap(state.pendingBatchTermination)
        XCTAssertEqual(Set(pending.targets), Set([shown.identity, hidden.identity]), "Exactly the selection is captured")
        XCTAssertEqual(pending.targets.first, shown.identity, "Rows on screen are listed first, in display order")
        XCTAssertEqual(pending.hiddenCount, 1)
        let review = try Batch10.popover(fixture, state: state).inspect().find(BatchStopReviewSheet.self)
        XCTAssertNoThrow(try review.find(text: "Stop 2 selected processes. 1 of these is not currently shown."))
        XCTAssertNoThrow(try review.find(text: "Hidden"))

        try review.find(button: "Stop Selected").tap()
        await state.waitForActions()
        XCTAssertEqual(Set(fixture.signaler.sent.map(\.pid)), [81, 82])
        XCTAssertTrue(fixture.signaler.sent.allSatisfy { $0.signal == SIGTERM })
    }

    // MARK: Process list sheets, menus and keys (A13-7, A11-6, L11-13, T02-8, L09-8)

    func testCancellingTheQuickRuleSheetClearsTheStoreError() async throws {
        let target = Batch10.process(51)
        let fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let rules = fixture.stores.autoStopRules
        XCTAssertFalse(rules.add(AutoStopRule(processName: "", runtimeMinutes: 1, action: .prompt)))
        XCTAssertNotNil(rules.validationError, "setup: a refused save leaves the shared error")
        let state = ProcessConfirmationState()
        try Batch10.popover(fixture, state: state).processContextMenu(for: target).inspect().find(button: "Create Auto-Stop Rule…").tap()
        XCTAssertEqual(state.quickAutoStopProcess?.identity, target.identity)
        let sheet = try Batch10.popover(fixture, state: state).inspect().find(QuickAutoStopRuleSheet.self).actualView()
        sheet.onCancel()
        XCTAssertNil(state.quickAutoStopProcess)
        XCTAssertNil(rules.validationError, "Settings > Auto-Stop must not inherit the quick sheet's error")
    }

    func testSavedSelectionMutationsAreUnavailableDuringRecovery() async throws {
        let target = Batch10.process(51)
        var fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let defaults = fixture.stores.defaults
        let source = SavedSelectionsStore(userDefaults: defaults, key: "source")
        XCTAssertTrue(source.save(name: "Saved", processes: [target]))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: "source"))) as? [Any])
        payload.append(42)
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "partial")
        let recovering = SavedSelectionsStore(userDefaults: defaults, key: "partial")
        XCTAssertTrue(recovering.isReadOnlyAfterCorruption)
        XCTAssertEqual(recovering.selections.map(\.name), ["Saved"])
        fixture.stores.savedSelections = recovering
        fixture.manager.select([target])

        let menu = try Batch10.popover(fixture).inspect()
        XCTAssertTrue(try menu.find(button: "Rename…").isDisabled())
        XCTAssertTrue(try menu.find(button: "Delete…").isDisabled())
        XCTAssertTrue(try menu.find(button: "Save Current Selection…").isDisabled())
        XCTAssertFalse(try menu.find(button: "Preview & Recall…").isDisabled(), "Recall stays available while mutations are locked")
    }

    func testWatchThisProcessIsOfferedOnlyWhereItCanSucceed() async throws {
        var tool = Batch10.process(51)
        tool.command = "/opt/homebrew/bin/ollama"
        tool.executablePath = "/opt/homebrew/bin/ollama"
        var foreign = Batch10.process(52, name: "Foreign")
        foreign.uid = getuid() &+ 1
        let app = Batch10.process(53, name: "Editor")
        let fixture = await Batch10.fixture(processes: [tool, foreign, app])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)
        XCTAssertTrue(try view.processContextMenu(for: tool).inspect().find(button: "Watch This Process…").isDisabled())
        XCTAssertTrue(try view.processContextMenu(for: foreign).inspect().find(button: "Watch This Process…").isDisabled())
        XCTAssertFalse(try view.processContextMenu(for: app).inspect().find(button: "Watch This Process…").isDisabled())
    }

    func testSaveSelectionAsPresetUsesTheFullSelectionNotTheDisplaySlice() async throws {
        let hot = Batch10.process(51, name: "Hot", cpu: 90)
        let cold = Batch10.process(52, name: "Cold", cpu: 1)
        let fixture = await Batch10.fixture(processes: [hot, cold])
        defer { fixture.stores.cleanup() }
        fixture.manager.processListLimitProvider = { 1 }
        fixture.manager.applyCurrentDisplayLimit()
        fixture.manager.select([cold])
        XCTAssertFalse(fixture.manager.displayProcesses(for: ProcessListQuery(searchText: "", filterMode: .all, watchedScopes: [], cpuHighlightThreshold: 50, memoryHighlightThresholdMB: 1_000)).contains { $0.pid == cold.pid }, "setup: the selection is outside the display limit")
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)
        try view.processContextMenu(for: hot).inspect().find(button: "Save Selection as Preset…").tap()
        XCTAssertEqual(state.quickPresetDraft?.processes.map(\.pid), [cold.pid])
    }

    func testCommandIShowsDetailForTheFocusedRowAndActionsSkipUnavailableOnes() async throws {
        let target = Batch10.process(51, name: "Focused")
        let own = Batch10.process(ProcessInfo.processInfo.processIdentifier, name: "TaskScope")
        let fixture = await Batch10.fixture(processes: [target, own])
        defer { fixture.stores.cleanup() }
        let list = ProcessListInteractionState()
        list.keyboardSelectedPid = target.pid
        list.keyboardSelectedIdentity = target.identity
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state, listState: list)
        view.showKeyboardDetail()
        XCTAssertEqual(state.detailProcess?.identity, target.identity)

        // A recycled PID does not inherit the focus.
        state.detailProcess = nil
        var reused = target
        reused.startTime = "new occupant"
        list.keyboardSelectedIdentity = reused.identity
        view.showKeyboardDetail()
        XCTAssertNil(state.detailProcess)
        view.toggleKeyboardSelection()
        XCTAssertTrue(fixture.manager.selectedPids.isEmpty)

        let ownActions = try view.processAccessibilityActions(for: own).inspect()
        XCTAssertThrowsError(try ownActions.find(button: "Force Stop…"))
        XCTAssertThrowsError(try ownActions.find(button: "Create Auto-Stop Rule…"))
        XCTAssertNoThrow(try ownActions.find(button: "Show Detail"))
        try view.processAccessibilityActions(for: target).inspect().find(button: "Force Stop…").tap()
        XCTAssertEqual(state.pendingTermination?.process.identity, target.identity)
        XCTAssertEqual(state.pendingTermination?.mode, .force)
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    // MARK: Settings from the popover (A12-18)

    func testSettingsButtonBringsTaskScopeForwardBeforeOpeningSettings() throws {
        var calls: [String] = []
        let header = TaskScopeHeaderView(
            status: .idle, samples: [], samplingState: .sampling, showsMetrics: false,
            showsOpenWindowButton: false, refreshAction: {},
            settingsActivation: { calls.append("activate") },
            openSettingsOverride: { calls.append("open") }
        )
        try header.inspect().find(OpenSettingsButton<Image>.self).find(ViewType.Button.self).tap()
        XCTAssertEqual(calls, ["activate", "open"])
    }

    // MARK: Process Detail (A03-11)

    /// Reads only: `ps` for this test process and for a child it started and
    /// reaped itself.
    func testDetailReadTellsAGoneProcessFromAChangedOneAndAFailedRead() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = await ShellCommandRunner.run("/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(pid)")
        let line = try XCTUnwrap(own.stdout.split(separator: "\n").first.map(String.init))
        let startTime = try XCTUnwrap(SystemProcessDetailReader.parseDetailLine(line, expectedStartTime: nil)).startTime
        let reader = SystemProcessDetailReader()

        // The identity includes the kernel executable path, so the row carries
        // this process's real one.
        var current = Batch10.process(pid, startTime: startTime)
        current.executablePath = ProcessListReader.executablePath(for: pid)
        guard case .loaded(let detail) = await reader.readResult(for: current) else {
            return XCTFail("This test process must load")
        }
        XCTAssertEqual(detail.pid, pid)
        // L11-18: the same PID and start time running another executable is
        // another process.
        let otherExecutable = await reader.readResult(for: Batch10.process(pid, startTime: startTime))
        XCTAssertEqual(otherExecutable, .identityChanged)

        let earlierOccupant = Batch10.process(pid, startTime: "Mon Jan  1 00:00:00 2001")
        let changed = await reader.readResult(for: earlierOccupant)
        XCTAssertEqual(changed, .identityChanged)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let gone = await reader.readResult(for: Batch10.process(child.processIdentifier))
        XCTAssertEqual(gone, .gone)

        XCTAssertEqual(ProcessDetailResult.gone.message, "This process is no longer running.")
        XCTAssertEqual(ProcessDetailResult.readFailed("ps timed out").message, "Could not read process detail: ps timed out.")
    }

    // MARK: Helpers

    private func heldFixture(gate: Batch10Gate) async -> UIFixture {
        let inventory = UIInventory(processes: [])
        let signaler = UIRecordingSignaler()
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: signaler, lifecycle: Batch10HeldOpenLifecycle(gate: gate),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false
        let stores = Batch10.stores(inventory: inventory)
        manager.watchedAppsProvider = { stores.watchedApps.presets }
        await manager.loadProcessList(showMessage: false)
        return UIFixture(manager: manager, signaler: signaler, stores: stores, lifecycle: UILifecycle())
    }
}

/// An inventory a test can change between Auto Stop passes.
actor Batch10MutableInventory: ProcessInventoryProviding {
    private var processes: [AppProcess]

    init(processes: [AppProcess]) { self.processes = processes }

    func setProcesses(_ processes: [AppProcess]) { self.processes = processes }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
