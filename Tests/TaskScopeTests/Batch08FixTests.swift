import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class Batch08FixTests: XCTestCase {
    nonisolated(unsafe) private var defaults: Batch08Defaults!
    nonisolated(unsafe) private var suite: String!
    private var instant = ContinuousClock.now
    private var date = Date(timeIntervalSince1970: 1_000)
    private let path = "/batch08/Example"

    override func setUp() {
        super.setUp()
        suite = "TaskScope.Batch08.\(UUID().uuidString)"
        defaults = Batch08Defaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        suite = nil
        super.tearDown()
    }

    func testBlankRuleNameIsRejectedInteractivelyAndAtLoad() throws {
        for blank in ["", " \n\t"] {
            let invalid = rule(name: blank)
            XCTAssertEqual(AutoStopRuleValidation.validate(invalid), .failure(.init(message: "Process name is required.")))
            XCTAssertFalse(makeStore().add(invalid))
            let original = try JSONEncoder().encode([invalid])
            defaults.set(original, forKey: "rules")
            let store = makeStore()
            XCTAssertTrue(store.rules.isEmpty)
            XCTAssertNotNil(store.rulesRecoveryMessage)
            XCTAssertEqual(defaults.data(forKey: "rules.rejectedMigrationBackup"), original)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testEngineMatchesNamesCaseInsensitively() async {
        let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
        XCTAssertTrue(store.add(rule(name: "example")))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [4101])
    }

    func testSavedSelectionRefusesBlankNamesAndDuplicateOrBlankRenames() {
        let store = SavedSelectionsStore(userDefaults: defaults, key: "selections")
        for blank in ["", " \n\t"] {
            XCTAssertFalse(store.save(name: blank, processes: [process()]))
            XCTAssertEqual(store.validationError, "Selection name is required.")
        }
        XCTAssertTrue(store.save(name: "Editors", processes: [process()]))
        XCTAssertTrue(store.save(name: "Tools", processes: [process()]))
        XCTAssertTrue(store.save(name: "Other", processes: [process()]))
        let before = store.selections
        for invalid in ["", "\n", "EDITORS"] {
            XCTAssertFalse(store.rename(before[1], to: invalid))
            XCTAssertNotNil(store.validationError)
            XCTAssertEqual(store.selections, before)
        }
        XCTAssertEqual(SavedSelectionsStore(userDefaults: defaults, key: "selections").selections, before)
    }

    func testDuplicateStoredRuleIDsRecoverWithoutOverwritingOriginal() throws {
        let first = rule(name: "alpha")
        var second = rule(name: "beta", action: .silent)
        second.id = first.id
        let original = try JSONEncoder().encode([first, second])
        defaults.set(original, forKey: "rules")
        let store = makeStore()
        XCTAssertEqual(store.rules, [first])
        XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
        XCTAssertTrue(store.rulesRecoveryMessage?.contains("Rejected 1") == true)
        XCTAssertEqual(defaults.data(forKey: "rules.rejectedMigrationBackup"), original)
        XCTAssertFalse(store.setEnabled(false, for: first))
        XCTAssertFalse(store.remove(first))
        XCTAssertEqual(defaults.data(forKey: "rules"), original)
        store.resetRulesAfterCorruption()
        XCTAssertEqual(makeStore().rules, [first])
    }

    func testNameUniquenessUsesTheEngineComparisonForAddEditAndLoad() throws {
        for pair in [("\u{10400}tool", "\u{10428}tool"), ("\u{1E900}x", "\u{1E922}x"), ("Straße", "STRASSE"), ("ος", "οσ")] {
            for editedFirst in [false, true] {
                defaults.removePersistentDomain(forName: suite)
                let store = makeStore()
                let first = rule(name: pair.0)
                let other = rule(name: "zz")
                XCTAssertTrue(store.add(editedFirst ? other : first))
                XCTAssertTrue(store.add(editedFirst ? first : other))
                let same = pair.0.caseInsensitiveCompare(pair.1) == .orderedSame
                let before = store.rules
                var edit = other
                edit.processName = pair.1
                XCTAssertEqual(store.update(edit), !same)
                XCTAssertEqual(store.rules.count, 2)
                XCTAssertTrue(store.rules.contains(first), "the untouched rule must survive")
                if same { XCTAssertEqual(store.rules, before); XCTAssertNotNil(store.validationError) }
                XCTAssertEqual(makeStore().rules, store.rules)
            }
            defaults.removePersistentDomain(forName: suite)
            let store = makeStore()
            XCTAssertTrue(store.add(rule(name: pair.0)))
            let second = rule(name: pair.1)
            let same = pair.0.caseInsensitiveCompare(pair.1) == .orderedSame
            XCTAssertEqual(store.add(second), !same)
            XCTAssertEqual(store.rules.count, same ? 1 : 2)
            XCTAssertEqual(makeStore().rules, store.rules)
            defaults.set(try JSONEncoder().encode([rule(name: pair.0), second]), forKey: "rules")
            XCTAssertEqual(makeStore().isRulesReadOnlyAfterRecovery, same)
        }
    }

    func testInteractiveNameAndDirectoryChecksDoNotRejectStoredRules() throws {
        let store = makeStore()
        XCTAssertFalse(store.add(rule(name: "/usr/local/bin/node")))
        XCTAssertTrue(store.validationError?.contains("process name") == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var invalid = rule()
        invalid.executablePath = directory.path
        XCTAssertFalse(store.add(invalid))
        XCTAssertTrue(store.validationError?.contains("directory") == true)
        XCTAssertTrue(store.add(rule()))
        var edited = store.rules[0]
        edited.executablePath = directory.path
        XCTAssertFalse(store.update(edited))
        XCTAssertTrue(store.validationError?.contains("directory") == true)
        edited.executablePath = nil
        edited.processName = "/usr/bin/Example"
        XCTAssertFalse(store.update(edited))
        XCTAssertEqual(store.rules.map(\.processName), ["Example"])

        // A rule stored before these checks loads normally and stays editable
        // as long as its name and path are kept, so it can still be switched off.
        invalid.processName = "/a/b"
        defaults.set(try JSONEncoder().encode([invalid]), forKey: "rules")
        let legacy = makeStore()
        XCTAssertEqual(legacy.rules, [invalid])
        XCTAssertFalse(legacy.isRulesReadOnlyAfterRecovery)
        XCTAssertTrue(legacy.setEnabled(false, for: invalid))
        XCTAssertFalse(legacy.rules[0].isEnabled)
        XCTAssertNotNil(AutoStopRuleValidation.pathWarning(invalid.executablePath), "the row explains why it never matches")
    }

    func testBundleDirectoryRejectionSuggestsItsExecutableAndMissingPathOnlyWarns() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
        let contents = bundle.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try Data().write(to: executable)
        let plist: [String: Any] = ["CFBundleExecutable": "Example", "CFBundleIdentifier": "test.batch08.\(UUID().uuidString)", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var candidate = rule(action: .kill)
        candidate.executablePath = bundle.path
        let store = makeStore()
        XCTAssertFalse(store.add(candidate))
        XCTAssertTrue(store.validationError?.contains(executable.path) == true)
        candidate.executablePath = bundle.appendingPathComponent("not-installed-yet").path
        XCTAssertTrue(store.add(candidate))
        XCTAssertNotNil(AutoStopRuleValidation.pathWarning(candidate.executablePath))
        XCTAssertNil(AutoStopRuleValidation.pathWarning(executable.path))
    }

    func testRuleEditorWarnsOnlyWhileTheExecutablePathDoesNotExist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("batch08-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let warning = "Executable path does not exist. This rule will match only after the executable is installed at that path."
        func sheet(path: String) -> AutoStopRuleEditorSheet {
            AutoStopRuleEditorSheet(
                rule: AutoStopRule(processName: "Example", executablePath: path, runtimeMinutes: 1, action: .prompt),
                onSave: { _ in },
                onCancel: {}
            )
        }
        XCTAssertNoThrow(try sheet(path: file.path + "-missing").inspect().find(text: warning))
        XCTAssertThrowsError(try sheet(path: file.path).inspect().find(text: warning))
    }

    func testDuplicateIsDisabledAndPreservesFieldsWithFreshIDsAndUniqueNames() {
        let store = makeStore()
        let original = rule(action: .kill)
        XCTAssertTrue(store.add(original))
        XCTAssertTrue(store.duplicate(original))
        XCTAssertTrue(store.duplicate(original))
        XCTAssertEqual(store.rules.map(\.processName), ["Example", "Example Copy", "Example Copy 2"])
        XCTAssertEqual(Set(store.rules.map(\.id)).count, 3)
        for copy in store.rules.dropFirst() {
            XCTAssertFalse(copy.isEnabled)
            XCTAssertEqual(copy.executablePath, original.executablePath)
            XCTAssertEqual(copy.runtimeMinutes, original.runtimeMinutes)
            XCTAssertEqual(copy.action, original.action)
        }
        XCTAssertEqual(makeStore().rules, store.rules)
    }

    func testClearEventsPersistsEmptyHistory() async throws {
        let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
        XCTAssertTrue(store.add(rule(action: .silent)))
        await store.evaluateNow()
        XCTAssertFalse(store.events.isEmpty)
        XCTAssertTrue(store.clearEvents())
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(try storedEvents(), [])
        XCTAssertTrue(makeStore().events.isEmpty)
    }

    func testDeletingRuleByEitherAPIRetiresQueuedPromptsAndDismissals() async throws {
        for offsets in [false, true] {
            for dismiss in [false, true] {
                defaults.removePersistentDomain(forName: suite)
                let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
                let target = rule()
                XCTAssertTrue(store.add(target))
                await store.evaluateNow()
                if dismiss { store.dismissPrompt(try XCTUnwrap(store.currentPrompt)) }
                XCTAssertTrue(offsets ? store.remove(at: IndexSet(integer: 0)) : store.remove(target))
                XCTAssertTrue(store.pendingPrompts.isEmpty)
                XCTAssertNil(store.currentPrompt)
                await store.evaluateNow()
                XCTAssertNil(store.currentPrompt)
                XCTAssertTrue(makeStore().rules.isEmpty)
                XCTAssertTrue(store.add(target))
                await store.evaluateNow()
                XCTAssertEqual(store.pendingPrompts.count, 1, "deletion must retire handled and dismissed marks")
            }
        }
    }

    func testConfirmedAcceptedStopSurvivesEditsToggleAndDeletionUntilExit() async throws {
        for mutation in ["save", "edit", "disable", "toggle", "delete", "offsets"] {
            defaults.removePersistentDomain(forName: suite)
            let inventory = Batch08Inventory(processes: [process()])
            let store = makeStore(inventory: inventory)
            let target = rule()
            XCTAssertTrue(store.add(target))
            var attempts = 0
            store.start { _, _ in attempts += 1; return .requestedStillRunning }
            store.stop()
            await store.evaluateNow()
            await store.finishStop(try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt))))
            switch mutation {
            case "edit":
                var edited = target
                edited.runtimeMinutes = 2
                XCTAssertTrue(store.update(edited))
            case "disable": XCTAssertTrue(store.setEnabled(false, for: target))
            case "toggle":
                XCTAssertTrue(store.setEnabled(false, for: target))
                XCTAssertTrue(store.setEnabled(true, for: store.rules[0]))
            case "delete": XCTAssertTrue(store.remove(target))
            case "offsets": XCTAssertTrue(store.remove(at: IndexSet(integer: 0)))
            default: XCTAssertTrue(store.update(target))
            }
            await store.evaluateNow()
            XCTAssertNil(store.currentPrompt, mutation)
            await inventory.set([])
            await store.evaluateNow()
            XCTAssertEqual(attempts, 1, mutation)
            XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested], mutation)
            XCTAssertEqual(store.events.first?.detail, "Exited after the stop request.")
        }
    }

    func testIgnoredConfirmedStopReportsOnceAfterCadenceWithoutSignallingAgain() async throws {
        let inventory = Batch08Inventory(processes: [process()])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(rule()))
        var attempts = 0
        store.start(cadence: 10) { _, _ in attempts += 1; return .requestedStillRunning }
        store.stop()
        await store.evaluateNow()
        await store.finishStop(try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt))))
        instant = instant.advanced(by: .seconds(9))
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])
        instant = instant.advanced(by: .seconds(1))
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.failed, .stopRequested])
        XCTAssertTrue(store.events[0].detail.contains("Force Stop"))
        await store.evaluateNow()
        XCTAssertEqual(store.events.count, 2)
        XCTAssertNil(store.currentPrompt)
        XCTAssertEqual(attempts, 1)
        await inventory.set([])
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .failed, .stopRequested])
    }

    func testLogOnlyLogsAnOccurrenceOnceWhenItsExecutableMovesAndAgainAfterPIDReuse() async {
        let inventory = Batch08Inventory(processes: [process()])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(rule(action: .silent)))
        await store.evaluateNow()
        await inventory.set([process(path: "/batch08/moved/Example")])
        await store.evaluateNow()
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.logged], "a moved executable is the same lifetime")
        await inventory.set([process(start: "replacement", path: "/batch08/moved/Example")])
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.outcome), [.logged, .logged], "a reused PID is a new lifetime")
    }

    func testPIDReuseMeansExitedButSameLifetimePathChangeMeansIdentityFailure() async throws {
        for mode in ["prompt", "confirmed", "automatic"] {
            for reused in [false, true] {
                defaults.removePersistentDomain(forName: suite)
                let inventory = Batch08Inventory(processes: [process()])
                let store = makeStore(inventory: inventory)
                XCTAssertTrue(store.add(rule(action: mode == "automatic" ? .kill : .prompt)))
                store.start { _, _ in .requestedStillRunning }
                store.stop()
                await store.evaluateNow()
                if mode == "confirmed" {
                    await store.finishStop(try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt))))
                }
                await inventory.set([process(start: reused ? "new" : "start", path: "/batch08/other/Example", elapsed: "00:01")])
                await store.evaluateNow()
                // A10-3 (lead): an unanswered name-only prompt follows its moved
                // executable, so nothing failed; a confirmed or automatic stop
                // whose executable moved is still an identity failure.
                let movedOutcome: AutoStopEvent.Outcome? = mode == "prompt" ? nil : .failed
                XCTAssertEqual(store.events.first?.outcome, reused ? (mode == "prompt" ? .processEnded : .stopped) : movedOutcome, "\(mode), reused=\(reused)")
                if mode == "prompt", !reused {
                    XCTAssertEqual(store.currentPrompt?.process.executablePath, "/batch08/other/Example")
                }
            }
        }
    }

    func testEventRecoveryGatePreservesPrimaryForEveryNonLogOutcomeUntilReset() async throws {
        for mixed in [false, true] {
            for scenario in ["autoStop", "dismiss", "endedPrompt", "confirmed", "pendingExit"] {
                defaults.removePersistentDomain(forName: suite)
                let seed = AutoStopEvent(timestamp: date, processName: "old", pid: 9, ruleID: UUID(), outcome: .logged, detail: "old")
                let original = mixed ? Data("[\(String(decoding: try JSONEncoder().encode(seed), as: UTF8.self)),null]".utf8) : Data([0xFF])
                defaults.set(original, forKey: "events")
                let inventory = Batch08Inventory(processes: [process()])
                let store = makeStore(inventory: inventory)
                XCTAssertTrue(store.add(rule(action: scenario == "autoStop" ? .kill : .prompt)))
                store.start { _, _ in scenario == "pendingExit" ? .requestedStillRunning : .stopped }
                store.stop()
                await store.evaluateNow()
                switch scenario {
                case "dismiss": store.dismissPrompt(try XCTUnwrap(store.currentPrompt))
                case "confirmed", "pendingExit": await store.finishStop(try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt))))
                default: break
                }
                if scenario == "endedPrompt" || scenario == "pendingExit" {
                    await inventory.set([])
                    await store.evaluateNow()
                }
                XCTAssertGreaterThan(store.events.count, mixed ? 1 : 0, scenario)
                XCTAssertEqual(defaults.data(forKey: "events"), original, scenario)
                XCTAssertTrue(store.isEventsReadOnlyAfterRecovery)
                let session = store.events
                store.resetEventsAfterCorruption()
                XCTAssertEqual(try storedEvents(), session)
            }
        }
    }

    func testLogOnlyBurstAndEndedPromptsSaveTheLogOncePerPassAndKeepCapAndUnknownFields() async throws {
        for action in [AutoStopRule.Action.silent, .prompt] {
            defaults.removePersistentDomain(forName: suite)
            let seed = AutoStopEvent(timestamp: date, processName: "old", pid: 9, ruleID: UUID(), outcome: .logged, detail: "old")
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
            raw["futureField"] = "preserve"
            defaults.set(try JSONSerialization.data(withJSONObject: [raw]), forKey: "events")
            let inventory = Batch08Inventory(processes: (4101...4150).map { process(pid: Int32($0)) })
            let store = makeStore(inventory: inventory)
            XCTAssertTrue(store.add(rule(action: action)))
            defaults.resetEventWrites()
            await store.evaluateNow()
            if action == .prompt {
                await inventory.set([])
                await store.evaluateNow()
            }
            XCTAssertEqual(defaults.eventWrites, 1, action.rawValue)
            XCTAssertEqual(store.events.count, 51)
            XCTAssertEqual(try storedEvents(), store.events)
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "events"))) as? [[String: Any]])
            XCTAssertEqual(persisted.last?["futureField"] as? String, "preserve")
            await inventory.set((4201...4401).map { process(pid: Int32($0)) })
            await store.evaluateNow()
            if action == .prompt { await inventory.set([]); await store.evaluateNow() }
            XCTAssertEqual(store.events.count, 200)
        }
    }

    func testFailedLogBatchRollsBackOccurrencesAndPreservesPreviousHistory() async throws {
        let seed = AutoStopEvent(timestamp: date, processName: "old", pid: 9, ruleID: UUID(), outcome: .logged, detail: "old")
        let original = try JSONEncoder().encode([seed])
        defaults.set(original, forKey: "events")
        let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
        XCTAssertTrue(store.add(rule(action: .silent)))
        date = Date(timeIntervalSince1970: .infinity) // JSONEncoder refuses a non-finite timestamp.
        await store.evaluateNow()
        XCTAssertEqual(store.events, [seed])
        XCTAssertEqual(defaults.data(forKey: "events"), original)
        date = Date(timeIntervalSince1970: 1_000)
        await store.evaluateNow()
        XCTAssertEqual(store.events.map(\.processName), ["Example", "old"])
        XCTAssertEqual(try storedEvents(), store.events)
    }

    func testWaitingAutomaticActionDoesNotDelayPromptsOrDurableLogOnlyEvents() async {
        let inventory = Batch08Inventory(processes: [process(), process(pid: 4102, name: "Prompted"), process(pid: 4103, name: "Logged")])
        let store = makeStore(inventory: inventory, polling: ProcessPollingController(sleep: { _ in false }))
        XCTAssertTrue(store.add(rule(action: .kill)))
        XCTAssertTrue(store.add(rule(name: "Prompted")))
        XCTAssertTrue(store.add(rule(name: "Logged", action: .silent)))
        let gate = Batch08Gate()
        var attempts = 0
        // The engine's immediate tick runs one pass; the stop waits on the gate.
        store.start { _, _ in attempts += 1; await gate.wait(); return .stopped }
        await waitUntil { attempts == 1 }
        XCTAssertEqual(store.pendingPrompts.map(\.process.name), ["Prompted"])
        XCTAssertEqual(store.events.map(\.processName), ["Logged"])
        XCTAssertEqual(makeStore().events.map(\.processName), ["Logged"])
        await gate.release()
        await waitUntil { store.events.count == 2 }
        store.stop()
        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .logged])
    }

    func testAutomaticRetryRejectedKeepsBudgetAndStaleConfirmsExit() async {
        for second in [ProcessActionResult.rejected, .stale] {
            defaults.removePersistentDomain(forName: suite)
            let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
            XCTAssertTrue(store.add(rule(action: .kill)))
            var attempts = 0
            store.start(cadence: 10) { _, _ in
                attempts += 1
                return attempts == 1 ? .requestedStillRunning : attempts == 2 ? second : .stopped
            }
            store.stop()
            await store.evaluateNow()
            instant = instant.advanced(by: .seconds(10))
            await store.evaluateNow()
            XCTAssertEqual(attempts, 2)
            XCTAssertFalse(store.events.contains { $0.outcome == .failed })
            if second == .rejected {
                instant = instant.advanced(by: .seconds(10))
                await store.evaluateNow()
                XCTAssertEqual(attempts, 3)
            }
            XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested])
            if second == .stale { XCTAssertEqual(store.events.first?.detail, "Exited after the stop request.") }
        }
    }

    func testStillMatchingEditDuringRetryRetainsAcceptedStopBudget() async {
        let store = makeStore(inventory: Batch08Inventory(processes: [process()]))
        let original = rule(action: .kill)
        XCTAssertTrue(store.add(original))
        var attempts = 0
        store.start(cadence: 10) { _, _ in
            attempts += 1
            if attempts == 2 {
                var edited = original
                edited.runtimeMinutes = 2
                XCTAssertTrue(store.update(edited))
                XCTAssertTrue(Task.isCancelled)
                return .rejected
            }
            return .requestedStillRunning
        }
        store.stop()
        await store.evaluateNow()
        instant = instant.advanced(by: .seconds(10))
        await store.evaluateNow()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.events.map(\.outcome), [.stopRequested])
        await store.evaluateNow()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(store.events.map(\.outcome), [.failed, .stopRequested])
        await store.evaluateNow()
        XCTAssertEqual(attempts, 3)
    }

    func testEngineErrorIsVisibleAndClearsOnSuccessfulObservation() async {
        let inventory = Batch08Inventory()
        await inventory.fail(.commandFailed("ps exploded"))
        let store = makeStore(inventory: inventory)
        await store.evaluateNow()
        XCTAssertEqual(store.engineError, ProcessInventoryError.commandFailed("ps exploded").localizedDescription)
        await inventory.set([])
        await store.evaluateNow()
        XCTAssertNil(store.engineError)
    }

    func testRemovingOrDisablingLastRuleStopsPollingBeforeExplicitStop() async {
        for remove in [false, true] {
            defaults.removePersistentDomain(forName: suite)
            let inventory = Batch08Inventory()
            let sleeper = Batch08Sleeper()
            let store = makeStore(inventory: inventory, polling: ProcessPollingController { await sleeper.sleep($0) })
            let target = rule()
            XCTAssertTrue(store.add(target))
            store.start { _, _ in .rejected }
            await waitUntil { await sleeper.count == 1 }
            XCTAssertTrue(remove ? store.remove(target) : store.setEnabled(false, for: target))
            await sleeper.resume(true)
            await settle()
            let loads = await inventory.count
            let sleeps = await sleeper.count
            XCTAssertEqual(loads, 1)
            XCTAssertEqual(sleeps, 1)
            store.stop()
            await sleeper.resume(false)
        }
    }

    func testRuleEditDuringCancelledPassTriggersImmediateFollowUpWithoutSleeperWake() async {
        let inventory = Batch08Inventory(processes: [process()])
        await inventory.blockNextLoad()
        let sleeper = Batch08Sleeper()
        let store = makeStore(inventory: inventory, polling: ProcessPollingController { await sleeper.sleep($0) })
        XCTAssertTrue(store.add(rule()))
        store.start { _, _ in .rejected }
        await waitUntil { await inventory.count == 1 }
        XCTAssertTrue(store.add(rule(name: "Other")))
        await settle()
        let before = await inventory.count
        XCTAssertEqual(before, 1)
        await inventory.releaseLoad()
        await waitUntil { store.pendingPrompts.count == 1 }
        let after = await inventory.count
        XCTAssertEqual(after, 2, "the refused evaluation runs once the cancelled pass ends")
        store.stop()
        await sleeper.resume(false)
    }

    /// Automatic stops run after the rest of the pass. A rule edit during one
    /// of them cancels the pass; the stops it had not reached yet must be
    /// left for the next pass, not marked handled and abandoned.
    func testCancelledPassLeavesUndispatchedAutomaticStopsForTheNextPass() async {
        let store = makeStore(
            inventory: Batch08Inventory(processes: [process(), process(pid: 4102)]),
            polling: ProcessPollingController(sleep: { _ in false })
        )
        XCTAssertTrue(store.add(rule(action: .kill)))
        var stopped: [Int32] = []
        store.start { _, target in
            stopped.append(target.pid)
            if stopped.count == 1 {
                // Replaces the polling task, cancelling the pass in flight.
                XCTAssertTrue(store.add(self.rule(name: "Other")))
            }
            return .stopped
        }
        await waitUntil { stopped.count == 2 }
        store.stop()
        XCTAssertEqual(stopped, [4101, 4102])
        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopped])
    }

    func testCompletedAutomaticStopIsRecordedWhileTheNextStopWaits() async {
        let store = makeStore(
            inventory: Batch08Inventory(processes: [process(), process(pid: 4102)]),
            polling: ProcessPollingController(sleep: { _ in false })
        )
        XCTAssertTrue(store.add(rule(action: .kill)))
        let gate = Batch08Gate()
        var attempts = 0
        store.start { _, _ in
            attempts += 1
            if attempts == 2 { await gate.wait() }
            return .stopped
        }
        await waitUntil { attempts == 2 }
        XCTAssertEqual(store.events.map(\.pid), [4101])
        XCTAssertEqual(makeStore().events.map(\.pid), [4101], "the first result is saved before the second stop finishes")
        await gate.release()
        await waitUntil { store.events.count == 2 }
        store.stop()
        XCTAssertEqual(store.events.map(\.pid), [4102, 4101])
    }

    /// A retired rule keeps no retry and no exit tracking for an accepted Auto
    /// Stop (AutoStopRuleLifecycleTests pins that), so its "waiting for the
    /// process to exit" record gets a closing record instead of waiting forever.
    func testRetiringAnAutoStopRuleAfterDeliveryClosesItsWaitingRecord() async throws {
        for retirement in ["disable", "delete", "offsets", "retarget"] {
            defaults.removePersistentDomain(forName: suite)
            let inventory = Batch08Inventory(processes: [process()])
            let store = makeStore(inventory: inventory)
            let target = rule(action: .kill)
            XCTAssertTrue(store.add(target))
            var attempts = 0
            store.start(cadence: 10) { _, _ in attempts += 1; return .requestedStillRunning }
            store.stop()
            await store.evaluateNow()
            XCTAssertEqual(store.events.first?.detail, "Stop requested; waiting for the process to exit.", retirement)
            switch retirement {
            case "disable": XCTAssertTrue(store.setEnabled(false, for: target))
            case "delete": XCTAssertTrue(store.remove(target))
            case "offsets": XCTAssertTrue(store.remove(at: IndexSet(integer: 0)))
            default:
                var retargeted = target
                retargeted.executablePath = "/batch08/other/Example"
                XCTAssertTrue(store.update(retargeted))
            }
            XCTAssertEqual(store.events.map(\.outcome), [.stopRequested, .stopRequested], retirement)
            XCTAssertEqual(
                store.events.first?.detail,
                "The rule changed or was removed before the process exited; its exit will not be tracked.",
                retirement
            )
            XCTAssertEqual(try storedEvents(), store.events, retirement)
            instant = instant.advanced(by: .seconds(10))
            await store.evaluateNow()
            await inventory.set([])
            await store.evaluateNow()
            XCTAssertEqual(attempts, 1, retirement)
            XCTAssertEqual(store.events.count, 2, retirement)
        }
    }

    /// The same when the rule is retired while the retry is in flight and the
    /// retry never signals: the first request's record is closed, or resolved
    /// when the process already exited.
    func testRuleRetiredDuringAnUnsignalledRetryClosesTheWaitingRecord() async {
        for second in [ProcessActionResult.rejected, .stale] {
            defaults.removePersistentDomain(forName: suite)
            let inventory = Batch08Inventory(processes: [process()])
            let store = makeStore(inventory: inventory)
            let target = rule(action: .kill)
            XCTAssertTrue(store.add(target))
            var attempts = 0
            store.start(cadence: 10) { _, _ in
                attempts += 1
                guard attempts == 2 else { return .requestedStillRunning }
                XCTAssertTrue(store.setEnabled(false, for: target))
                return second
            }
            store.stop()
            await store.evaluateNow()
            instant = instant.advanced(by: .seconds(10))
            await store.evaluateNow()
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(store.events.map(\.outcome), [second == .stale ? .stopped : .stopRequested, .stopRequested])
            XCTAssertEqual(
                store.events.first?.detail,
                second == .stale
                    ? "Exited after the stop request."
                    : "The rule changed or was removed before the process exited; its exit will not be tracked."
            )
            await inventory.set([])
            await store.evaluateNow()
            XCTAssertEqual(store.events.count, 2)
        }
    }

    /// Switching off the last rule normally stops polling, but a confirmed
    /// stop still waiting for its process keeps it running until that exit
    /// is recorded, and no longer.
    func testConfirmedStopKeepsPollingUntilItsExitAfterTheLastRuleIsSwitchedOff() async throws {
        let inventory = Batch08Inventory(processes: [process()])
        let sleeper = Batch08Sleeper()
        let store = makeStore(inventory: inventory, polling: ProcessPollingController { await sleeper.sleep($0) })
        let target = rule()
        XCTAssertTrue(store.add(target))
        store.start { _, _ in .requestedStillRunning }
        await waitUntil { store.currentPrompt != nil }
        await store.finishStop(try XCTUnwrap(store.claimPrompt(XCTUnwrap(store.currentPrompt))))
        await waitUntil { await sleeper.count == 1 }
        XCTAssertTrue(store.setEnabled(false, for: target))
        await waitUntil { await sleeper.count == 2 }
        await inventory.set([])
        await sleeper.resume(true)
        await waitUntil { store.events.first?.detail == "Exited after the stop request." }
        await settle()
        let sleeps = await sleeper.count
        XCTAssertEqual(sleeps, 2, "polling stops once no confirmed stop is left to watch")
        XCTAssertEqual(store.events.map(\.outcome), [.stopped, .stopRequested])
        store.stop()
        await sleeper.resume(false)
    }

    private func makeStore(inventory: any ProcessInventoryProviding = Batch08Inventory(), polling: ProcessPollingController? = nil) -> AutoStopRulesStore {
        AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events", inventory: inventory,
                           now: { self.date }, pollingController: polling, currentUID: getuid(), currentPID: getpid(),
                           monotonicNow: { self.instant })
    }

    private func rule(name: String = "Example", action: AutoStopRule.Action = .prompt) -> AutoStopRule {
        AutoStopRule(processName: name, executablePath: action == .kill ? path : nil, runtimeMinutes: 1, action: action)
    }

    private func process(pid: Int32 = 4101, name: String = "Example", start: String = "start", path: String? = nil, elapsed: String = "10:00") -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1, command: name,
                   executablePath: path ?? self.path, elapsedTime: elapsed, startTime: start,
                   netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func storedEvents() throws -> [AutoStopEvent] {
        try JSONDecoder().decode([AutoStopEvent].self, from: XCTUnwrap(defaults.data(forKey: "events")))
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

/// Same actor-based fake inventory pattern as the lifecycle tests, with an optional
/// read failure and first-load gate for engine scheduling tests.
actor Batch08Inventory: ProcessInventoryProviding {
    private var result: Result<[AppProcess], ProcessInventoryError>
    private var blocks = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    init(processes: [AppProcess] = []) { result = .success(processes) }
    func set(_ processes: [AppProcess]) { result = .success(processes) }
    func fail(_ error: ProcessInventoryError) { result = .failure(error) }
    func blockNextLoad() { blocks = true }
    func releaseLoad() { continuation?.resume(); continuation = nil }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        count += 1
        if blocks {
            blocks = false
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
}

private actor Batch08Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor Batch08Sleeper {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var count = 0
    func sleep(_ interval: TimeInterval) async -> Bool {
        count += 1
        return await withCheckedContinuation { continuations.append($0) }
    }
    func resume(_ value: Bool) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

/// In-memory test defaults (see InMemoryUserDefaults) that count writes of
/// the event log, to pin one save per engine pass.
private final class Batch08Defaults: InMemoryUserDefaults {
    private(set) var eventWrites = 0
    func resetEventWrites() { eventWrites = 0 }
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "events" { eventWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
