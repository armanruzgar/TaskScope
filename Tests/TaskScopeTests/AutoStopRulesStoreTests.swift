import XCTest
@testable import TaskScope

@MainActor
final class AutoStopRulesStoreTests: XCTestCase {
    nonisolated(unsafe) private var userDefaults: UserDefaults!
    private let suiteName = "TaskScope.AutoStopRulesStoreTests.\(UUID().uuidString)"
    private let key = "auto-stop-rules-tests"
    private let eventsKey = "auto-stop-events-tests"
    nonisolated(unsafe) private var currentDate: Date!

    override func setUp() {
        super.setUp()
        userDefaults = InMemoryUserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        currentDate = Date(timeIntervalSince1970: 1_000)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        currentDate = nil
        super.tearDown()
    }

    func testRulesPersistToConfiguredUserDefaults() {
        let store = makeStore()
        let rule = AutoStopRule(processName: "Example", runtimeMinutes: 5, action: .prompt)

        XCTAssertTrue(store.add(rule))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.rules, [rule])
    }

    func testRealRuntimeImmediatelyQualifiesAfterColdStart() async {
        let process = appProcess(pid: 42, elapsed: "10:00")
        let store = makeStore(inventory: ScriptedInventory(processes: [process]))
        let rule = AutoStopRule(
            processName: "Example",
            executablePath: "/Applications/Example.app/Example",
            runtimeMinutes: 1,
            action: .kill
        )
        store.add(rule)

        var actions: [(AutoStopRule, AppProcess)] = []
        store.start { rule, process in actions.append((rule, process)); return .stopped }
        store.stop()
        await store.evaluateNow()

        XCTAssertEqual(actions.map(\.0), [rule])
        XCTAssertEqual(actions.map(\.1.pid), [42])
    }

    func testOccurrenceUsesStableIdentityAndOnlyTriggersOnce() async {
        let inventory = ScriptedInventory(processes: [])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        let first = appProcess(pid: 42, elapsed: "02:00", startTime: "first")
        let replacement = appProcess(pid: 42, elapsed: "02:00", startTime: "second")
        var identities: [ProcessIdentity] = []

        inventory.setProcesses([first])
        await store.evaluateNow()
        identities.append(contentsOf: store.pendingPrompts.map(\.process.identity))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1)
        inventory.setProcesses([replacement])
        await store.evaluateNow()
        identities.append(contentsOf: store.pendingPrompts.map(\.process.identity))

        XCTAssertEqual(identities, [first.identity, replacement.identity])
    }

    func testTwoPromptRulesQueueSeriallyAndDismissIsRecorded() async {
        let inventory = ScriptedInventory(processes: [
            appProcess(pid: 41, command: "/Example", elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, command: "/Other", elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))

        await store.evaluateNow()

        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42])
        store.dismissCurrentPrompt()
        XCTAssertEqual(store.currentPrompt?.process.pid, 42)
        XCTAssertEqual(store.events.first?.outcome, .dismissed)

        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [42])
    }

    func testTwoAutomaticActionsExecuteSeriallyAndReportOutcomes() async {
        let inventory = ScriptedInventory(processes: [
            appProcess(pid: 41, command: "/Example", elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, command: "/Other", elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory)
        store.add(AutoStopRule(
            processName: "Example",
            executablePath: "/Example",
            runtimeMinutes: 1,
            action: .kill
        ))
        store.add(AutoStopRule(
            processName: "Other",
            executablePath: "/Other",
            runtimeMinutes: 1,
            action: .kill
        ))
        var actionOrder: [Int32] = []
        store.start(cadence: 60) { _, process in
            actionOrder.append(process.pid)
            return process.pid == 41 ? .stopped : .rejected
        }

        await waitUntil { store.events.count == 2 }
        store.stop()

        XCTAssertEqual(actionOrder, [41, 42])
        XCTAssertEqual(Set(store.events.map(\.outcome)), Set([.stopped, .failed]))
    }

    func testLogOnlyPersistsBoundedVisibleEvents() async {
        let inventory = ScriptedInventory(processes: [
            appProcess(pid: 41, elapsed: "03:00", startTime: "one"),
            appProcess(pid: 42, elapsed: "03:00", startTime: "two")
        ])
        let store = makeStore(inventory: inventory, eventLimit: 1)
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .silent))

        await store.evaluateNow()

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].outcome, .logged)
        let reloaded = makeStore(inventory: inventory, eventLimit: 1)
        XCTAssertEqual(reloaded.events, store.events)
    }

    func testDuplicateNamesAreRejectedCaseInsensitivelyAndRuleCanBeEdited() {
        let store = makeStore()
        let first = AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)
        XCTAssertTrue(store.add(first))
        XCTAssertFalse(store.add(AutoStopRule(
            processName: " example ",
            executablePath: "/Applications/Example.app/Example",
            runtimeMinutes: 2,
            action: .kill
        )))
        XCTAssertNotNil(store.validationError)

        var updated = first
        updated.runtimeMinutes = 8
        updated.action = .silent
        updated.isEnabled = false
        XCTAssertTrue(store.update(updated))

        XCTAssertEqual(store.rules, [updated])
        XCTAssertNil(store.validationError)
    }

    func testClearValidationErrorDropsAnAbandonedEditsDuplicateMessage() {
        let store = makeStore()
        let node = AutoStopRule(processName: "node", runtimeMinutes: 1, action: .prompt)
        let python = AutoStopRule(processName: "python", runtimeMinutes: 1, action: .prompt)
        XCTAssertTrue(store.add(node))
        XCTAssertTrue(store.add(python))

        var renamed = python
        renamed.processName = "node"
        XCTAssertFalse(store.update(renamed))
        XCTAssertEqual(store.validationError, "A rule for node already exists.")

        store.clearValidationError()

        XCTAssertNil(store.validationError)
        XCTAssertEqual(store.rules, [node, python])
    }

    func testElapsedRuntimeParserSupportsPsFormats() {
        XCTAssertEqual(appProcess(pid: 1, elapsed: "01:02").runtimeSeconds, 62)
        XCTAssertEqual(appProcess(pid: 1, elapsed: "02:03:04").runtimeSeconds, 7_384)
        XCTAssertEqual(appProcess(pid: 1, elapsed: "2-03:04:05").runtimeSeconds, 183_845)
        XCTAssertNil(appProcess(pid: 1, elapsed: "invalid").runtimeSeconds)
        XCTAssertNil(appProcess(pid: 1, elapsed: "xx:01:02").runtimeSeconds)
        XCTAssertNil(appProcess(pid: 1, elapsed: "-01:02").runtimeSeconds)
        XCTAssertNil(appProcess(pid: 1, elapsed: "1-24:00:00").runtimeSeconds)
    }

    func testAutomaticStopMatchesTheTrustedExecutablePath() async {
        let inventory = ScriptedInventory(processes: [])
        let store = makeStore(inventory: inventory)
        let rule = AutoStopRule(
            processName: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            runtimeMinutes: 1,
            action: .kill
        )
        XCTAssertTrue(store.add(rule))
        let trusted = appProcess(
            pid: 41,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            elapsed: "10:00",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let impostor = appProcess(
            pid: 42,
            command: "/tmp/Example",
            elapsed: "10:00",
            executablePath: "/tmp/Example"
        )
        var matchedPIDs: [Int32] = []

        inventory.setProcesses([impostor, trusted])
        store.start { _, process in matchedPIDs.append(process.pid); return .stopped }
        store.stop()
        await store.evaluateNow()

        XCTAssertEqual(matchedPIDs, [41])
    }

    func testEnabledAutomaticStopRequiresAnExecutablePath() {
        let store = makeStore()

        XCTAssertFalse(store.add(AutoStopRule(
            processName: "Example",
            runtimeMinutes: 1,
            action: .kill
        )))
        XCTAssertEqual(store.rules, [])
        XCTAssertNotNil(store.validationError)

        XCTAssertFalse(store.add(AutoStopRule(
            processName: "Example",
            executablePath: "relative/Example",
            runtimeMinutes: 1,
            action: .prompt
        )))
        XCTAssertTrue(store.validationError?.contains("absolute") == true)
    }

    func testLegacyNameOnlyAutomaticStopIsLoadedDisabledForReview() throws {
        let legacy = AutoStopRule(
            processName: "Example",
            runtimeMinutes: 1,
            action: .kill
        )
        userDefaults.set(try JSONEncoder().encode([legacy]), forKey: key)

        let store = makeStore()

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.action, .kill)
        XCTAssertFalse(store.rules.first?.isEnabled ?? true)
        XCTAssertNil(store.rules.first?.executablePath)
        XCTAssertFalse(store.isRulesReadOnlyAfterRecovery)
    }

    func testEngineDoesNotPollUntilThereIsAnEnabledRule() async {
        let inventory = ScriptedInventory(processes: [])
        let sleeper = ControlledAutoStopSleeper()
        let pollingController = ProcessPollingController { interval in
            await sleeper.sleep(interval: interval)
        }
        let store = AutoStopRulesStore(
            userDefaults: userDefaults,
            key: key,
            eventsKey: eventsKey,
            inventory: inventory,
            now: { self.currentDate },
            pollingController: pollingController
        )

        store.start(cadence: 60) { _, _ in .rejected }
        for _ in 0..<10 { await Task.yield() }
        let initialInventoryCount = inventory.readCount
        let initialSleepCount = await sleeper.requestCount()
        XCTAssertEqual(initialInventoryCount, 0)
        XCTAssertEqual(initialSleepCount, 0)

        XCTAssertTrue(store.add(AutoStopRule(
            processName: "Example",
            runtimeMinutes: 1,
            action: .prompt
        )))
        await inventory.waitForRead(1)
        await sleeper.waitForRequest()
        let enabledInventoryCount = inventory.readCount
        let enabledSleepCount = await sleeper.requestCount()
        XCTAssertEqual(enabledInventoryCount, 1)
        XCTAssertEqual(enabledSleepCount, 1)

        XCTAssertTrue(store.remove(store.rules[0]))
        store.stop()
        await sleeper.resume(returning: false)
    }

    /// `/opt/homebrew/bin/node` is a symlink; the kernel reports the Cellar
    /// binary as the executable. The rule must match through the link.
    func testRulePathMatchesTheKernelPathThroughASymlink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("RealTool")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        let link = directory.appendingPathComponent("linked-tool")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let inventory = ScriptedInventory(processes: [])
        let store = makeStore(inventory: inventory)
        XCTAssertTrue(store.add(AutoStopRule(
            processName: "RealTool",
            executablePath: link.path,
            runtimeMinutes: 1,
            action: .kill
        )))
        XCTAssertEqual(store.rules[0].executablePath, link.standardizedFileURL.path)
        XCTAssertEqual(makeStore().rules, store.rules)

        let kernelPath = AutoStopRuleValidation.canonicalPath(real.path)
        let running = appProcess(
            pid: 41,
            command: kernelPath,
            elapsed: "10:00",
            executablePath: kernelPath
        )
        var matched: [Int32] = []
        inventory.setProcesses([running])
        store.start { _, process in matched.append(process.pid); return .stopped }
        store.stop()
        await store.evaluateNow()

        XCTAssertEqual(matched, [41])
        XCTAssertTrue(AutoStopRuleValidation.pathsMatch(link.path, real.path))
        XCTAssertTrue(AutoStopRuleValidation.pathsMatch("/tmp/\(UUID().uuidString)", "/private/tmp/never-exists")
            == false)

        let upgraded = directory.appendingPathComponent("v2/RealTool")
        try FileManager.default.createDirectory(at: upgraded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: upgraded)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: upgraded)
        try FileManager.default.removeItem(at: real)
        let upgradedPath = AutoStopRuleValidation.canonicalPath(upgraded.path)
        let reloaded = makeStore(inventory: ScriptedInventory(processes: [appProcess(
            pid: 42, command: upgradedPath, elapsed: "10:00", executablePath: upgradedPath
        )]))
        reloaded.start { _, process in matched.append(process.pid); return .stopped }
        reloaded.stop()
        await reloaded.evaluateNow()

        XCTAssertEqual(reloaded.rules[0].executablePath, link.standardizedFileURL.path)
        XCTAssertEqual(matched, [41, 42])
    }

    func testPreviouslyResolvedStoredRuleStillMatchesItsExecutable() async throws {
        let rule = AutoStopRule(
            processName: "Example", executablePath: "/opt/homebrew/Cellar/example/1/bin/Example",
            runtimeMinutes: 1, action: .kill
        )
        userDefaults.set(try JSONEncoder().encode([rule]), forKey: key)
        let store = makeStore(inventory: ScriptedInventory(processes: [appProcess(
            pid: 41, command: try XCTUnwrap(rule.executablePath), elapsed: "10:00"
        )]))
        var matched: [Int32] = []

        store.start { _, process in matched.append(process.pid); return .stopped }
        store.stop()
        await store.evaluateNow()

        XCTAssertEqual(store.rules, [rule])
        XCTAssertEqual(matched, [41])
    }

    func testUndecodableRulesAreRejectedWhileValidRulesRemainEnforced() async throws {
        let valid = AutoStopRule(
            processName: "Example", executablePath: "/Applications/Example.app/Example",
            runtimeMinutes: 1, action: .kill
        )
        let other = AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt)
        let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
        let otherJSON = String(decoding: try JSONEncoder().encode(other), as: UTF8.self)
        let original = Data("""
        [null, \(validJSON), {"processName":"Future","runtimeMinutes":1,"action":"futureAction"},
         {"processName":42}, \(otherJSON), \(validJSON)]
        """.utf8)
        userDefaults.set(original, forKey: key)
        let store = makeStore(inventory: ScriptedInventory(processes: [appProcess(pid: 41, elapsed: "10:00")]))

        XCTAssertEqual(store.rules, [valid, other])
        XCTAssertTrue(store.rulesRecoveryMessage?.contains("Rejected 4") == true)
        XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
        XCTAssertEqual(userDefaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
        XCTAssertNil(userDefaults.data(forKey: "\(key).corruptBackup"))
        XCTAssertFalse(store.remove(valid))
        XCTAssertFalse(store.add(AutoStopRule(processName: "New", runtimeMinutes: 1, action: .prompt)))
        var matched: [Int32] = []
        store.start { _, process in matched.append(process.pid); return .stopped }
        store.stop()
        await store.evaluateNow()
        XCTAssertEqual(matched, [41])
        XCTAssertEqual(userDefaults.data(forKey: key), original)
        XCTAssertEqual(makeStore().rules, [valid, other])

        store.resetRulesAfterCorruption()

        XCTAssertFalse(store.isRulesReadOnlyAfterRecovery)
        XCTAssertNil(store.rulesRecoveryMessage)
        XCTAssertEqual(try JSONDecoder().decode([AutoStopRule].self, from: XCTUnwrap(userDefaults.data(forKey: key))), [valid, other])
        XCTAssertEqual(userDefaults.data(forKey: "\(key).rejectedMigrationBackup"), original)
    }

    func testNonArrayRulesPayloadUsesCorruptRecovery() {
        for json in ["{}", "null", "42", "\"rules\""] {
            let original = Data(json.utf8)
            userDefaults.set(original, forKey: key)
            let store = makeStore()

            XCTAssertTrue(store.rules.isEmpty)
            XCTAssertTrue(store.isRulesReadOnlyAfterRecovery)
            XCTAssertTrue(store.rulesRecoveryMessage?.contains("corruptBackup") == true)
            XCTAssertEqual(userDefaults.data(forKey: key), original)
            XCTAssertNil(userDefaults.data(forKey: "\(key).rejectedMigrationBackup"))
        }
    }

    /// An outcome written by another build must survive a round trip verbatim
    /// instead of being decoded as Logged.
    func testUnknownEventOutcomeRoundTripsInsteadOfBecomingLogged() throws {
        let json = Data(#"[{"timestamp":0,"processName":"Example","pid":42,"ruleID":"00000000-0000-0000-0000-000000000001","outcome":"vaporized","detail":"x"}]"#.utf8)

        let events = try JSONDecoder().decode([AutoStopEvent].self, from: json)
        XCTAssertEqual(events[0].outcome, .unknown("vaporized"))
        XCTAssertEqual(events[0].outcome.label, "Unknown (vaporized)")

        let reencoded = try JSONEncoder().encode(events)
        XCTAssertTrue(String(decoding: reencoded, as: UTF8.self).contains("\"vaporized\""))
        XCTAssertEqual(try JSONDecoder().decode([AutoStopEvent].self, from: reencoded), events)
        XCTAssertEqual(AutoStopEvent.Outcome(rawValue: "stopRequested"), .stopRequested)
    }

    /// The first slot keeps the *first* unreadable payload. A later, different
    /// unreadable payload is preserved in the next numbered slot, so resetting
    /// after a second corruption cannot destroy the only copy of its bytes.
    func testSecondUnreadableLaunchPreservesItsPayloadInTheNextSlot() {
        let first = Data([0xAA, 0x01])
        let second = Data([0xBB, 0x02])
        userDefaults.set(first, forKey: key)
        let firstStore = makeStore()
        XCTAssertTrue(firstStore.rulesRecoveryMessage?.contains("was backed up as \(key).corruptBackup.") == true)

        userDefaults.set(second, forKey: key)
        let secondStore = makeStore()

        XCTAssertTrue(
            secondStore.rulesRecoveryMessage?.contains("was backed up as \(key).corruptBackup.2.") == true,
            secondStore.rulesRecoveryMessage ?? "nil"
        )
        XCTAssertEqual(userDefaults.data(forKey: "\(key).corruptBackup"), first)
        XCTAssertEqual(userDefaults.data(forKey: "\(key).corruptBackup.2"), second)
        XCTAssertEqual(userDefaults.data(forKey: key), second)

        // Relaunching with the same bytes reuses their slot instead of filling another.
        let thirdStore = makeStore()
        XCTAssertTrue(thirdStore.rulesRecoveryMessage?.contains("\(key).corruptBackup.2.") == true)
        XCTAssertNil(userDefaults.data(forKey: "\(key).corruptBackup.3"))
    }

    /// When every slot holds another payload, the message must not claim a backup.
    func testUnreadableLaunchWithEveryBackupSlotOccupiedSaysItWasNotBackedUp() {
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            let slotKey = slot == 1 ? "\(key).corruptBackup" : "\(key).corruptBackup.\(slot)"
            userDefaults.set(Data([0xC0, UInt8(slot)]), forKey: slotKey)
        }
        userDefaults.set(Data([0xDD, 0x04]), forKey: key)

        let store = makeStore()

        XCTAssertTrue(
            store.rulesRecoveryMessage?.contains("was not backed up") == true,
            store.rulesRecoveryMessage ?? "nil"
        )
        XCTAssertEqual(userDefaults.data(forKey: key), Data([0xDD, 0x04]))
    }

    func testCorruptRulesAndEventsAreBackedUp() {
        let corruptRules = Data([0xFF, 0x01])
        let corruptEvents = Data([0xFE, 0x02])
        userDefaults.set(corruptRules, forKey: key)
        userDefaults.set(corruptEvents, forKey: eventsKey)

        let store = makeStore()

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.recoveryMessages.count, 2)
        XCTAssertEqual(userDefaults.data(forKey: "\(key).corruptBackup"), corruptRules)
        XCTAssertEqual(userDefaults.data(forKey: "\(eventsKey).corruptBackup"), corruptEvents)
    }

    private func makeStore(
        inventory: any ProcessInventoryProviding = ScriptedInventory(processes: []),
        eventLimit: Int = 200
    ) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: userDefaults,
            key: key,
            eventsKey: eventsKey,
            inventory: inventory,
            eventLimit: eventLimit,
            now: { self.currentDate }
        )
    }

    private func appProcess(
        pid: Int32,
        command: String = "/Applications/Example.app/Example",
        elapsed: String,
        startTime: String = "start",
        executablePath: String? = nil
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 0,
            uid: getuid(),
            cpu: 0,
            memoryMB: 0,
            command: command,
            executablePath: executablePath ?? command,
            elapsedTime: elapsed,
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private actor ControlledAutoStopSleeper {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Bool, Never>?

    func sleep(interval: TimeInterval) async -> Bool {
        count += 1
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func requestCount() -> Int { count }

    func waitForRequest() async {
        guard count == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume(returning value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
