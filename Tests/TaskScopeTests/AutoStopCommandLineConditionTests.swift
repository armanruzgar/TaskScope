import ViewInspector
import XCTest
@testable import TaskScope

/// L11-16: the "Command line contains" condition. Command lines are read only
/// for processes that already match a rule by name, path and owner, through
/// the identity-checked per-process read, and only whether they matched is
/// kept.
@MainActor
final class AutoStopCommandLineConditionTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopCommandLineConditionTests.\(UUID().uuidString)"
    private let secret = "--token=s3cr3t-value"

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testOnlyMatchingProcessesAreReadAndOnlyAContainingCommandLineMatches() async {
        let reader = FakeCommandLineReader([
            4101: .loaded("node /srv/app/server.js \(secret)"),
            4102: .loaded("node /srv/app/worker.js"),
            4103: .identityChanged,
            4104: .unavailable("The command line could not be parsed."),
            4105: .gone,
        ])
        let processes = (4101...4105).map { process(pid: Int32($0)) } + [process(pid: 4200, name: "python3")]
        let store = makeStore(processes: processes, reader: reader)
        XCTAssertTrue(store.add(rule(contains: "server.js")))

        await store.evaluateNow()

        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [4101])
        let reads = await reader.reads
        XCTAssertEqual(reads.sorted(), [4101, 4102, 4103, 4104, 4105], "a process of another name is never read")
    }

    func testTheTextIsPlainCaseSensitiveAndKeptAsTyped() async {
        for (text, matches) in [("server.js", true), ("Server.js", false), ("server.j?", false), ("serve..js", false), (" server.js", true), ("server.js ", false)] {
            defaults.removePersistentDomain(forName: suiteName)
            let store = makeStore(processes: [process(pid: 4101)],
                                  reader: FakeCommandLineReader([4101: .loaded("node server.js")]))
            XCTAssertTrue(store.add(rule(contains: text)), text)
            await store.evaluateNow()
            XCTAssertEqual(store.pendingPrompts.count, matches ? 1 : 0, "“\(text)”")
        }
    }

    /// Log Only records, prompts and history name the condition, never the
    /// command line, and nothing stored holds it.
    func testCommandLinesAreNeverStoredRecordedOrShown() async throws {
        let reader = FakeCommandLineReader([4101: .loaded("node server.js \(secret)")])
        let store = makeStore(processes: [process(pid: 4101)], reader: reader)
        var logOnly = rule(contains: "server.js")
        logOnly.action = .silent
        XCTAssertTrue(store.add(logOnly))
        await store.evaluateNow()

        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.detail, "Conditions met.")
        XCTAssertEqual(event.conditions, "After 1 min, command line contains the rule's text")
        for key in ["rules", "rules.events"] {
            let stored = String(decoding: try XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self)
            XCTAssertFalse(stored.contains(secret), key)
            XCTAssertFalse(stored.contains("node server.js"), key)
        }

        let prompt = AutoStopPrompt(
            id: AutoStopOccurrence(ruleID: logOnly.id, processIdentity: process(pid: 4101).identity),
            rule: rule(contains: "server.js"),
            process: process(pid: 4101)
        )
        XCTAssertEqual(
            AutoStopPromptAlert.message(for: prompt),
            "Example (PID 4101) has run for 10m, beyond the 1-minute rule, and its command line contains the rule's text. Stop it now? Dismiss stops reminders for this process until it restarts."
        )
    }

    func testWithoutACommandLineConditionNothingIsRead() async {
        let reader = FakeCommandLineReader([4101: .loaded("node server.js")])
        let store = makeStore(processes: [process(pid: 4101)], reader: reader)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        var disabled = rule(contains: "server.js", name: "Other")
        disabled.isEnabled = false
        XCTAssertTrue(store.add(disabled))

        await store.evaluateNow()

        XCTAssertEqual(store.pendingPrompts.count, 1)
        let reads = await reader.reads
        XCTAssertTrue(reads.isEmpty)
    }

    /// The text is part of each pass's result, so a rule whose text changed
    /// while the command lines were read matches nothing until it is read again.
    func testARuleEditedWhileCommandLinesAreReadWaitsForTheNextRead() async {
        let reader = FakeCommandLineReader([4101: .loaded("node server.js")])
        let store = makeStore(processes: [process(pid: 4101)], reader: reader)
        let target = rule(contains: "server.js")
        XCTAssertTrue(store.add(target))
        var edited = target
        edited.commandLineContains = "node"
        let replacement = edited
        await reader.onNextRead {
            XCTAssertTrue(store.update(replacement))
        }

        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty, "the result read for the old text is not used for the new one")

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1)
    }

    /// The condition narrows Auto Stop; it does not replace the trusted path.
    func testAutoStopWithACommandLineConditionStillNeedsAPath() async {
        let reader = FakeCommandLineReader([4101: .loaded("node server.js")])
        let store = makeStore(processes: [process(pid: 4101)], reader: reader)
        var automatic = rule(contains: "server.js")
        automatic.action = .kill
        XCTAssertFalse(store.add(automatic))
        automatic.executablePath = "/cmdline/Example"
        XCTAssertTrue(store.add(automatic))
        var stopped: [Int32] = []
        store.start { _, target in stopped.append(target.pid); return .stopped }
        store.stop()
        await store.evaluateNow()
        XCTAssertEqual(stopped, [4101])
    }

    // MARK: - Stored form, validation and editors

    func testTheTextIsStoredOnlyWhenSetAndReleaseOneOneZeroKeepsTheRuleLocked() throws {
        let classic = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)
        let narrowed = rule(contains: "server.js")
        let classicKeys = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(classic)) as? [String: Any]).keys
        XCTAssertFalse(classicKeys.contains("commandLineContains"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(narrowed)) as? [String: Any])
        XCTAssertEqual(object["commandLineContains"] as? String, "server.js")
        XCTAssertEqual(try JSONDecoder().decode(AutoStopRule.self, from: JSONEncoder().encode(narrowed)), narrowed)

        // 1.1.0 knows exactly these six fields; any other keeps a rule disabled and read-only there.
        let release110Fields: Set<String> = ["id", "processName", "executablePath", "runtimeMinutes", "action", "isEnabled"]
        XCTAssertFalse(Set(object.keys).isSubset(of: release110Fields))
        XCTAssertNotNil(object["runtimeMinutes"] as? Int, "the field 1.1.0 requires is written")
    }

    func testValidationOfTheText() {
        func message(_ text: String) -> String? {
            if case .failure(let failure) = AutoStopRuleValidation.validate(rule(contains: text)) { return failure.message }
            return nil
        }
        XCTAssertEqual(message(""), "Enter the text the command line must contain.")
        XCTAssertEqual(message("   "), "Enter the text the command line must contain.")
        XCTAssertEqual(message("a\nb"), "The command line text must be on one line.")
        XCTAssertEqual(message(String(repeating: "a", count: 1_001)), "The command line text can be at most 1,000 characters.")
        XCTAssertNil(message(String(repeating: "a", count: 1_000)))
        XCTAssertNil(message(" --serve "))

        var alone = rule(contains: "server.js")
        alone.checksRuntime = false
        if case .failure(let failure) = AutoStopRuleValidation.validate(alone) {
            XCTAssertEqual(failure.message, "Choose at least one condition: run time, CPU, or memory.",
                           "the command line narrows a rule; it is not a condition on its own")
        } else {
            XCTFail("a rule that tests only its command line must be refused")
        }
    }

    func testTheEditorsCarryTheTextExactlyAndRefuseAnEmptyOne() throws {
        var draft = AutoStopConditionsDraft(rule: rule(contains: " --serve"))
        XCTAssertTrue(draft.checksCommandLine)
        XCTAssertEqual(draft.commandLineText, " --serve")
        XCTAssertNil(draft.commandLineProblem)
        XCTAssertEqual(draft.applied(to: AutoStopRule(processName: "A", runtimeMinutes: 1, action: .prompt)).commandLineContains, " --serve")

        draft.commandLineText = " "
        XCTAssertEqual(draft.commandLineProblem, "Enter the text the command line must contain.")
        XCTAssertFalse(draft.canSave)
        draft.checksCommandLine = false
        XCTAssertTrue(draft.canSave)
        XCTAssertNil(draft.applied(to: rule(contains: "x")).commandLineContains)

        var add = AutoStopConditionsDraft()
        add.checksCommandLine = true
        add.commandLineText = "server.js"
        XCTAssertEqual(SettingsView.moreConditionsTitle(add), "More conditions: command line contains “server.js”")
        XCTAssertEqual(rule(contains: "server.js").conditionSummary(showingCommandLineText: true),
                       "After 1 min, command line contains “server.js”")

        let sheet = AutoStopRuleEditorSheet(rule: rule(contains: "server.js"), onSave: { _ in }, onCancel: {})
        XCTAssertNoThrow(try sheet.inspect().find(AutoStopCommandLineField.self))
    }

    // MARK: - Support

    private func makeStore(processes: [AppProcess], reader: FakeCommandLineReader) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults, key: "rules", eventsKey: "rules.events",
            inventory: CommandLineInventory(processes), commandLineReader: reader,
            now: { Date(timeIntervalSince1970: 1_000) }, currentUID: getuid(), currentPID: getpid()
        )
    }

    private func rule(contains text: String, name: String = "Example") -> AutoStopRule {
        AutoStopRule(processName: name, runtimeMinutes: 1, commandLineContains: text, action: .prompt)
    }

    private func process(pid: Int32, name: String = "Example") -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 64, command: name,
                   executablePath: "/cmdline/\(name)", elapsedTime: "10:00", startTime: "start-\(pid)",
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }
}

private struct CommandLineInventory: ProcessInventoryProviding {
    let processes: [AppProcess]

    init(_ processes: [AppProcess]) { self.processes = processes }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

/// Scripted command-line reads, by PID, that record which PIDs were read.
private actor FakeCommandLineReader: ProcessCommandLineReading {
    private let results: [Int32: CommandLineReadResult]
    private(set) var reads: [Int32] = []
    private var hook: (@Sendable @MainActor () -> Void)?

    init(_ results: [Int32: CommandLineReadResult]) { self.results = results }

    /// Runs `hook` on the main actor during the next read, before it returns.
    func onNextRead(_ hook: @escaping @Sendable @MainActor () -> Void) { self.hook = hook }

    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult {
        reads.append(identity.pid)
        if let hook {
            self.hook = nil
            await MainActor.run { hook() }
        }
        return results[identity.pid] ?? .gone
    }
}
