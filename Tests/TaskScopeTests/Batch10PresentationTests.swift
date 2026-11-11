import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Batch 10: what the main window and the menu-bar popover show and announce.
@MainActor
final class Batch10PresentationTests: XCTestCase {
    // L09-1: identifiers are drawn as ps prints them, without locale grouping.
    func testPIDsAreDrawnWithoutDigitGrouping() {
        var process = Batch10.process(48165)
        process.parentPID = 12345
        let row = ProcessRow(
            process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
            isHighlightedCPU: false, isHighlightedMEM: false, showsExpandedMetrics: true,
            stopAction: {}, toggleSelection: {}
        )
        let drawn = Batch10.renderedText(row)
        XCTAssertTrue(drawn.contains("48165"), drawn)
        XCTAssertTrue(drawn.contains("12345"), drawn)
        XCTAssertFalse(drawn.contains("48,165"), drawn)
        XCTAssertFalse(drawn.contains("12,345"), drawn)

        // The report sheet's list rows (a List is not drawn by ImageRenderer,
        // so its row view is rendered on its own).
        let result = ProcessTargetActionResult(identity: process.identity, name: "Example", state: .stopped)
        let reportRow = Batch10.renderedText(ProcessBatchActionReportRow(target: result))
        XCTAssertTrue(reportRow.contains("PID 48165"), reportRow)
        XCTAssertFalse(reportRow.contains("48,165"), reportRow)
    }

    // A12-9: a busy process's NET / DISK pair shrinks instead of wrapping.
    func testTrafficPairsStayOnOneLine() throws {
        var process = Batch10.process(51)
        process.diskReadBytes = 123_456_789_000
        process.diskWriteBytes = 98_765_432_000
        let row = ProcessRow(
            process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
            isHighlightedCPU: false, isHighlightedMEM: false, showsExpandedMetrics: true,
            stopAction: {}, toggleSelection: {}
        )
        let net = try row.inspect().find(text: "123456789.0 / 123456789.0")
        XCTAssertEqual(try net.lineLimit(), 1)
        let disk = try row.inspect().find(text: "117737.6 / 94190.1")
        XCTAssertEqual(try disk.lineLimit(), 1)
    }

    // L10-14: an over-threshold value is marked by a glyph and weight, keeps the
    // primary colour, and keeps the cue while the row has keyboard focus.
    func testHighlightedValuesAreMarkedWithoutRelyingOnColour() throws {
        for focused in [false, true] {
            let row = ProcessRow(
                process: Batch10.process(51, cpu: 97.5), isCurrentProcess: false, isSelected: false,
                isKeyboardSelected: focused, isHighlightedCPU: true, isHighlightedMEM: false,
                stopAction: {}, toggleSelection: {}
            )
            let glyphs = try row.inspect().findAll(ViewType.Image.self) {
                try $0.actualImage().name() == "arrow.up"
            }
            XCTAssertEqual(glyphs.count, 1, "Exactly the CPU value is marked")
            let cpu = try row.inspect().find(text: "97.5")
            XCTAssertEqual(try cpu.attributes().fontWeight(), .bold)
            XCTAssertThrowsError(try cpu.attributes().foregroundColor(), "No red text: the colour alone carried the warning")
        }
        let plain = ProcessRow(
            process: Batch10.process(51, cpu: 1), isCurrentProcess: false, isSelected: false,
            isKeyboardSelected: false, isHighlightedCPU: false, isHighlightedMEM: false,
            stopAction: {}, toggleSelection: {}
        )
        XCTAssertTrue(try plain.inspect().findAll(ViewType.Image.self) { try $0.actualImage().name() == "arrow.up" }.isEmpty)
    }

    // A12-12: keyboard focus, tree level and context-only ancestors reach
    // assistive technology; the own-process Stop button says why it is off.
    func testRowExposesFocusLevelAndContextToAccessibility() throws {
        let row = ProcessRow(
            process: Batch10.process(51, name: "Helper"), isCurrentProcess: false, isSelected: false,
            isKeyboardSelected: true, isHighlightedCPU: false, isHighlightedMEM: false,
            treeLevel: 2, isContextOnly: true, stopAction: {}, toggleSelection: {}
        )
        let name = try row.inspect().find(ViewType.VStack.self) {
            try $0.accessibilityLabel().string() == "Helper, PID 51"
        }
        XCTAssertTrue(try name.accessibilityTraits().contains(.isSelected))
        let value = try name.accessibilityValue().string()
        XCTAssertTrue(value.contains("level 2"), value)
        XCTAssertTrue(value.contains("does not match the search or filter"), value)

        let unfocused = ProcessRow(
            process: Batch10.process(51, name: "Helper"), isCurrentProcess: false, isSelected: false,
            isKeyboardSelected: false, isHighlightedCPU: false, isHighlightedMEM: false,
            stopAction: {}, toggleSelection: {}
        )
        let plainName = try unfocused.inspect().find(ViewType.VStack.self) {
            try $0.accessibilityLabel().string() == "Helper, PID 51"
        }
        XCTAssertFalse(try plainName.accessibilityTraits().contains(.isSelected))
        XCTAssertFalse(try plainName.accessibilityValue().string().contains("level"))

        let own = ProcessRow(
            process: Batch10.process(51, name: "TaskScope"), isCurrentProcess: true, isSelected: false,
            isKeyboardSelected: false, isHighlightedCPU: false, isHighlightedMEM: false,
            stopAction: {}, toggleSelection: {}
        )
        let buttons = try own.inspect().findAll(ViewType.Button.self)
        XCTAssertEqual(try buttons[1].accessibilityLabel().string(), "TaskScope cannot be stopped here")
    }

    // A05-4: in tree view, ancestors that are shown only for context are marked,
    // and the count line says how many rows are on screen.
    func testTreeMarksContextOnlyAncestorsAndCountsVisibleRows() async throws {
        let parent = Batch10.process(51, name: "Terminal")
        let child = Batch10.process(52, parent: 51, name: "Needle")
        let fixture = await Batch10.fixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.searchText = "Needle"
        let list = ProcessListInteractionState()
        list.treeMode = true
        list.expandedTreePids = [51]
        let view = Batch10.popover(fixture, listState: list)
        let rows = try view.inspect().findAll(ProcessRow.self)
        let context = try XCTUnwrap(rows.first { try $0.actualView().process.pid == 51 })
        let match = try XCTUnwrap(rows.first { try $0.actualView().process.pid == 52 })
        XCTAssertTrue(try context.actualView().isContextOnly)
        XCTAssertEqual(try context.actualView().treeLevel, 1)
        XCTAssertFalse(try match.actualView().isContextOnly)
        XCTAssertEqual(try match.actualView().treeLevel, 2)
        XCTAssertNoThrow(try view.inspect().find(text: "1 match, 2 rows visible"))
    }

    // A05-4: an unfiltered tree opens the path to every displayed row, and a
    // match that appears on a later reload is not left under a collapsed node.
    func testTreeExpansionReachesMatchesWithoutASearchAndOnReload() {
        let root = Batch10.process(1, parent: 0, name: "launchd")
        let app = Batch10.process(51, name: "App")
        let worker = Batch10.process(52, parent: 51, name: "Worker")
        let state = ProcessListInteractionState()
        let tree: [ProcessTreeNode] = [
            .init(process: root, children: [
                .init(process: app, children: [.init(process: worker, children: [])])
            ])
        ]
        state.updateTree(matches: [root, app], roots: tree)
        XCTAssertEqual(state.expandedTreePids, [1])
        state.expandedTreePids = []
        state.updateTree(matches: [root, app, worker], roots: tree)
        XCTAssertEqual(state.expandedTreePids, [1, 51], "The new match's ancestors open; nothing else changes")
    }

    // L09-16 / L10-18: decorative images are hidden from VoiceOver; the Sort
    // pop-up is named once; the search field has its own label.
    func testDecorativeImagesAreHiddenAndControlsAreNamedOnce() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51, name: "Leaf"), Batch10.process(52, parent: 51, name: "Child")])
        defer { fixture.stores.cleanup() }
        let list = ProcessListInteractionState()
        list.treeMode = true
        list.expandedTreePids = [51]
        let view = Batch10.popover(fixture, listState: list)
        let inspected = try view.inspect()

        let glass = try inspected.find(ViewType.Image.self) { try $0.actualImage().name() == "magnifyingglass" }
        XCTAssertTrue(try glass.accessibilityHidden())
        XCTAssertEqual(try inspected.find(ViewType.TextField.self).accessibilityLabel().string(), "Search processes")
        // Only the leaf row (pid 52) has the invisible alignment spacer; the
        // expanded parent shows "chevron.down".
        let spacer = try inspected.find(ViewType.Image.self) { try $0.actualImage().name() == "chevron.right" }
        XCTAssertTrue(try spacer.accessibilityHidden())
        let sort = try inspected.find(ViewType.Picker.self) { try $0.labelView().text().string() == "Sort" }
        XCTAssertThrowsError(try sort.accessibilityLabel(), "The hidden title already names the pop-up")

        let header = TaskScopeHeaderView(status: .idle, samples: [], samplingState: .sampling, showsMetrics: false, showsOpenWindowButton: false, refreshAction: {})
        let logo = try header.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "waveform.path.ecg" }
        XCTAssertTrue(try logo.accessibilityHidden())

        let empty = LightweightEmptyState {}
        let leaf = try empty.inspect().find(ViewType.Image.self) { try $0.actualImage().name() == "leaf" }
        XCTAssertTrue(try leaf.accessibilityHidden())
    }

    // L10-18: the first-load error keeps Retry as its own button.
    func testFirstLoadErrorKeepsRetrySeparateAndPunctuated() async throws {
        let inventory = UIScriptedInventory(results: [.failure(.commandFailed("ps exited with status 1"))])
        let fixture = await Batch10.fixture(processes: [], inventory: inventory)
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "ps exited with status 1."))
        let icon = try inspected.find(ViewType.Image.self) { try $0.actualImage().name() == "exclamationmark.triangle" }
        XCTAssertTrue(try icon.accessibilityHidden())
        XCTAssertNoThrow(try inspected.find(button: "Retry"))
    }

    // L10-17: tool and system error text is turned into one sentence.
    func testErrorTextBecomesOneSentence() {
        XCTAssertEqual(UIMessage.sentence("Command timed out after 15.0 seconds."), "Command timed out after 15.0 seconds.")
        XCTAssertEqual(UIMessage.sentence("No such file or directory"), "No such file or directory.")
        XCTAssertEqual(UIMessage.sentence("  stderr line\nCommand timed out.. "), "stderr line Command timed out.")
        XCTAssertEqual(UIMessage.sentence("Is it running?"), "Is it running?")
        XCTAssertEqual(UIMessage.sentence(" \n "), "An unknown error occurred.")
    }

    // L10-17: the footer and stale banner end the error with one full stop.
    func testLoadFailureMessagesArePunctuatedOnce() async throws {
        let inventory = UIScriptedInventory(results: [
            .success([Batch10.process(51)]),
            .failure(.commandFailed("Resource temporarily unavailable")),
            .failure(.commandFailed("ps exited with status 1."))
        ])
        let fixture = await Batch10.fixture(processes: [], inventory: inventory)
        defer { fixture.stores.cleanup() }
        await fixture.manager.loadProcessList()
        XCTAssertEqual(fixture.manager.message, "Could not load processes: Resource temporarily unavailable.")
        await fixture.manager.loadProcessList()
        XCTAssertEqual(fixture.manager.message, "Could not load processes: ps exited with status 1.")
        let banner = try Batch10.popover(fixture).inspect().find(ViewType.Text.self) {
            try $0.string().contains("Refresh failed:")
        }
        XCTAssertTrue(try banner.string().contains("Refresh failed: ps exited with status 1. Actions will be revalidated"))
    }

    // L10-5: counts agree with their nouns.
    func testCountsUseTheSingularForOne() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51, name: "Solo"), Batch10.process(52, name: "Other")])
        defer { fixture.stores.cleanup() }
        fixture.manager.select([Batch10.process(51, name: "Solo")])
        let view = Batch10.popover(fixture)
        let menu = try view.inspect().find(ViewType.Menu.self) {
            try $0.accessibilityLabel().string().hasPrefix("Actions for")
        }
        XCTAssertEqual(try menu.accessibilityLabel().string(), "Actions for 1 selected process")
        fixture.stores.settings.searchText = "Solo"
        XCTAssertNoThrow(try Batch10.popover(fixture).inspect().find(text: "1 match"))

        let one = SparklineView(samples: [.init(timestamp: Date(), observedProcessCPU: 1, observedProcessMemoryMB: 2, processCount: 3)],
                                keyPath: \.observedProcessCPU, color: .orange, label: "PROC CPU %", unit: "percent")
        XCTAssertTrue(try one.inspect().vStack().accessibilityValue().string().hasSuffix(", 1 sample"))
    }

    // L09-11: the footer total says it covers the shown rows, and only on the
    // Processes tab.
    func testFooterTotalIsLabelledAndOnlyOnTheProcessesTab() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51, cpu: 2.5, memoryMB: 100)])
        defer { fixture.stores.cleanup() }
        let footer = try Batch10.popover(fixture).inspect().find(TaskScopeFooterView.self).actualView()
        XCTAssertEqual(footer.summary, "Σ shown 2.5% CPU · 100 MB MEM")
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        let presetsFooter = try Batch10.popover(fixture).inspect().find(TaskScopeFooterView.self).actualView()
        XCTAssertNil(presetsFooter.summary)
    }

    // L10-16 / L09-21: titles use the rows' spacing, say what the pairs are,
    // and the sortable ones sort and show the active sort.
    func testColumnHeadersAlignSortAndExplainTheirPairs() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)
        let inspected = try view.inspect()
        let header = try inspected.find(ViewType.HStack.self) { stack in
            (try? stack.find(text: "PPID")) != nil
        }
        XCTAssertEqual(try header.spacing(), 10)
        XCTAssertEqual(try inspected.find(text: "NET KB TOTAL").help().string(), "Kilobytes received / sent since the process started")
        XCTAssertEqual(try inspected.find(text: "DISK MB TOTAL").help().string(), "Megabytes read / written since the process started")

        let cpuHeader = try inspected.find(button: "CPU")
        XCTAssertEqual(try cpuHeader.accessibilityValue().string(), "sorted descending")
        try inspected.find(button: "MEM MB").tap()
        XCTAssertEqual(fixture.stores.settings.sortKey, .memory)
        XCTAssertEqual(fixture.manager.sortKey, .memory)
        try Batch10.popover(fixture).inspect().find(button: "PID").tap()
        XCTAssertEqual(fixture.manager.sortKey, .pid)
        XCTAssertEqual(try Batch10.popover(fixture).inspect().find(button: "PID").accessibilityValue().string(), "sorted ascending")
    }

    // A05-6: a failed history read is visible on the charts, not only on hover.
    func testUnavailableHistoryIsShownAndAnnounced() {
        let state = ProcessHistory.SamplingState.unavailable("ps failed")
        let sample = ProcessHistory.Sample(timestamp: Date(), observedProcessCPU: 1, observedProcessMemoryMB: 2, processCount: 3)
        let chart = SparklineView(samples: [sample], keyPath: \.observedProcessCPU, color: .orange, label: "PROC CPU %", unit: "percent", samplingState: state)
        XCTAssertEqual(try chart.inspect().vStack().accessibilityValue().string(), "Latest 1.0 percent, 1 sample, Unavailable")
        let live = SparklineView(samples: [sample], keyPath: \.observedProcessCPU, color: .orange, label: "PROC CPU %", unit: "percent")
        XCTAssertEqual(try live.inspect().vStack().accessibilityValue().string(), "Latest 1.0 percent, 1 sample")
        XCTAssertEqual(state.detail, "History unavailable: ps failed")
    }

    // L09-10: only the built-in VPN preset shows the network shield (also
    // pinned in Batch10FixTests); L10-3: while an action runs the card's
    // actions are unavailable and say why.
    func testBusyCardDisablesItsActionsButKeepsInformationAvailable() throws {
        let card = PresetCard(
            snapshot: .init(preset: .globalProtect, runningNames: []),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
            onStopWithoutDisconnect: {}, isMutationActive: true
        )
        let inspected = try card.inspect()
        for title in ["Open", "Quit App…", "Quit Helpers…", "Quit All…", "Apply Keep Off…", "Stop Services Anyway…"] {
            XCTAssertTrue(try inspected.find(button: title).isDisabled(), title)
        }
        XCTAssertTrue(try inspected.find(ViewType.Toggle.self).isDisabled())
        XCTAssertNoThrow(try inspected.find(text: "Waiting for the current action to finish…"))

        let idle = PresetCard(
            snapshot: .init(preset: .globalProtect, runningNames: []),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
            onStopWithoutDisconnect: {}, isMutationActive: false
        )
        for title in ["Open", "Quit App…", "Quit All…", "Apply Keep Off…", "Stop Services Anyway…"] {
            XCTAssertFalse(try idle.inspect().find(button: title).isDisabled(), title)
        }
        XCTAssertThrowsError(try idle.inspect().find(text: "Waiting for the current action to finish…"))
    }

    // L09-13: preset confirmations ask a question that names the preset and keep
    // the verb on the button.
    func testPresetConfirmationsNameThePreset() {
        let preset = WatchedAppPreset(displayName: "Work Browser", mainProcessName: "Browser", helperProcessNames: ["Renderer"], protectedProcessNames: [], appPath: "/Applications/Browser.app")
        let expected: [(ProcessConfirmationState.PresetAction, String, String)] = [
            (.quitApp, "Quit Work Browser?", "Quit App"),
            (.quitHelpers, "Quit Work Browser Helpers?", "Quit Helpers"),
            (.quitAll, "Quit All Work Browser Processes?", "Quit All Killable")
        ]
        for (action, title, button) in expected {
            let pending = ProcessConfirmationState.PendingPresetAction(preset: preset, action: action)
            XCTAssertEqual(pending.title, title)
            XCTAssertEqual(pending.confirmTitle, button)
        }
        let keepOff = ProcessConfirmationState.PendingPresetAction(preset: .globalProtect, action: .keepOff)
        XCTAssertEqual(keepOff.title, "Keep GlobalProtect Off?")
        XCTAssertEqual(ProcessConfirmationState.PendingPresetAction(preset: .globalProtect, action: .quitAll).confirmTitle, "Quit All")
    }

    // L11-10: the stop dialog no longer promises a clean-up that ordinary apps
    // do not get.
    func testStopConfirmationDescribesWhatSIGTERMDoes() {
        let pending = ProcessConfirmationState.PendingTermination(process: Batch10.process(51), mode: .normal)
        XCTAssertEqual(pending.message, "Send SIGTERM to PID 51. Apps may close without asking to save changes.")
        XCTAssertFalse(pending.message.contains("allowing the process to clean up"))
    }

    // A05-2: the batch review and the batch result name a process whose title
    // was rewritten the same way the list row does.
    func testBatchNamesFollowTheRowNamingRule() async throws {
        var ssh = Batch10.process(61)
        ssh.command = "ssh: /Users/someone/.ssh/cm-root@192.0.2.1:22 [mux]"
        ssh.executablePath = "/usr/bin/ssh"
        let identity = ProcessIdentity(pid: 61, startTime: "one", command: ssh.command, executablePath: "/usr/bin/ssh")
        XCTAssertEqual(AppProcess.name(from: ssh.command), "ssh")
        let pending = ProcessConfirmationState.PendingBatchTermination(targets: [identity], mode: .normal)
        XCTAssertEqual(pending.rows.map(\.name), ["ssh"])
        XCTAssertFalse(pending.message.contains("[mux]"))

        // The process has gone before the batch runs, so the result names it
        // from the captured identity.
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        await fixture.manager.batchTerminate([identity])
        XCTAssertEqual(fixture.manager.batchActionReport?.targets.map(\.name), ["ssh"])
        XCTAssertTrue(fixture.signaler.sent.isEmpty)
    }

    // L09-19: an unregistered or stale login item is described as such, and the
    // recovery button says what it does.
    func testNotFoundLoginItemIsNotCalledUnavailable() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let manager = LoginItemManager(service: UILoginItemService(state: .notFound))
        let view = PresetsSectionView(processManager: fixture.manager, loginItemManager: manager, settings: fixture.stores.settings, watchedApps: fixture.stores.watchedApps, confirmationState: ProcessConfirmationState())
        XCTAssertNoThrow(try view.inspect().find(text: "macOS has no login item for this copy of TaskScope. Turn the switch on to register it."))
        XCTAssertNoThrow(try view.inspect().find(button: "Remove Stale Login Item"))
        XCTAssertThrowsError(try view.inspect().find(text: "Launch at Login is unavailable for this app bundle."))
    }
}
