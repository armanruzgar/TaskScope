import XCTest
@testable import TaskScope

/// Recovery gates preserve unreadable primary payloads until explicit reset.
@MainActor
final class StorePersistenceGateTests: XCTestCase {
    private let suiteName = "TaskScope.StorePersistenceGateTests.\(UUID().uuidString)"
    private let rulesKey = "auto-stop-rules-p11-tests"
    private let eventsKey = "auto-stop-events-p11-tests"
    private let selectionsKey = "saved-selections-p11-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Recovery

    /// The write gate is only safe if the user can lift it. Without an explicit
    /// reset they would be locked out of editing rules for good.
    func testExplicitResetRestoresRuleWritingAfterCorruption() throws {
        defaults.set(Data([0xFE, 0x03]), forKey: rulesKey)
        let store = makeRulesStore(inventory: ScriptedInventory(processes: []))
        XCTAssertTrue(store.hasUnreadableData, "precondition: writing is disabled")
        XCTAssertTrue(store.rules.isEmpty)

        store.resetAfterCorruption()
        XCTAssertFalse(store.hasUnreadableData)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent))

        let reloaded = makeRulesStore(inventory: ScriptedInventory(processes: []))
        XCTAssertEqual(reloaded.rules.map(\.processName), ["Example"])
    }

    func testExplicitResetRestoresSelectionSavingAfterCorruption() {
        defaults.set(Data([0xFE, 0x04]), forKey: selectionsKey)
        let store = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertTrue(store.isReadOnlyAfterCorruption, "precondition: saving is disabled")

        store.resetAfterCorruption()
        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.save(name: "Editors", processes: [appProcess(pid: 10, elapsed: "00:10")]))

        let reloaded = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertEqual(reloaded.selections.map(\.name), ["Editors"])
    }

    // MARK: - AutoStopRulesStore

    /// Zero user interaction: a rule the user created in a previous session, an unreadable
    /// event log, and one engine tick (`evaluateNow()` is exactly what the launch-time loop in
    /// TaskScopeApp calls every 10s).
    func testUnreadableEventLogSurvivesAnAutomaticEngineTick() async throws {
        let corruptEvents = Data([0xFE, 0x02])
        defaults.set(
            try JSONEncoder().encode([AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent)]),
            forKey: rulesKey
        )
        defaults.set(corruptEvents, forKey: eventsKey)

        let store = makeRulesStore(inventory: ScriptedInventory(processes: [appProcess(pid: 42, elapsed: "10:00")]))
        XCTAssertTrue(store.events.isEmpty, "precondition: events failed to decode")
        XCTAssertEqual(defaults.data(forKey: "\(eventsKey).corruptBackup"), corruptEvents, "precondition: backup taken")

        await store.evaluateNow()
        XCTAssertTrue(
            store.events.isEmpty,
            "Log Only must stay retryable until its event can be durably recorded"
        )

        XCTAssertEqual(
            defaults.data(forKey: eventsKey),
            corruptEvents,
            "Automatic evaluation must preserve the unreadable primary event payload until reset."
        )
    }

    /// User edits must obey the same recovery gate as automatic event writes.
    func testUnreadableRulePayloadSurvivesAddingANewRule() {
        let corruptRules = Data([0xFF, 0x01])
        defaults.set(corruptRules, forKey: rulesKey)
        let store = makeRulesStore()
        XCTAssertTrue(store.rules.isEmpty, "precondition: rules failed to decode")

        _ = store.add(AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt))

        XCTAssertEqual(
            defaults.data(forKey: rulesKey),
            corruptRules,
            "Rule mutations must preserve the unreadable primary payload until reset."
        )
    }

    /// A second corruption must not overwrite the first recovery backup.
    func testFirstCorruptBackupIsNotClobberedByASecondCorruptRead() {
        let firstCorrupt = Data([0xAA, 0x01])
        let secondCorrupt = Data([0xBB, 0x02])

        defaults.set(firstCorrupt, forKey: eventsKey)
        _ = makeRulesStore()
        XCTAssertEqual(defaults.data(forKey: "\(eventsKey).corruptBackup"), firstCorrupt)

        defaults.set(secondCorrupt, forKey: eventsKey)
        _ = makeRulesStore()

        XCTAssertEqual(
            hex(defaults.data(forKey: "\(eventsKey).corruptBackup")),
            hex(firstCorrupt),
            "Later corruption must preserve the older backup in its original slot."
        )
    }

    // MARK: - SavedSelectionsStore

    func testUnreadableSelectionPayloadSurvivesSavingANewSelection() {
        let corrupt = Data([0xFF, 0x01])
        defaults.set(corrupt, forKey: selectionsKey)
        let store = SavedSelectionsStore(userDefaults: defaults, key: selectionsKey)
        XCTAssertTrue(store.selections.isEmpty, "precondition: selections failed to decode")
        XCTAssertNotNil(store.recoveryMessage, "precondition: recovery message surfaced")

        // The save must be refused rather than accepted-and-dropped, so the caller
        // can tell the user instead of reporting a save that cannot reach disk.
        let saved = store.save(name: "Editors", processes: [appProcess(pid: 10, elapsed: "00:10")])
        XCTAssertFalse(saved, "save must report failure while the payload is unreadable")
        XCTAssertNotNil(store.validationError)

        XCTAssertEqual(
            defaults.data(forKey: selectionsKey),
            corrupt,
            "Selection mutations must preserve the unreadable primary payload until reset."
        )
    }

    // MARK: - Legacy event decoding

    /// Missing defaulted fields in legacy rules and events must remain readable,
    /// with the documented defaults: a rule stored without `isEnabled` keeps
    /// enforcing, and an event stored without an outcome is never shown as
    /// Logged.
    func testPersistedEventDecoderHonoursPropertyDefaultsLikeEveryOtherPersistedType() throws {
        let ruleMissingDefaultedFields = Data(#"[{"processName":"Example","runtimeMinutes":5,"action":"silent"}]"#.utf8)
        let eventsMissingDefaultedFields = Data(
            #"[{"timestamp":0,"processName":"Example","pid":42,"ruleID":"00000000-0000-0000-0000-000000000001","outcome":"logged","detail":"x"},{"timestamp":0,"processName":"Example","pid":43,"ruleID":"00000000-0000-0000-0000-000000000001","detail":"y"}]"#.utf8
        )

        // The hand-written decoders supply `id`, `isEnabled` and the outcome.
        let rules = try JSONDecoder().decode([AutoStopRule].self, from: ruleMissingDefaultedFields)
        XCTAssertEqual(rules.count, 1)
        XCTAssertTrue(rules[0].isEnabled, "A rule stored without isEnabled must keep enforcing.")
        XCTAssertFalse(rules[0].hasUnknownFields)

        let events = try JSONDecoder().decode([AutoStopEvent].self, from: eventsMissingDefaultedFields)
        XCTAssertEqual(
            events.map(\.outcome),
            [.logged, .unknown("missing")],
            "An event without an outcome must not be reported as Logged."
        )
        XCTAssertNotEqual(events[0].id, events[1].id)
        let roundTripped = try JSONDecoder().decode([AutoStopEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(roundTripped.map(\.outcome), [.logged, .unknown("missing")])
        XCTAssertEqual(roundTripped.map(\.id), events.map(\.id))

        // The store loads the same payloads with the same defaults.
        defaults.set(ruleMissingDefaultedFields, forKey: rulesKey)
        defaults.set(eventsMissingDefaultedFields, forKey: eventsKey)
        let store = makeRulesStore()
        XCTAssertFalse(store.hasUnreadableData)
        XCTAssertEqual(store.rules.map(\.isEnabled), [true])
        XCTAssertEqual(store.events.map(\.outcome), [.logged, .unknown("missing")])
    }

    // MARK: - Helpers

    private func makeRulesStore(
        inventory: any ProcessInventoryProviding = ScriptedInventory(processes: [])
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: rulesKey,
            eventsKey: eventsKey,
            inventory: inventory,
            eventLimit: 200,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func hex(_ data: Data?) -> String {
        data.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "<nil>"
    }

    private func appProcess(
        pid: Int32,
        command: String = "/Applications/Example.app/Example",
        elapsed: String
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 0,
            uid: getuid(),
            cpu: 0,
            memoryMB: 0,
            command: command,
            executablePath: command,
            elapsedTime: elapsed,
            startTime: "start-\(pid)",
            netInKB: 0,
            netOutKB: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
    }
}
