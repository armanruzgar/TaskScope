import AppKit
import Combine
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Leads from the November 2026 audit that verifiers noted but never checked:
/// the process list, preset stop messages and Auto Stop prompts.
@MainActor
final class AuditLeadListTests: XCTestCase {
    // L09-18: flat and tree rows share their PID ids. Turning Tree View on
    // after the flat list was drawn kept the flat rows on screen (no indent,
    // no disclosure button), so a parent could not be expanded. Checked in a
    // real window: SwiftUI draws each row's buttons as AppKit buttons.
    func testTurningTreeViewOnDrawsTreeRows() async throws {
        _ = NSApplication.shared
        let parent = Batch10.process(100, name: "Parent")
        let child = Batch10.process(150, parent: 100, name: "Child")
        let fixture = await Batch10.fixture(processes: [parent, child])
        defer { fixture.stores.cleanup() }
        let listState = ProcessListInteractionState()
        let window = host(Batch10.popover(fixture, listState: listState))
        defer { window.orderOut(nil); window.close() }

        let flat = await rowButtonOffsets(in: window) { $0.count == 4 }
        XCTAssertEqual(flat.count, 4, "two flat rows, each with a selection and a stop button")
        let flatSelectionOffset = try XCTUnwrap(flat.min())

        listState.treeMode = true
        let tree = await rowButtonOffsets(in: window) { $0.contains { $0 < flatSelectionOffset } }
        XCTAssertTrue(tree.contains { $0 < flatSelectionOffset }, "no disclosure button: \(tree)")
        XCTAssertFalse(tree.contains(flatSelectionOffset), "a row is still drawn as a flat row: \(tree)")
    }

    // L09-4: a row shows the executable path under its name, which can differ
    // from the `ps` command name; searching for the path shown found nothing.
    func testSearchMatchesTheExecutablePathShownUnderTheName() {
        let home = NSHomeDirectory()
        let tail = listProcess(pid: 42, command: "tail", path: "/usr/bin/tail")
        let session = listProcess(pid: 43, command: "sshd-session: me@ttys001", path: "/usr/libexec/sshd-session")
        let tool = listProcess(pid: 44, command: "tool", path: home + "/bin/tool")
        var query = ProcessListQuery(
            searchText: "/usr/bin", filterMode: .all, watchedScopes: [],
            cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1_024
        )
        XCTAssertTrue(query.matches(tail))
        XCTAssertFalse(query.matches(session))
        query.searchText = "libexec/sshd"
        XCTAssertTrue(query.matches(session))
        query.searchText = "~/bin/tool"
        XCTAssertTrue(query.matches(tool), "the path as shown, with ~")
        query.searchText = home + "/bin"
        XCTAssertTrue(query.matches(tool), "the full path")
        XCTAssertFalse(query.matches(tail))

        // A plain word is not a path: it does not match every process in a
        // folder of that name.
        let parent = listProcess(pid: 45, command: "Parent", path: "/Applications/Workers.app/Contents/MacOS/Parent")
        query.searchText = "Workers"
        XCTAssertFalse(query.matches(parent))
        query.searchText = "Workers.app/"
        XCTAssertTrue(query.matches(parent))
    }

    // L09-8: in the window, the PPID, NET and DISK cells are hidden from
    // VoiceOver, so the row's summary must read them out.
    func testExpandedRowSummaryReadsParentNetworkAndDisk() throws {
        var process = listProcess(pid: 4_816, command: "Example", path: "/Applications/Example.app/Contents/MacOS/Example")
        process.parentPID = 1_288
        process.ownerName = "alex"
        process.netInKB = 12.5
        process.netOutKB = 3.5
        process.diskReadBytes = 2 * 1_048_576
        process.diskWriteBytes = 524_288
        process.netInRateKBps = 12.5
        process.netOutRateKBps = 3.5
        process.diskReadRateBytesPerSecond = 2 * 1_048_576
        process.diskWriteRateBytesPerSecond = 524_288
        func summary(expanded: Bool) throws -> String {
            let row = ProcessRow(
                process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
                isHighlightedCPU: false, isHighlightedMEM: false, showsExpandedMetrics: expanded,
                stopAction: {}, toggleSelection: {}
            )
            return try row.inspect().find(ViewType.HStack.self).find(ViewType.VStack.self)
                .accessibilityValue().string()
        }
        XCTAssertEqual(
            try summary(expanded: true),
            "CPU 1.0 percent, memory 128 megabytes, parent PID 1288, user alex, "
                + "network received 12.5, sent 3.5 kilobytes per second, disk read 2.0, written 0.5 megabytes per second"
        )
        XCTAssertEqual(try summary(expanded: false), "CPU 1.0 percent, memory 128 megabytes",
                       "the popover has no such columns")
    }

    // L10-3: a custom preset's Quit App, Quit Helpers and Quit App and Helpers
    // set the footer message only when they finished, so the spinner showed an
    // earlier, unrelated result (for example "Idle.") for the whole stop.
    func testPresetStopShowsWhatItIsDoingWhileItRuns() async {
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Example Helper"],
            protectedProcessNames: [], appPath: "/Applications/Example.app"
        )
        let cases: [(PresetStopScope, String)] = [
            (.app, "Quitting Example…"),
            (.helpers, "Quitting the helpers of Example…"),
            (.all, "Quitting Example and its helpers…")
        ]
        for (scope, progress) in cases {
            let fixture = await Batch10.fixture(processes: [Batch10.process(500, name: "Example")])
            defer { fixture.stores.cleanup() }
            let manager = fixture.manager
            var messages: [String] = []
            let observation = manager.$message.dropFirst().sink { messages.append($0) }
            let result: TaskScopeCommandResult
            switch scope {
            case .app: result = await manager.quitMainApp(preset)
            case .helpers: result = await manager.quitHelpers(preset)
            case .all: result = await manager.quitAllKillable(preset)
            }
            observation.cancel()
            XCTAssertEqual(messages.first, progress, "\(scope): \(messages)")
            XCTAssertEqual(manager.message, result.message, "\(scope): the result replaces the progress text")
        }
    }

    // A05-4 and L11-6 named '1 processes'; the Save Selection sheet had the
    // same fixed plural.
    func testSaveSelectionSheetCountsOneProcessInTheSingular() throws {
        func text(_ count: Int) throws -> String {
            let sheet = SaveSelectionSheet(name: .constant(""), count: count, validationError: nil, onSave: {}, onCancel: {})
            return try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }.joined(separator: "\n")
        }
        XCTAssertTrue(try text(1).contains("Save 1 selected process as a named selection"))
        XCTAssertTrue(try text(3).contains("Save 3 selected processes as a named selection"))
    }

    // MARK: - Helpers

    private func listProcess(pid: Int32, command: String, path: String) -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 1, memoryMB: 128,
            command: command, executablePath: path, elapsedTime: "03:00", startTime: "one",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    /// An off-screen borderless window, so nothing appears on the display.
    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -12_000, y: -12_000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 900, height: 600))
        window.orderFrontRegardless()
        return window
    }

    /// The horizontal offsets of the buttons drawn in the process list's
    /// scroll view, read once `condition` holds or after five seconds.
    private func rowButtonOffsets(in window: NSWindow, until condition: ([CGFloat]) -> Bool) async -> [CGFloat] {
        var offsets: [CGFloat] = []
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            offsets = currentRowButtonOffsets(in: window)
            if condition(offsets) { break }
        }
        return offsets
    }

    private func currentRowButtonOffsets(in window: NSWindow) -> [CGFloat] {
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
        }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        guard let content = window.contentView,
              let document = scrollView(in: content)?.documentView else { return [] }
        return buttons(in: document).map { $0.convert($0.bounds, to: document).minX }
    }
}
