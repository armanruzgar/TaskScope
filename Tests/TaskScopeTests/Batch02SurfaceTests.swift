import AppKit
import OSLog
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the URL scheme, accessibility labels, the
// Keep Off card in settings recovery, scene titles, persisted list options,
// the registry of running shell commands, and the action log.

// MARK: - URL scheme (A01-15, T05-3)

@MainActor
final class Batch02URLSchemeTests: XCTestCase {
    private var submitted: [TaskScopeCommand] = []
    private var prepared: [TaskScopeCommand] = []

    private func makeHandler() -> URLSchemeHandler {
        URLSchemeHandler(
            submitCommand: { [unowned self] command in
                submitted.append(command)
                return TaskScopeCommandResult(status: .completed, message: "done")
            },
            willHandleCommand: { [unowned self] in prepared.append($0) }
        )
    }

    /// A01-15: only the literal string the docs and the error text promise is
    /// accepted. Case, percent-encoded, empty-port and IDNA-mapped spellings
    /// (which `URL(string:)` would normalize to the host "refresh") are refused.
    func testOnlyTheExactRefreshURLReachesTheCommandBus() async throws {
        let handler = makeHandler()
        let variants = [
            "TASKSCOPE://refresh",
            "TaskScope://refresh",
            "taskscope://%72efresh",
            "taskscope://%72%65%66%72%65%73%68",
            "taskscope://refresh:",
            "taskscope://\u{FF52}efresh",
            "taskscope://\u{FF32}\u{FF25}\u{FF26}\u{FF32}\u{FF25}\u{FF33}\u{FF28}",
            "taskscope://re\u{00AD}fresh"
        ]
        for value in variants {
            try Self.deliverGetURLEvent(value, to: handler)
            // URL(string:) already maps the IDNA spellings to the canonical URL,
            // so for those only the raw string the Apple Event carries can tell.
            if value.unicodeScalars.allSatisfy(\.isASCII), let url = URL(string: value) {
                XCTAssertNotEqual(TaskScopeURLParser.command(from: url), .success(.refresh), Self.escaped(value))
            }
        }
        try Self.deliverGetURLEvent("taskscope://refresh", to: handler)
        for _ in 0..<200 where submitted.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(submitted, [.refresh], "Only the canonical URL submits refresh")
        XCTAssertEqual(prepared, [.refresh])
        XCTAssertEqual(
            TaskScopeURLParser.command(from: try XCTUnwrap(URL(string: "taskscope://refresh"))),
            .success(.refresh)
        )
    }

    /// T05-3: the handler, not only the parser, refuses destructive, foreign and
    /// malformed URLs without submitting a command or touching launch policy.
    func testHandlerRejectsDestructiveForeignAndMalformedURLsWithoutSideEffects() async throws {
        let handler = makeHandler()
        for value in [
            "taskscope://stop/GlobalProtect",
            "taskscope://open/GlobalProtect",
            "taskscope://quit",
            "taskscope://refresh/GlobalProtect",
            "http://refresh",
            "https://refresh",
            "x-taskscope://refresh"
        ] {
            let result = await handler.handle(try XCTUnwrap(URL(string: value)))
            XCTAssertNil(result, "handle(\(value)) must reject")
        }
        XCTAssertEqual(
            TaskScopeURLParser.command(from: try XCTUnwrap(URL(string: "http://refresh"))),
            .failure(.invalidScheme)
        )
        XCTAssertEqual(submitted, [], "A rejected URL must not submit a command")
        XCTAssertEqual(prepared, [], "A rejected URL must not reach the launch policy")

        try Self.deliverGetURLEvent("", to: handler)
        try Self.deliverGetURLEvent(nil, to: handler)
        try Self.deliverGetURLEvent("taskscope://stop/GlobalProtect", to: handler)
        try Self.deliverGetURLEvent("http://refresh", to: handler)
        try Self.deliverGetURLEvent("taskscope://refresh", to: handler)
        for _ in 0..<200 where submitted.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(submitted, [.refresh])
        XCTAssertEqual(prepared, [.refresh])
    }

    private static func escaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            scalar.isASCII ? String(scalar) : String(format: "\\u{%04X}", scalar.value)
        }.joined()
    }

    /// Calls the selector `register()` installs for kAEGetURL, with an event
    /// built the way Launch Services delivers a URL open. Nothing leaves this
    /// test process.
    private static func deliverGetURLEvent(_ value: String?, to handler: URLSchemeHandler) throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let value {
            event.setParam(NSAppleEventDescriptor(string: value), forKeyword: keyDirectObject)
        }
        let selector = NSSelectorFromString("handleURLEvent:replyEvent:")
        let method = try XCTUnwrap(class_getInstanceMethod(URLSchemeHandler.self, selector))
        typealias EventHandler = @convention(c) (
            AnyObject, Selector, NSAppleEventDescriptor, NSAppleEventDescriptor
        ) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: EventHandler.self)
        implementation(handler, selector, event, NSAppleEventDescriptor.null())
    }
}

// MARK: - Views and scenes (L09-15, A11-2, L07-11, L11-15)

@MainActor
final class Batch02ViewTests: XCTestCase {
    /// L09-15: VoiceOver names the status item TaskScope, and the decorative
    /// header symbol is hidden next to the "TaskScope" text.
    func testStatusItemIsNamedTaskScopeAndTheHeaderSymbolIsHidden() throws {
        let label = try TaskScopeStatusItemLabel().inspect().find(ViewType.Label.self)
        XCTAssertEqual(try label.accessibilityLabel().string(), "TaskScope")

        let header = TaskScopeHeaderView(
            status: .idle, samples: [], samplingState: .paused,
            showsMetrics: false, showsOpenWindowButton: false, openFullWindow: nil, refreshAction: {}
        )
        let symbol = try header.inspect().find(ViewType.Image.self) {
            (try? $0.actualImage().name()) == "waveform.path.ecg"
        }
        XCTAssertTrue(try symbol.accessibilityHidden())
        XCTAssertNoThrow(try header.inspect().find(text: "TaskScope"))
    }

    /// A11-2: with unreadable settings the saved Keep Off intent is unknown, so
    /// the card shows it as unknown rather than as an Off switch, and says that
    /// background enforcement is paused until settings are reset.
    func testUnreadableSettingsShowKeepOffAsUnknownAndSayEnforcementIsPaused() throws {
        let recovery = makeCard(enabled: false)
        XCTAssertThrowsError(try recovery.inspect().find(ViewType.Toggle.self), "No Off switch in recovery")
        XCTAssertNoThrow(try recovery.inspect().find(text: "Keep GlobalProtect Off: Unknown"))
        XCTAssertNoThrow(try recovery.inspect().find(
            text: "Keep Off is not enforced in the background until then. After the reset, Keep Off is off until you turn it on again."
        ))

        let normal = makeCard(enabled: true)
        XCTAssertNoThrow(try normal.inspect().find(ViewType.Toggle.self))
        XCTAssertThrowsError(try normal.inspect().find(text: "Keep GlobalProtect Off: Unknown"))
    }

    /// L07-11: window suppression matches exactly the scene titles, declared
    /// once; the stale "TaskScope Processes" title is gone.
    func testWindowSuppressionUsesExactlyTheSceneTitles() {
        XCTAssertEqual(AppDelegate.automaticWindowTitles, ["TaskScope", "About TaskScope", "Onboarding"])
        XCTAssertEqual(AppDelegate.automaticWindowTitles, Set(TaskScopeScene.allCases.map(\.title)))
        XCTAssertFalse(AppDelegate.automaticWindowTitles.contains("TaskScope Processes"))
        XCTAssertEqual(TaskScopeScene.main.id, "processes")
        XCTAssertEqual(TaskScopeScene.about.id, "about")
        XCTAssertEqual(TaskScopeScene.onboarding.id, "onboarding")
    }

    /// L11-15: the list's Filter and Tree View are saved like Sort, and older
    /// payloads without them still load.
    func testFilterAndTreeViewArePersisted() throws {
        let defaults = batch02Defaults()
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.filterMode, .all)
        XCTAssertFalse(store.treeMode)

        store.filterModeRaw = ProcessFilterMode.watched.rawValue
        store.treeMode = true

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.filterMode, .watched)
        XCTAssertTrue(reloaded.treeMode)

        let older = batch02Defaults()
        older.set(Data(#"{"schemaVersion":3,"sortKeyRaw":"memory"}"#.utf8), forKey: "TaskScope.settings.v1")
        let fromOlder = SettingsStore(userDefaults: older)
        XCTAssertFalse(fromOlder.isReadOnlyAfterCorruption)
        XCTAssertEqual(fromOlder.sortKey, .memory)
        XCTAssertEqual(fromOlder.filterMode, .all)
        XCTAssertFalse(fromOlder.treeMode)

        let unknown = batch02Defaults()
        unknown.set(Data(#"{"schemaVersion":3,"filterModeRaw":"future"}"#.utf8), forKey: "TaskScope.settings.v1")
        XCTAssertEqual(SettingsStore(userDefaults: unknown).filterMode, .all)
    }

    private func makeCard(enabled: Bool) -> PresetCard {
        PresetCard(
            snapshot: WatchedAppSnapshot(preset: .globalProtect, runningNames: []),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: false, isKeepOffControlEnabled: enabled, onKeepOffChanged: { _ in }
        )
    }
}

// MARK: - Action log (L11-22)

final class Batch02ActionLogTests: XCTestCase {
    func testOnlyCommandsThatChangeSystemStateAreLogged() {
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/bin/launchctl bootout 'gui/501/com.example'"),
                       "launchctl bootout")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/bin/launchctl disable 'system/com.example'"),
                       "launchctl disable")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/bin/launchctl bootstrap 'gui/501' '/x.plist'"),
                       "launchctl bootstrap")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/bin/launchctl kickstart 'gui/501/com.example'"),
                       "launchctl kickstart")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/usr/bin/osascript -e 'do shell script'"),
                       "Administrator request")
        XCTAssertEqual(TaskScopeActionLog.loggedCommandKind("/usr/bin/open '/Applications/Example.app'"),
                       "Open application")
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind("/bin/launchctl print 'system/com.example'"))
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind("/bin/launchctl print-disabled system"))
        XCTAssertNil(TaskScopeActionLog.loggedCommandKind("/bin/ps -axo pid"))
    }

    /// A stop signal and a launchd change leave a Unified Log record after the
    /// fact. The signalled process is this test's own child.
    func testSignalsAndLaunchdChangesAreRecordedInTheUnifiedLog() async throws {
        let since = Date().addingTimeInterval(-1)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer { if child.isRunning { child.terminate() } }

        XCTAssertEqual(DarwinProcessSignaler().deliver(SIGTERM, to: pid), .delivered)
        child.waitUntilExit()
        TaskScopeActionLog.commandFinished(
            "/bin/launchctl bootout 'gui/501/com.example.batch02'",
            result: ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 0)
        )
        TaskScopeActionLog.commandFinished(
            "/bin/launchctl print 'gui/501/com.example.batch02'",
            result: ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 0)
        )

        let subsystem = TaskScopeLogging.subsystem()
        var messages: [String] = []
        // Opening the process's log store takes seconds; one read normally
        // finds both entries.
        for _ in 0..<10 {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            messages = try store.getEntries(
                at: store.position(date: since),
                matching: NSPredicate(
                    format: "subsystem == %@ AND category == %@", subsystem, TaskScopeActionLog.category
                )
            )
            .compactMap { $0 as? OSLogEntryLog }
            .map(\.composedMessage)
            if messages.contains(where: { $0.contains("launchctl bootout") }),
               messages.contains(where: { $0.contains("PID \(pid)") }) {
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertTrue(messages.contains { $0.contains("Sent SIGTERM to PID \(pid)") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("launchctl bootout succeeded") }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains("launchctl print") }, "Reads are not logged: \(messages)")
    }
}
