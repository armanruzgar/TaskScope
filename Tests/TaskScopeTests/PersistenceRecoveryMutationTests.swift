import XCTest
@testable import TaskScope

@MainActor
final class PersistenceRecoveryMutationTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.PersistenceRecoveryMutationTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRejectedStoredRulesAreBackedUpFilteredAndLockedUntilReset() throws {
        let rulesKey = "rules"
        let safe = AutoStopRule(
            processName: " Safe ",
            runtimeMinutes: 5,
            action: .prompt
        )
        let invalid = AutoStopRule(
            processName: "Unsafe",
            executablePath: "/Applications/Unsafe.app/Contents/MacOS/Unsafe",
            runtimeMinutes: 0,
            action: .kill
        )
        let duplicate = AutoStopRule(
            processName: "safe",
            runtimeMinutes: 10,
            action: .silent
        )
        let original = try JSONEncoder().encode([safe, invalid, duplicate])
        defaults.set(original, forKey: rulesKey)

        let store = makeRulesStore(rulesKey: rulesKey)

        XCTAssertEqual(store.rules.map(\.processName), ["Safe"])
        XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
        XCTAssertEqual(
            defaults.data(forKey: "\(rulesKey).rejectedMigrationBackup"),
            original
        )

        var callbackNames: [String] = []
        store.evaluate(runningProcesses: [process(name: "Unsafe"), process(name: "Safe")]) { rule, _ in
            callbackNames.append(rule.processName)
        }
        XCTAssertEqual(callbackNames, ["Safe"], "only the valid rule may act; the zero-minute path-bound kill rule must be rejected")

        let recovered = try XCTUnwrap(store.rules.first)
        var updated = recovered
        updated.runtimeMinutes = 20
        XCTAssertFalse(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt)))
        XCTAssertFalse(store.update(updated))
        XCTAssertFalse(store.setEnabled(false, for: recovered))
        XCTAssertFalse(store.duplicate(recovered))
        XCTAssertFalse(store.remove(recovered))
        XCTAssertFalse(store.remove(at: IndexSet(integer: 0)))
        XCTAssertEqual(store.rules, [recovered])
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(defaults.data(forKey: rulesKey), original)

        store.resetRulesAfterCorruption()

        XCTAssertFalse(store.isRulesReadOnlyAfterRecovery)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt)))
        let persisted = try JSONDecoder().decode(
            [AutoStopRule].self,
            from: XCTUnwrap(defaults.data(forKey: rulesKey))
        )
        XCTAssertEqual(persisted.map(\.processName), ["Safe", "Other"])
    }

    func testOverflowingStoredRuntimeIsRejectedBeforeEvaluation() throws {
        let rulesKey = "rules"
        let unsafe = AutoStopRule(
            processName: "Unsafe",
            executablePath: "/Applications/Unsafe.app/Contents/MacOS/Unsafe",
            runtimeMinutes: .max,
            action: .kill
        )
        let original = try JSONEncoder().encode([unsafe])
        defaults.set(original, forKey: rulesKey)

        let store = makeRulesStore(rulesKey: rulesKey)

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
        XCTAssertEqual(defaults.data(forKey: "\(rulesKey).rejectedMigrationBackup"), original)
        // Once recovery is accepted, the same target must be actionable under
        // a valid path-bound rule. A missing path must not mask bad runtimes.
        store.resetRulesAfterCorruption()
        var valid = unsafe
        valid.runtimeMinutes = 1
        XCTAssertTrue(store.add(valid))
        var actedRules: [AutoStopRule] = []
        store.evaluate(runningProcesses: [process(name: "Unsafe")]) { rule, _ in
            actedRules.append(rule)
        }
        XCTAssertEqual(actedRules, [valid])
    }

    func testRuleAndEventRecoveryGatesAreIndependentAndResetCommitsSessionHistory() async throws {
        let rulesKey = "rules"
        let eventsKey = "events"
        let example = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent)
        defaults.set(try JSONEncoder().encode([example]), forKey: rulesKey)
        let corruptEvents = Data([0xFE, 0x02])
        defaults.set(corruptEvents, forKey: eventsKey)
        let inventory = PersistenceRecoveryInventory(processes: [process(name: "Example")])

        let store = makeRulesStore(
            rulesKey: rulesKey,
            eventsKey: eventsKey,
            inventory: inventory
        )

        XCTAssertFalse(store.isRulesReadOnlyAfterRecovery)
        XCTAssertTrue(store.isEventsReadOnlyAfterRecovery)
        XCTAssertTrue(store.add(AutoStopRule(processName: "Other", runtimeMinutes: 2, action: .prompt)))
        XCTAssertFalse(store.clearEvents())
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(defaults.data(forKey: eventsKey), corruptEvents)

        await store.evaluateNow()
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(defaults.data(forKey: eventsKey), corruptEvents)

        store.resetEventsAfterCorruption()
        await store.evaluateNow()

        XCTAssertFalse(store.isEventsReadOnlyAfterRecovery)
        XCTAssertEqual(store.events.map(\.outcome), [.logged])
        XCTAssertEqual(
            try JSONDecoder().decode(
                [AutoStopEvent].self,
                from: XCTUnwrap(defaults.data(forKey: eventsKey))
            ).map(\.outcome),
            [.logged]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [AutoStopRule].self,
                from: XCTUnwrap(defaults.data(forKey: rulesKey))
            ).map(\.processName),
            ["Example", "Other"]
        )
    }

    func testLoadedEventsAreImmediatelyBoundedAndPersisted() throws {
        let eventsKey = "events"
        let events = (0..<4).map { index in
            AutoStopEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(100 - index)),
                processName: "Process \(index)",
                pid: Int32(index),
                ruleID: UUID(),
                outcome: .logged,
                detail: "Event \(index)"
            )
        }
        defaults.set(try JSONEncoder().encode(events), forKey: eventsKey)

        let store = makeRulesStore(eventsKey: eventsKey, eventLimit: 2)

        XCTAssertEqual(store.events, Array(events.prefix(2)))
        let persisted = try JSONDecoder().decode(
            [AutoStopEvent].self,
            from: XCTUnwrap(defaults.data(forKey: eventsKey))
        )
        XCTAssertEqual(persisted, Array(events.prefix(2)))
    }

    func testEverySavedSelectionMutationRefusesRecoveryMode() {
        let key = "selections"
        let corrupt = Data([0xFF, 0x01])
        defaults.set(corrupt, forKey: key)
        let store = SavedSelectionsStore(userDefaults: defaults, key: key)
        let selection = SavedSelectionsStore.SavedSelection(
            name: "Fabricated",
            pids: [],
            processes: []
        )

        XCTAssertFalse(store.save(name: "New", processes: [process(name: "Example")]))
        XCTAssertFalse(store.rename(selection, to: "Renamed"))
        XCTAssertFalse(store.remove(selection))
        XCTAssertFalse(store.remove(.init(name: "Missing", pids: [], processes: [])))
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    private func makeRulesStore(
        rulesKey: String = "rules",
        eventsKey: String = "events",
        inventory: any ProcessInventoryProviding = PersistenceRecoveryInventory(processes: []),
        eventLimit: Int = 200
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults,
            key: rulesKey,
            eventsKey: eventsKey,
            inventory: inventory,
            eventLimit: eventLimit,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func process(name: String) -> AppProcess {
        AppProcess(
            pid: 42,
            parentPID: 1,
            uid: getuid(),
            cpu: 0,
            memoryMB: 0,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "10:00",
            startTime: "start-42",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}

private struct PersistenceRecoveryInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}
