import AppKit
import Combine
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class Batch10FixTests: XCTestCase {
    func testModalResponseMappingAndSafeDefaultKey() async throws {
        let request = MenuBarConfirmationRequest(title: "Stop?", message: "Review target", confirmTitle: "Stop")
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .abort] {
            let presenter = AppModalMenuBarConfirmation(runAlert: { alert in
                XCTAssertEqual(alert.messageText, request.title)
                XCTAssertEqual(alert.informativeText, request.message)
                XCTAssertEqual(alert.buttons.map(\.title), ["Stop", "Cancel"])
                XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
                XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
                XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
                return response
            })
            let confirmed = await presenter.confirm(request)
            XCTAssertEqual(confirmed, response == .alertFirstButtonReturn)
        }
    }

    func testMenuModalRunLoopKeepsMainQueueAndMainActorResponsive() async {
        let tick = Batch10Tick()
        let presenter = AppModalMenuBarConfirmation(runAlert: { _ in
            DispatchQueue.main.async { tick.queueRan = true }
            Task { @MainActor in tick.actorRan = true }
            let deadline = Date().addingTimeInterval(1)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            while (!tick.queueRan || !tick.actorRan) && Date() < deadline
            return .alertSecondButtonReturn
        })
        _ = await presenter.confirm(.init(title: "Test", message: "", confirmTitle: "Stop"))
        XCTAssertTrue(tick.queueRan)
        XCTAssertTrue(tick.actorRan)
    }

    func testMenuRequestMustStillBeCurrentBeforeAndAfterAwait() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51), Batch10.process(52)])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let presenter = Batch10HeldConfirmation()
        let view = Batch10.popover(fixture, state: state, confirmer: presenter)
        state.requestTermination(Batch10.process(51))
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingTermination)
        state.clearTermination()
        await state.waitForActions()
        XCTAssertTrue(presenter.requests.isEmpty, "A request cleared before presentation must never open an alert")

        state.requestTermination(Batch10.process(51))
        try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingTermination)
        await presenter.waitUntilPresented()
        state.requestTermination(Batch10.process(52))
        presenter.answer(true)
        await state.waitForActions()
        XCTAssertEqual(state.pendingTermination?.process.pid, 52)
        XCTAssertTrue(fixture.signaler.sent.isEmpty, "An old answer must not stop anything or clear a replacement request")
    }

    func testContextAndSelectionMenusCaptureTheRequestedStopMode() async throws {
        let target = Batch10.process(51)
        let fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = try await installed(Batch10.popover(fixture, state: state))
        for (title, mode) in [("Stop…", ProcessConfirmationState.TerminationMode.normal), ("Force Stop…", .force)] {
            try view.processContextMenu(for: target).inspect().find(button: title).tap()
            XCTAssertEqual(state.pendingTermination?.process.identity, target.identity)
            XCTAssertEqual(state.pendingTermination?.mode, mode)
            state.clearTermination()
        }
        fixture.manager.select([target])
        for (title, mode) in [("Stop Selected…", ProcessConfirmationState.TerminationMode.normal), ("Force Stop Selected…", .force)] {
            try view.inspect().find(button: title).tap()
            XCTAssertEqual(state.pendingBatchTermination?.targets, [target.identity])
            XCTAssertEqual(state.pendingBatchTermination?.mode, mode)
            state.clearBatch()
        }
    }

    func testCardQuitButtonsAndConfirmedWindowAndMenuRoutesAreScoped() async throws {
        for menuBar in [false, true] {
            for action in [ProcessConfirmationState.PresetAction.quitApp, .quitHelpers] {
                let main = Batch10.process(51)
                var helper = Batch10.process(52)
                helper.command = "/Applications/Example.app/Contents/Helpers/Helper"
                helper.executablePath = helper.command
                let fixture = await Batch10.fixture(processes: [main, helper])
                defer { fixture.stores.cleanup() }
                let preset = WatchedAppPreset(displayName: "Work App", mainProcessName: "Example",
                    helperProcessNames: ["Helper"], protectedProcessNames: [], appPath: "/Applications/Example.app")
                XCTAssertTrue(fixture.stores.watchedApps.add(preset))
                fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
                let state = ProcessConfirmationState()
                let presenter = UIMenuBarConfirmation(answer: true)
                let view = Batch10.popover(fixture, state: state, confirmer: menuBar ? presenter : nil)
                let card = try XCTUnwrap(view.inspect().findAll(PresetCard.self).first {
                    try $0.actualView().snapshot.preset.id == preset.id
                })
                try card.find(button: action.rawValue + "…").tap()
                XCTAssertEqual(state.pendingPresetAction?.action, action)
                XCTAssertEqual(state.pendingPresetAction?.preset.id, preset.id)
                XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
                let pending = try XCTUnwrap(state.pendingPresetAction)
                XCTAssertTrue(pending.title.contains("Work App"))
                if menuBar {
                    try view.inspect().vStack().callOnChange(oldValue: nil, newValue: state.pendingPresetAction)
                } else {
                    try view.inspect().find(ViewType.ConfirmationDialog.self).actions().find(button: pending.confirmTitle).tap()
                }
                await state.waitForActions()
                if action == .quitApp {
                    XCTAssertEqual(fixture.lifecycle.calls.filter { $0 != "settle" }, ["agents.unload", "terminate:Example"])
                    XCTAssertEqual(fixture.lifecycle.presetsByCall["terminate"]?.map(\.displayName), ["Work App"])
                    XCTAssertEqual(fixture.lifecycle.preservedPIDs, [], "Quit App unloads every agent")
                } else {
                    XCTAssertEqual(fixture.lifecycle.calls.filter { $0 != "settle" }, ["agents.unload", "terminate.helper:Helper"])
                    XCTAssertEqual(fixture.lifecycle.preservedPIDs.count, 1, "Quit Helpers keeps the app's agents")
                }
            }
        }
    }

    func testRealCardKeepOffControlsOnlyRequestConfirmationAndScopeBadge() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let preset = WatchedAppPreset(displayName: "Editor", mainProcessName: "Editor", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Editor.app")
        XCTAssertTrue(fixture.stores.watchedApps.add(preset))
        fixture.stores.settings.keepGlobalProtectOff = true
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        let state = ProcessConfirmationState()
        let cards = try await hosted(Batch10.popover(fixture, state: state)).findAll(PresetCard.self)
        let gp = try XCTUnwrap(cards.first { try $0.actualView().snapshot.preset.isBuiltInGlobalProtect })
        let editor = try XCTUnwrap(cards.first { try $0.actualView().snapshot.preset.id == preset.id })
        XCTAssertTrue(try gp.actualView().isKeptOff)
        XCTAssertFalse(try editor.actualView().isKeptOff)
        XCTAssertNoThrow(try editor.find(text: "Quiet"))
        let gpCard = try gp.actualView()
        gpCard.onKeepOffChanged(true)
        XCTAssertEqual(state.pendingPresetAction?.action, .keepOff)
        XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
        state.clearPresetAction()
        try gp.find(button: "Apply Keep Off…").tap()
        XCTAssertEqual(state.pendingPresetAction?.action, .keepOff)
        XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
    }

    func testQuickPresetWithoutHelpersDisablesOnlyUselessHelperAction() throws {
        for withAgent in [false, true] {
            var preset = WatchedAppPreset(displayName: "Work", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Example.app")
            if withAgent { preset.userLaunchAgentJobs = WatchedAppPreset.globalProtect.userLaunchAgentJobs }
            let card = PresetCard(snapshot: .init(preset: preset, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in })
            XCTAssertEqual(try card.inspect().find(button: "Quit Helpers…").isDisabled(), !withAgent)
            let message = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: preset, action: .quitApp))
            XCTAssertTrue(message.hasPrefix("TaskScope will"))
            XCTAssertTrue(message.contains("Apps may close without asking to save changes."))
            // Only the built-in VPN preset carries the network shield.
            XCTAssertEqual(try card.inspect().vStack().hStack(0).label(0).icon().image().actualImage().name(), "app")
        }
        let builtIn = PresetCard(snapshot: .init(preset: .globalProtect, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in })
        XCTAssertEqual(try builtIn.inspect().vStack().hStack(0).label(0).icon().image().actualImage().name(), "network.badge.shield.half.filled")
    }

    func testOwnRowButtonsRefuseTapsAndOtherRowsRemainEnabled() throws {
        for own in [false, true] {
            var selections = 0
            var stops = 0
            let row = ProcessRow(process: Batch10.process(48165), isCurrentProcess: own, isSelected: false, isKeyboardSelected: true,
                isHighlightedCPU: true, isHighlightedMEM: true, showsExpandedMetrics: true,
                stopAction: { stops += 1 }, toggleSelection: { selections += 1 })
            let buttons = try row.inspect().findAll(ViewType.Button.self)
            XCTAssertEqual(buttons.count, 2)
            XCTAssertEqual(buttons[0].isDisabled(), own)
            XCTAssertEqual(buttons[1].isDisabled(), own)
            if own {
                XCTAssertThrowsError(try buttons[0].tap())
                XCTAssertThrowsError(try buttons[1].tap())
                XCTAssertEqual(stops, 0)
                XCTAssertEqual(selections, 0)
            } else {
                try buttons[0].tap(); try buttons[1].tap()
                XCTAssertEqual(stops, 1); XCTAssertEqual(selections, 1)
                XCTAssertTrue(try buttons[1].accessibilityLabel().string().contains("48165"))
            }
            XCTAssertEqual(try row.inspect().findAll(ViewType.Text.self).filter { try $0.string() == "48165" }.count, 2)
        }
    }

    func testBatchReviewListsAllCapturedTargetsAndUsesRowNames() {
        let targets = (1...8).map { Batch10.process(Int32($0), name: "Example \($0)").identity }
        let pending = ProcessConfirmationState.PendingBatchTermination(targets: targets, mode: .normal, hiddenCount: 5)
        // Every captured target is named, not just the first three.
        XCTAssertEqual(pending.rows.map(\.pid), targets.map(\.pid))
        for target in targets {
            XCTAssertTrue(pending.message.contains("PID \(target.pid)"))
            XCTAssertTrue(pending.message.contains(AppProcess.name(from: target.command)))
            XCTAssertTrue(pending.message.contains(target.executablePath!))
            XCTAssertTrue(pending.menuBarRequest.details?.contains("\(AppProcess.name(from: target.command)) (PID \(target.pid))") == true)
        }
        XCTAssertEqual(pending.summary, "Stop 8 selected processes. 5 of these are not currently shown.")
        XCTAssertEqual(
            ProcessConfirmationState.PendingBatchTermination(targets: targets, mode: .normal, hiddenCount: 1).summary,
            "Stop 8 selected processes. 1 of these is not currently shown."
        )
        XCTAssertEqual(
            ProcessConfirmationState.PendingBatchTermination(targets: [targets[0]], mode: .force).summary,
            "Force stop 1 selected process."
        )
    }

    func testTreeExpandsNewMatchesWithoutReopeningManuallyCollapsedKnownBranches() {
        let parent = Batch10.process(51)
        let child = Batch10.process(52, parent: 51)
        let added = Batch10.process(53, parent: 51)
        let state = ProcessListInteractionState()
        state.updateTree(matches: [parent, child], roots: [.init(process: parent, children: [.init(process: child, children: [])])])
        XCTAssertEqual(state.expandedTreePids, [51])
        state.expandedTreePids.remove(51)
        state.updateTree(matches: [parent, child], roots: [.init(process: parent, children: [.init(process: child, children: [])])])
        XCTAssertTrue(state.expandedTreePids.isEmpty)
        state.updateTree(matches: [parent, child, added], roots: [.init(process: parent, children: [.init(process: child, children: []), .init(process: added, children: [])])])
        XCTAssertEqual(state.expandedTreePids, [51])
    }

    func testKeyboardMovementSelectionDisclosureEscapeAndRecycledPIDFocus() async throws {
        let parent = Batch10.process(51, name: "Ancestor")
        let child = Batch10.process(52, parent: 51, name: "Needle")
        let hidden = Batch10.process(53, name: "Other")
        let bystander = Batch10.process(54, name: "Bystander")
        let fixture = await Batch10.fixture(processes: [parent, child, hidden, bystander])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.searchText = "Needle"
        // The installed popover takes tree mode from Settings when it appears.
        fixture.stores.settings.treeMode = true
        let interaction = ProcessListInteractionState()
        interaction.expandedTreePids = [51]
        interaction.keyboardSelectedPid = 52
        interaction.keyboardSelectedIdentity = child.identity
        let state = ProcessConfirmationState()
        let view = try await installed(Batch10.popover(fixture, state: state, listState: interaction))
        fixture.manager.select([hidden])
        view.selectAllVisibleMatches()
        XCTAssertEqual(fixture.manager.selectedPids, [52, 53], "Select All preserves hidden choices and excludes context ancestors")
        XCTAssertFalse(fixture.manager.selectedPids.contains(bystander.pid), "Select All never adds a hidden row that does not match")
        view.toggleKeyboardSelection()
        XCTAssertEqual(fixture.manager.selectedPids, [53])
        view.clearKeyboardFocus()
        XCTAssertEqual(fixture.manager.selectedPids, [53])
        XCTAssertNil(interaction.keyboardSelectedPid)
        interaction.keyboardSelectedPid = 51
        view.setKeyboardDisclosure(expanded: false)
        XCTAssertTrue(interaction.expandedTreePids.isEmpty)
        view.setKeyboardDisclosure(expanded: true)
        XCTAssertEqual(interaction.expandedTreePids, [51])
        XCTAssertEqual(ProcessListInteractionState.nextFocus(current: nil, delta: -1, processes: [parent, child])?.pid, 51)
        XCTAssertEqual(ProcessListInteractionState.nextFocus(current: nil, delta: 1, processes: [parent, child])?.pid, 51)
        XCTAssertEqual(ProcessListInteractionState.nextFocus(current: 52, delta: -1, processes: [parent, child])?.pid, 51)
        XCTAssertEqual(ProcessListInteractionState.nextFocus(current: 51, delta: 1, processes: [parent, child])?.pid, 52)
        XCTAssertEqual(ProcessListInteractionState.nextFocus(current: 52, delta: 1, processes: [parent, child])?.pid, 52)
        var reused = child; reused.startTime = "new occupant"
        interaction.keyboardSelectedPid = 52
        interaction.keyboardSelectedIdentity = reused.identity
        view.requestKeyboardTermination(pid: 52)
        XCTAssertNil(state.pendingTermination)
        interaction.retainLiveFocus(in: [parent, child])
        XCTAssertNil(interaction.keyboardSelectedPid)
    }

    func testHistoryFailureIsVisibleAndRecoveryStartsANewSegment() async throws {
        let inventory = ScriptedInventory([.success([Batch10.process(51)]), .failure(.commandFailed("read failed")), .success([Batch10.process(51)])], repeatsLast: true)
        let history = ProcessHistory(inventory: inventory)
        await history.sampleNow(); await history.sampleNow()
        XCTAssertEqual(history.samples.count, 1)
        let header = TaskScopeHeaderView(status: .idle, samples: history.samples, samplingState: history.state, showsMetrics: true, showsOpenWindowButton: false, refreshAction: {})
        XCTAssertNoThrow(try header.inspect().find(text: "History unavailable"))
        XCTAssertTrue(history.state.detail.contains("read failed"))
        await history.sampleNow()
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertTrue(history.samples[1].startsNewSegment)
    }

    func testActionFeedbackAnnouncesChangesOnceAndNotSilentPolls() async {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        var announcements: [String] = []
        let feedback = ProcessActionFeedback(manager: fixture.manager, announce: { announcements.append($0) })
        fixture.manager.setMessage("Could not stop Example.")
        fixture.manager.setMessage("Could not stop Example.")
        await fixture.manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(announcements, ["Could not stop Example."])
        withExtendedLifetime(feedback) {}
    }

    func testFooterKeepsResultDuringWorkAndDisablesQuitDuringMutation() throws {
        var quit = false
        let view = TaskScopeFooterView(isWorking: true, message: "A long failure. Open System Settings and enable Accessibility, then try again.", summary: nil, quitDisabled: true, quitAction: { quit = true })
        // The whole result stays readable: no one-line truncation.
        XCTAssertNil(try view.inspect().find(text: view.message).lineLimit())
        let idle = TaskScopeFooterView(isWorking: false, message: view.message, summary: "Σ shown 1.0% CPU · 1 MB MEM", quitAction: {})
        XCTAssertNil(try idle.inspect().find(text: view.message).lineLimit())
        let button = try XCTUnwrap(view.inspect().findAll(ViewType.Button.self).first)
        XCTAssertTrue(button.isDisabled())
        XCTAssertThrowsError(try button.tap())
        XCTAssertFalse(quit)
    }

    func testQuickWatchAvailabilityRejectsToolsOtherUsersAndUntrustedPaths() {
        XCTAssertNil(QuickWatchedPresetDraft.unavailabilityReason(for: Batch10.process(51)))
        var target = Batch10.process(51)
        target.executablePath = "/usr/bin/tool"
        XCTAssertNotNil(QuickWatchedPresetDraft.unavailabilityReason(for: target))
        target = Batch10.process(51); target.uid = getuid() + 1
        XCTAssertNotNil(QuickWatchedPresetDraft.unavailabilityReason(for: target))
        target = Batch10.process(51); target.executablePath = nil
        XCTAssertNotNil(QuickWatchedPresetDraft.unavailabilityReason(for: target))
    }

    func testRecallSuccessAndFailureHaveObservablePendingState() async throws {
        for success in [false, true] {
            let fixture = await Batch10.fixture(processes: [Batch10.process(51)], inventory: ScriptedInventory(processes: [Batch10.process(51)]))
            defer { fixture.stores.cleanup() }
            XCTAssertTrue(fixture.stores.savedSelections.save(name: "Example", processes: [Batch10.process(51)]))
            let inventory = ScriptedInventory(success ? [.success([Batch10.process(51)])] : [.failure(.commandFailed("ps timed out."))])
            let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory, processSignaler: fixture.signaler, lifecycle: fixture.lifecycle, settleAfterProcessChange: {}, dependencies: .inert)
            manager.enableNotifications = false
            var modified = fixture; modified.manager = manager
            let state = ProcessConfirmationState()
            try await hosted(Batch10.popover(modified, state: state)).find(button: "Preview & Recall…").tap()
            await state.waitForActions()
            XCTAssertEqual(state.pendingRecallSelection != nil, success)
            XCTAssertEqual(state.pendingRecallResult != nil, success)
            if !success { XCTAssertEqual(manager.message, "Could not preview saved selection: ps timed out.") }
        }
    }

    func testRejectedQuickPresetCannotReportSuccess() async {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)
        let preset = WatchedAppPreset(displayName: "Invalid", mainProcessName: "Invalid", helperProcessNames: [], protectedProcessNames: [], appPath: "/usr/bin/tool")
        XCTAssertNotNil(view.saveQuickWatchedPreset(preset))
        XCTAssertEqual(fixture.manager.message, "Idle.")
        XCTAssertFalse(fixture.stores.watchedApps.presets.contains { $0.id == preset.id })
    }

    func testPresetsRecoveryDoesNotMasqueradeAsAnEmptyList() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.defaults.set(Data([0xff]), forKey: "broken")
        let watched = WatchedAppsStore(userDefaults: fixture.stores.defaults, key: "broken")
        XCTAssertTrue(watched.isReadOnlyAfterCorruption)
        fixture.stores.settings.keepGlobalProtectOff = true
        let view = PresetsSectionView(processManager: fixture.manager, loginItemManager: LoginItemManager(service: UILoginItemService()), settings: fixture.stores.settings, watchedApps: watched, confirmationState: ProcessConfirmationState())
        XCTAssertNoThrow(try view.inspect().find(text: watched.persistenceIssue!))
        XCTAssertNoThrow(try view.inspect().find(text: "Keep GlobalProtect Off is not being enforced until presets are reset."))
        XCTAssertThrowsError(try view.inspect().find(text: "No watched apps configured. Add presets in Settings."))
    }

    func testDetailStatesRetryAndMetricObservationAreExplicit() throws {
        for failure in [ProcessDetailResult.gone, .identityChanged, .readFailed("timeout")] {
            var retries = 0
            var closes = 0
            let view = ProcessDetailSheet(process: Batch10.process(51), detail: nil, failed: true, failure: failure, onRetry: { retries += 1 }, onClose: { closes += 1 })
            XCTAssertNoThrow(try view.inspect().find(text: failure.message!))
            if case .readFailed = failure {
                try view.inspect().find(button: "Retry").tap()
                XCTAssertEqual(retries, 1)
            } else { XCTAssertThrowsError(try view.inspect().find(button: "Retry")) }
            try view.inspect().find(button: "Close").tap()
            XCTAssertEqual(closes, 1)
        }
        let loading = ProcessDetailSheet(process: Batch10.process(51), detail: nil, failed: false, onClose: {})
        XCTAssertNoThrow(try loading.inspect().find(ViewType.ProgressView.self))
    }

    func testReportSheetsRemainReadableUntilDoneAndRespectOwnership() async throws {
        let target = Batch10.process(51)
        let fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        await fixture.manager.batchTerminate([target.identity])
        // Test windows are never key, so the active state is set explicitly.
        for style in [TaskScopePresentationStyle.expandedWindow, .menuBarCompact] {
            let view = try await hosted(Batch10.popover(fixture, style: style, windowState: .key))
            XCTAssertNoThrow(try view.find(ProcessBatchActionReportSheet.self))
        }
        let inactive = try await hosted(Batch10.popover(fixture, windowState: .inactive))
        XCTAssertThrowsError(try inactive.find(ProcessBatchActionReportSheet.self))
        let menuWithWindow = try await hosted(Batch10.popover(fixture, style: .menuBarCompact, windowState: .key, mainWindowVisible: { true }))
        XCTAssertThrowsError(try menuWithWindow.find(ProcessBatchActionReportSheet.self))
        let view = try await hosted(Batch10.popover(fixture, windowState: .key))
        try view.find(ProcessBatchActionReportSheet.self).find(button: "Done").tap()
        XCTAssertNil(fixture.manager.batchActionReport)
        let reportState = ProcessReportPresentationState()
        let first = LifecycleReport(title: "First", jobs: [.init(label: "job", state: .failed, detail: "A long failure")])
        let next = LifecycleReport(title: "Second", jobs: [])
        XCTAssertEqual(reportState.retain(first)?.id, first.id)
        XCTAssertEqual(reportState.retain(nil as LifecycleReport?)?.id, first.id)
        XCTAssertEqual(reportState.retain(next)?.id, first.id)
        reportState.dismissLifecycle()
        XCTAssertEqual(reportState.retain(next)?.id, next.id)
        var closed = false
        let sheet = LifecycleReportSheet(report: first, onClose: { closed = true })
        XCTAssertNoThrow(try sheet.inspect().find(text: "A long failure"))
        try sheet.inspect().find(button: "Done").tap()
        XCTAssertTrue(closed)
    }
}

@MainActor
private final class Batch10Tick {
    var queueRan = false
    var actorRan = false
}
