import Darwin
import XCTest
@testable import TaskScope

/// `ps etime` is the current wall clock minus the wall-clock start, so a
/// forward clock step makes processes look older than they are. Runtime rules
/// must also reach their threshold on the kernel's monotonic clocks.
@MainActor
final class MonotonicRuntimeTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!
    private var clock = UptimeSample(uptime: 0, asleep: 0)
    private let path = "/Applications/Example.app/Contents/MacOS/Example"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.MonotonicRuntime.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testForwardClockStepCannotMakeRuntimeRulesActEarly() async {
        for action in AutoStopRule.Action.allCases {
            defaults.removePersistentDomain(forName: suiteName)
            clock = UptimeSample(uptime: ns(10_000), asleep: 0)
            // The wall clock jumped ahead: ps reports two hours for a process
            // the kernel started five minutes ago.
            let store = makeStore(processes: [process(elapsed: "02:00:00", start: .uptimeNanoseconds(ns(10_000 - 300)))])
            XCTAssertTrue(store.add(rule(action: action)))
            var attempts = 0
            store.start { _, _ in attempts += 1; return .stopped }
            store.stop()

            await store.evaluateNow()
            XCTAssertEqual(attempts, 0, action.rawValue)
            XCTAssertTrue(store.pendingPrompts.isEmpty, action.rawValue)
            XCTAssertTrue(store.events.isEmpty, action.rawValue)

            clock.uptime += ns(55 * 60 - 1)
            await store.evaluateNow()
            XCTAssertEqual(attempts, 0, "One second short of the threshold \(action.rawValue)")

            clock.uptime += ns(1)
            await store.evaluateNow()
            XCTAssertEqual(attempts, action == .kill ? 1 : 0, action.rawValue)
            XCTAssertEqual(store.pendingPrompts.count, action == .prompt ? 1 : 0, action.rawValue)
            let outcomes: [AutoStopEvent.Outcome] = action == .kill ? [.stopped] : action == .silent ? [.logged] : []
            XCTAssertEqual(store.events.map(\.outcome), outcomes, action.rawValue)
        }
    }

    func testCompatibilityEvaluatorUsesTheMonotonicRuntime() {
        clock = UptimeSample(uptime: ns(10_000), asleep: 0)
        let store = makeStore()
        XCTAssertTrue(store.add(rule(action: .prompt)))
        let stepped = process(elapsed: "02:00:00", start: .uptimeNanoseconds(ns(10_000 - 300)))
        var attempts = 0
        store.evaluate(runningProcesses: [stepped]) { _, _ in attempts += 1 }
        XCTAssertEqual(attempts, 0)
        clock.uptime += ns(55 * 60)
        store.evaluate(runningProcesses: [stepped]) { _, _ in attempts += 1 }
        XCTAssertEqual(attempts, 1)
    }

    func testSleepObservedAfterStartCountsTowardRuntime() async {
        clock = UptimeSample(uptime: ns(10_000), asleep: 0)
        let store = makeStore(processes: [process(elapsed: "01:05:05", start: .uptimeNanoseconds(ns(10_000)))])
        XCTAssertTrue(store.add(rule(action: .prompt)))
        clock.uptime += ns(300)
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty, "Five awake minutes are not an hour")

        // An hour asleep: uptime stands still while the sleep total grows.
        clock.asleep += ns(3_600)
        clock.uptime += ns(5)
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1, "Sleep TaskScope observed after the start counts, as in ps etime")
    }

    func testSleepBeforeTaskScopeObservedItDelaysButNeverAdvancesARule() async {
        // The process started before this store existed, and the Mac slept for
        // two hours at some unknown point before the store's first sample.
        clock = UptimeSample(uptime: ns(10_000), asleep: ns(7_200))
        let store = makeStore(processes: [process(elapsed: "02:16:40", start: .uptimeNanoseconds(ns(9_000)))])
        XCTAssertTrue(store.add(rule(action: .prompt)))
        await store.evaluateNow()
        XCTAssertTrue(store.pendingPrompts.isEmpty, "Unobserved sleep is not credited")

        clock.uptime += ns(2_600)
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.count, 1, "An hour of certain existence reaches the threshold")
    }

    func testUnavailableKernelStartBlocksRulesWhileUnreadRowsKeepElapsedTime() async {
        for (start, fires) in [(MonotonicStart.unavailable, false), (.notRead, true)] {
            defaults.removePersistentDomain(forName: suiteName)
            let store = makeStore(processes: [process(elapsed: "02:00:00", start: start)])
            XCTAssertTrue(store.add(rule(action: .prompt)))
            await store.evaluateNow()
            XCTAssertEqual(store.pendingPrompts.count, fires ? 1 : 0, "\(start)")
        }
    }

    // MARK: - ProcessAgeHistory

    func testAgeHistoryCreditsOnlySleepObservedAfterStart() throws {
        var history = ProcessAgeHistory()
        history.record(UptimeSample(uptime: ns(100), asleep: 0))
        history.record(UptimeSample(uptime: ns(200), asleep: 0))
        let wake = UptimeSample(uptime: ns(200), asleep: ns(3_600))
        history.record(wake)

        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(150), at: wake)), 3_650, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(50), at: wake)), 3_750, accuracy: 0.001,
                       "A process running before the first observation had slept no more than its total")
        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(200), at: wake)), 0, accuracy: 0.001,
                       "A start at a wake's uptime may follow the sleep")
        XCTAssertNil(history.minimumAge(sinceUptime: ns(201), at: wake))

        let later = UptimeSample(uptime: ns(300), asleep: ns(3_600))
        history.record(later)
        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(250), at: later)), 50, accuracy: 0.001,
                       "Sleep before the start is never credited")
    }

    func testAgeHistoryWithoutObservationsCountsAwakeTimeOnly() throws {
        let history = ProcessAgeHistory()
        let sample = UptimeSample(uptime: ns(500), asleep: ns(10_000))
        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(100), at: sample)), 400, accuracy: 0.001)
    }

    func testDroppedObservationsOnlyMakeProcessesLookYounger() throws {
        var full = ProcessAgeHistory()
        var bounded = ProcessAgeHistory(limit: 2)
        let samples = [(100, 0), (200, 10), (300, 20)].map { UptimeSample(uptime: ns($0.0), asleep: ns($0.1)) }
        for sample in samples {
            full.record(sample)
            bounded.record(sample)
        }
        let now = samples[2]
        XCTAssertEqual(try XCTUnwrap(full.minimumAge(sinceUptime: ns(50), at: now)), 270, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bounded.minimumAge(sinceUptime: ns(50), at: now)), 260, accuracy: 0.001)
    }

    func testUnderstatedSleepReadsDoNotSplitASleepPeriod() throws {
        var history = ProcessAgeHistory()
        history.record(UptimeSample(uptime: ns(100), asleep: ns(50)))
        history.record(UptimeSample(uptime: ns(200), asleep: ns(50) - 1))
        let now = UptimeSample(uptime: ns(300), asleep: ns(50))
        history.record(now)
        XCTAssertEqual(try XCTUnwrap(history.minimumAge(sinceUptime: ns(150), at: now)), 150, accuracy: 0.001)
    }

    // MARK: - Kernel start times

    func testCurrentUserRowsCarryValidatedKernelStartTimes() {
        let me = getuid()
        var rows = [
            row(pid: 41, uid: me, start: "a"), row(pid: 42, uid: me, start: "b"),
            row(pid: 43, uid: me, start: "c"), row(pid: 44, uid: me + 1, start: "d")
        ]
        ProcessListReader.attachMonotonicStarts(
            to: &rows,
            startTimes: [41: 7, 43: 9, 44: 11],
            currentUID: me,
            validatedStartTimes: [41: "a", 42: "b", 43: "changed", 44: "d"]
        )
        XCTAssertEqual(rows.map(\.monotonicStart), [.uptimeNanoseconds(7), .unavailable, .unavailable, .notRead])
    }

    func testLiveKernelStartTimeUsesTheUptimeClock() async throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let start = try XCTUnwrap(ProcessListReader.startUptimeNanoseconds(for: ownPID))
        XCTAssertLessThanOrEqual(start, UptimeSample.now().uptime)
        XCTAssertNil(ProcessListReader.startUptimeNanoseconds(for: 1), "root-owned launchd must report unavailable")
        let converted = try XCTUnwrap(UptimeSample.nanoseconds(fromMachTime: mach_absolute_time()))
        let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        XCTAssertLessThan(max(converted, uptime) - min(converted, uptime), 1_000_000_000)

        let inventory = try await ProcessListReader.currentProcessList(fetchExtendedStats: false).get()
        let own = try XCTUnwrap(inventory.first { $0.pid == ownPID })
        guard case .uptimeNanoseconds(let listed) = own.monotonicStart else {
            return XCTFail("The live inventory must read this process's kernel start: \(own.monotonicStart)")
        }
        XCTAssertEqual(listed, start)
        XCTAssertTrue(inventory.filter { $0.uid != getuid() }.allSatisfy { $0.monotonicStart == .notRead })
    }

    // MARK: - Helpers

    private func ns(_ seconds: UInt64) -> UInt64 {
        seconds * 1_000_000_000
    }

    private func makeStore(processes: [AppProcess] = []) -> AutoStopRulesStore {
        AutoStopRulesStore(
            userDefaults: defaults, key: "rules", eventsKey: "events",
            inventory: MonotonicInventory(processes: processes),
            now: { Date(timeIntervalSince1970: 1_000) },
            uptimeClock: { self.clock }
        )
    }

    private func rule(action: AutoStopRule.Action) -> AutoStopRule {
        AutoStopRule(processName: "Example", executablePath: path, runtimeMinutes: 60, action: action)
    }

    private func process(elapsed: String, start: MonotonicStart) -> AppProcess {
        AppProcess(pid: 41, parentPID: 1, uid: getuid(), cpu: 1, memoryMB: 1, command: path,
            executablePath: path, elapsedTime: elapsed, startTime: "start-41", monotonicStart: start,
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil)
    }

    private func row(pid: Int32, uid: uid_t, start: String) -> AppProcess {
        AppProcess(pid: pid, parentPID: 1, uid: uid, cpu: 0, memoryMB: 0, command: "Example",
            elapsedTime: "00:01", startTime: start, netInKB: nil, netOutKB: nil,
            diskReadBytes: nil, diskWriteBytes: nil)
    }
}

private struct MonotonicInventory: ProcessInventoryProviding {
    let processes: [AppProcess]
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> { .success(processes) }
}
