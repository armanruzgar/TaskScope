import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The shared inventory's cache, join and cancellation rules.
final class Batch05InventoryFixTests: XCTestCase {
    /// A load issued after `invalidate()` must not join a read that started
    /// before it (an observer's read in flight across a Stop).
    func testInvalidationDetachesBlockedBasicAndExtendedReads() async {
        for extended in [false, true] {
            let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
            let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
            let first = Task { await inventory.load(fetchExtendedStats: extended) }
            await upstream.waitUntilFirstCallStarted()
            await inventory.invalidate()

            let completed = expectation(description: "A read after invalidation does not wait for the old one")
            let second = Task {
                let result = await inventory.load(fetchExtendedStats: extended)
                completed.fulfill()
                return result
            }
            await fulfillment(of: [completed], timeout: 10)
            await upstream.releaseFirstCall()
            let fresh = await second.value
            _ = await first.value

            XCTAssertEqual(try fresh.get().map(\.pid), [43], "extended: \(extended)")
            let calls = await upstream.callCount()
            XCTAssertEqual(calls, 2)
        }
    }

    /// A basic cache entry has no network or disk values, so it never answers
    /// an extended request.
    func testBasicCacheCannotAnswerExtendedRequest() async {
        let upstream = Batch05CountingUpstream()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)

        _ = await inventory.load(fetchExtendedStats: false)
        _ = await inventory.load(fetchExtendedStats: true)

        let modes = await upstream.requestedModes()
        XCTAssertEqual(modes, [false, true])
    }

    /// An extended read already in flight answers both an extended and a basic
    /// request; neither starts a read of its own.
    func testBasicAndExtendedRequestsJoinAnExtendedReadInFlight() async {
        for extended in [false, true] {
            let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
            let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
            let first = Task { await inventory.load(fetchExtendedStats: true) }
            await upstream.waitUntilFirstCallStarted()
            let second = Task { await inventory.load(fetchExtendedStats: extended) }
            let joined = await batch05Eventually { await inventory.waitingCallerCount == 2 }
            XCTAssertTrue(joined)

            await upstream.releaseFirstCall()
            let firstResult = await first.value
            let secondResult = await second.value

            XCTAssertEqual(firstResult, secondResult)
            XCTAssertEqual(try secondResult.get().map(\.pid), [42], "extended: \(extended)")
            let calls = await upstream.callCount()
            XCTAssertEqual(calls, 1)
        }
    }

    /// The cache window starts when a read completes. Measured from its start,
    /// a read slower than the window was already stale when it finished, and
    /// the next consumer in the same poll tick read everything again.
    func testASlowReadIsSharedForAFullWindowAfterItCompletes() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
        let clock = Batch05Clock()
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 0.5, now: { clock.now() })
        let first = Task { await inventory.load(fetchExtendedStats: false) }
        await upstream.waitUntilFirstCallStarted()
        clock.advance(5)
        await upstream.releaseFirstCall()
        _ = await first.value

        let shared = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try shared.get().map(\.pid), [42])
        clock.advance(0.6)
        let expired = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try expired.get().map(\.pid), [43])
    }

    /// A cancelled sole caller returns at once with `.cancelled`, its read is
    /// cancelled too (so the commands behind it stop), and the next caller
    /// starts a fresh read.
    func testCancelledSoleCallerReturnsAtOnceAndCancelsTheRead() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)], [batch05Process(43)]])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let returned = expectation(description: "The cancelled caller returns before the read ends")
        let first = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            returned.fulfill()
            return result
        }
        await upstream.waitUntilFirstCallStarted()

        first.cancel()
        await fulfillment(of: [returned], timeout: 10)
        let detached = await batch05Eventually { await inventory.waitingCallerCount == 0 }
        XCTAssertTrue(detached)
        let freshDone = expectation(description: "The next caller starts a fresh read")
        let second = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            freshDone.fulfill()
            return result
        }
        await fulfillment(of: [freshDone], timeout: 10)
        await upstream.releaseFirstCall()

        let cancelledResult = await first.value
        let freshResult = await second.value
        XCTAssertEqual(cancelledResult, .failure(.cancelled))
        XCTAssertEqual(try freshResult.get().map(\.pid), [43])
        let cancelledReads = await batch05Eventually { await upstream.cancelledCallCount() == 1 }
        XCTAssertTrue(cancelledReads, "The abandoned read must see its cancellation")
    }

    /// Cancelling one of two callers sharing a read leaves the other one, and
    /// the read, untouched.
    func testCancellingOneJoinerLeavesTheOtherAndTheRead() async {
        let upstream = Batch05BlockingUpstream(results: [[batch05Process(42)]])
        let inventory = CoalescingProcessInventory(upstream: upstream, maximumAge: 60)
        let first = Task { await inventory.load(fetchExtendedStats: true) }
        await upstream.waitUntilFirstCallStarted()
        let returned = expectation(description: "The cancelled joiner returns on its own")
        let second = Task {
            let result = await inventory.load(fetchExtendedStats: false)
            returned.fulfill()
            return result
        }
        let joined = await batch05Eventually { await inventory.waitingCallerCount == 2 }
        XCTAssertTrue(joined)

        second.cancel()
        await fulfillment(of: [returned], timeout: 10)
        let remaining = await inventory.waitingCallerCount
        XCTAssertEqual(remaining, 1)
        await upstream.releaseFirstCall()

        // A regression that drops the other caller must fail, not hang.
        guard let firstResult = await batch05Value(of: first) else {
            return XCTFail("The caller still waiting was never answered")
        }
        let secondResult = await second.value
        XCTAssertEqual(try firstResult.get().map(\.pid), [42])
        XCTAssertEqual(secondResult, .failure(.cancelled))
        let cancelledReads = await upstream.cancelledCallCount()
        XCTAssertEqual(cancelledReads, 0, "A read someone still waits for must not be cancelled")
    }
}

/// The process list reader's composition, process records and details.
final class Batch05ReaderFixTests: XCTestCase {
    private let start = "Wed Oct 7 17:04:47 2026"
    private var list: String {
        "42 1 \(getuid()) 1 1024 \(start) 00:01 <defunct>\n43 1 0 2 2048 \(start) 00:02 Other"
    }
    private var validation: String { "42 \(start)\n43 \(start)" }

    private func read(
        _ results: [ShellCommandResult],
        extended: Bool = false
    ) async -> Result<[AppProcess], ProcessInventoryError> {
        let runner = Batch05ScriptedRunner(results)
        return await ProcessListReader.currentProcessList(
            fetchExtendedStats: extended,
            run: { await runner.run($0) },
            executablePath: { _ in nil },
            startUptime: { _ in 123 },
            zombieState: { $0 == 43 },
            diskIO: { $0 == 42 ? (4096, 8192) : nil },
            currentPID: 42
        )
    }

    func testInventoryFailuresAndCancellationAtBothSnapshots() async {
        for (results, expected) in [
            ([shellResult("", code: 9, error: "denied")], ProcessInventoryError.commandFailed("denied")),
            ([shellResult("", code: 7)], .commandFailed("ps exited with status 7.")),
            ([shellResult("", code: ShellCommandRunner.cancelledExitCode)], .cancelled),
            ([shellResult(list), shellResult("", code: 4)], .commandFailed("Identity validation exited with status 4.")),
            ([shellResult(list), shellResult("", code: ShellCommandRunner.cancelledExitCode)], .cancelled),
            // Well formed, but without TaskScope's own PID: never "nothing running".
            ([shellResult(list), shellResult("43 \(start)")], .parseFailed),
            ([shellResult(list), shellResult("malformed")], .parseFailed)
        ] {
            let result = await read(results)
            XCTAssertEqual(result, .failure(expected))
        }
    }

    func testChurnDropsOnlyTheMissingRowAndAttachesValidatedKernelState() async throws {
        let rows = try await read([shellResult(list), shellResult("42 \(start)")]).get()

        XCTAssertEqual(rows.map(\.pid), [42])
        XCTAssertEqual(rows[0].monotonicStart, .uptimeNanoseconds(123))
        XCTAssertEqual(rows[0].isZombie, false)
        XCTAssertFalse(rows[0].hasExited, "A live process can call itself <defunct>; argv is not exit evidence")
    }

    func testExtendedMergePutsEachValueInItsFieldAndLeavesMissingOnesEmpty() async throws {
        let rows = try await read(
            [shellResult(list), shellResult(validation), shellResult(",bytes_in,bytes_out,\nname.42,2048,3072,")],
            extended: true
        ).get()

        XCTAssertEqual(rows.map(\.pid), [42, 43])
        XCTAssertEqual(rows[0].netInKB, 2)
        XCTAssertEqual(rows[0].netOutKB, 3)
        XCTAssertEqual(rows[0].diskReadBytes, 4096)
        XCTAssertEqual(rows[0].diskWriteBytes, 8192)
        XCTAssertNil(rows[1].netInKB)
        XCTAssertNil(rows[1].netOutKB)
        XCTAssertNil(rows[1].diskReadBytes)
        XCTAssertNil(rows[1].diskWriteBytes)
        XCTAssertTrue(rows[1].hasExited, "The kernel's zombie state decides, whatever the row is called")
        XCTAssertEqual(rows[1].monotonicStart, .notRead)
    }

    func testNetworkParserHandlesDottedAndCommaNamesAndMalformedRows() {
        let stats = ProcessListReader.parseNetworkStats("""
        ,bytes_in,bytes_out,
        com.apple.WebKit.Networking.42,1024,2048,
        a,name.43,3072,4096,
        missing.44,10,
        bad.45,no,20,
        badpid.x,1,2,
        """)

        XCTAssertEqual(stats?.count, 2)
        XCTAssertEqual(stats?[42]?.0, 1)
        XCTAssertEqual(stats?[42]?.1, 2)
        XCTAssertEqual(stats?[43]?.0, 3)
        XCTAssertEqual(stats?[43]?.1, 4)
        XCTAssertNil(ProcessListReader.parseNetworkStats(""))
        XCTAssertNil(ProcessListReader.parseNetworkStats("name.42,,20,"))
    }

    /// Without a recorded kernel state the old text rule still applies.
    func testRowsWithoutKernelStateKeepTheTextFallback() {
        var row = batch05Process(42)
        row.command = "<defunct>"
        XCTAssertTrue(row.hasExited)
        row.isZombie = false
        XCTAssertFalse(row.hasExited)
        row.command = "Example"
        row.isZombie = true
        XCTAssertTrue(row.hasExited)
    }

    func testDetailArgumentsPreserveSpacesAndRejectAnotherProcess() async {
        let process = batch05Process(42)
        let reader = SystemProcessDetailReader()
        let arguments = "python  worker.py --name 'two words'"
        for (pid, stamp, expected) in [
            (42, start, Optional(arguments)),
            (42, "Wed Oct 7 17:04:48 2026", nil),
            (43, start, nil)
        ] {
            let runner = Batch05ScriptedRunner([
                shellResult("42 1 me \(start) /usr/bin/python"),
                shellResult("\(pid) \(stamp) \(arguments)")
            ])

            let detail = await reader.readDetail(for: process, run: { await runner.run($0) })

            XCTAssertEqual(detail?.command, "/usr/bin/python")
            XCTAssertEqual(detail?.arguments, expected)
        }
    }

    @MainActor
    func testDetailSheetShowsTheArgumentsOrSaysTheyAreUnavailable() throws {
        let process = batch05Process(42)
        var detail = ProcessDetail(pid: 42, parentPID: 1, user: "me", startTime: start, command: "/usr/bin/python")
        detail.arguments = "python worker.py --port 8080"

        let shown = ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {})
        XCTAssertNoThrow(try shown.inspect().find(text: "Arguments"))
        XCTAssertNoThrow(try shown.inspect().find(text: "python worker.py --port 8080"))

        detail.arguments = nil
        let unavailable = ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {})
        XCTAssertNoThrow(try unavailable.inspect().find(text: "Unavailable"))
    }

    func testIdentityStandardizesThePathAndFollowsUpdatesWithoutChangingTheRawPath() {
        var process = batch05Process(42)
        process.executablePath = "/Applications/Example.app/../Example.app/Contents/MacOS/Example"

        XCTAssertEqual(process.identity.executablePath, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(process.executablePath, "/Applications/Example.app/../Example.app/Contents/MacOS/Example")
        process.executablePath = "/usr/bin/other"
        XCTAssertEqual(process.identity.executablePath, "/usr/bin/other")
        process.executablePath = nil
        XCTAssertNil(process.identity.executablePath)
    }

    /// Identities are built for the whole inventory on the main actor at every
    /// list publish and engine tick, so reading one must not consult the file
    /// system. The path is standardized once, when it is set; standardizing
    /// drops a leading /private only while the shorter path exists.
    func testReadingAnIdentityDoesNotConsultTheFileSystem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let privatePath = "/private" + directory.appendingPathComponent("tool").path
        XCTAssertTrue(privatePath.hasPrefix("/private/var/"), privatePath)
        var process = batch05Process(42)
        process.executablePath = privatePath
        let identity = process.identity

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("tool").path, contents: Data()))
        XCTAssertNotEqual(
            URL(fileURLWithPath: privatePath).standardizedFileURL.path, privatePath,
            "Standardizing now gives another answer"
        )

        XCTAssertEqual(process.identity, identity)
    }

    /// With the comparison at `<`, every awake pass with an unchanged sleep
    /// total appended an observation, and the one that proved a sleep happened
    /// after an older process started was evicted.
    func testEqualSleepTotalsExtendTheObservationWithoutEvictingTheWake() throws {
        func ns(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }
        var history = ProcessAgeHistory(limit: 2)
        history.record(UptimeSample(uptime: ns(100), asleep: 0))
        history.record(UptimeSample(uptime: ns(200), asleep: ns(3600)))
        for value in stride(from: UInt64(300), through: 1000, by: 100) {
            history.record(UptimeSample(uptime: ns(value), asleep: ns(3600)))
        }

        let age = try XCTUnwrap(history.minimumAge(sinceUptime: ns(50), at: UptimeSample(uptime: ns(1000), asleep: ns(3600))))

        XCTAssertEqual(age, 4550)
    }
}

func batch05Process(_ pid: Int32) -> AppProcess {
    AppProcess(
        pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1,
        command: "Example", elapsedTime: "00:01", startTime: "Wed Oct 7 17:04:47 2026",
        netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
    )
}

private func shellResult(_ output: String, code: Int32 = 0, error: String = "") -> ShellCommandResult {
    ShellCommandResult(command: "fixture", stdout: output, stderr: error, exitCode: code)
}

func batch05Eventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

/// The task's value, or nil when it has not finished within ten seconds; the
/// task is then left suspended instead of hanging the test.
func batch05Value<Value: Sendable>(of task: Task<Value, Never>) async -> Value? {
    let box = Batch05Box<Value>()
    Task { box.store(await task.value) }
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if let value = box.value { return value }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return box.value
}

private final class Batch05Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func store(_ value: Value) {
        lock.withLock { stored = value }
    }

    var value: Value? { lock.withLock { stored } }
}

/// Answers each command with the next scripted result.
private actor Batch05ScriptedRunner {
    private var results: [ShellCommandResult]

    init(_ results: [ShellCommandResult]) {
        self.results = results
    }

    func run(_ command: String) -> ShellCommandResult {
        guard !results.isEmpty else { return shellResult("", code: 99, error: "Unexpected command: \(command)") }
        return results.removeFirst()
    }
}

/// Blocks its first read until released; later reads answer at once. Records
/// whether the blocked read saw its task cancelled.
actor Batch05BlockingUpstream: ProcessInventoryProviding {
    private var results: [[AppProcess]]
    private var calls = 0
    private var cancelledCalls = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?

    init(results: [[AppProcess]]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        let result = results.isEmpty ? [] : results.removeFirst()
        if calls == 1 {
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { gate = $0 }
            if Task.isCancelled {
                cancelledCalls += 1
                return .failure(.cancelled)
            }
        }
        return .success(result)
    }

    func waitUntilFirstCallStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        gate?.resume()
        gate = nil
    }

    func callCount() -> Int { calls }

    func cancelledCallCount() -> Int { cancelledCalls }
}

private actor Batch05CountingUpstream: ProcessInventoryProviding {
    private var modes: [Bool] = []

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        modes.append(fetchExtendedStats)
        return .success([])
    }

    func requestedModes() -> [Bool] { modes }
}

private final class Batch05Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 1_000

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}
