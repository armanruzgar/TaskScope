import Darwin
import XCTest
@testable import TaskScope

final class ShellInventoryRegressionTests: XCTestCase {
    func testTimedOutChildrenRetryReapingAfterEarlyExitNotifications() async {
        let completed = expectation(description: "timed-out children finish and are reaped")
        let probe = DeferredStopWaitProbe()
        let task = Task {
            await withTaskGroup(of: (Int, ShellCommandResult).self) { group in
                for index in 0..<24 {
                    group.addTask {
                        let result = await ShellCommandRunner.runShellScript(
                            "printf '%s' $$; exec /bin/sleep 5", timeout: 0.1,
                            waitForChild: { probe.wait(for: index, $0, $1, $2) }
                        )
                        return (index, result)
                    }
                }
                for await (index, result) in group {
                    XCTAssertEqual(result.exitCode, ShellCommandRunner.timedOutExitCode, result.stderr)
                    // Take the PID from the waitpid seam: on a loaded machine the
                    // timeout can stop the shell before it prints `$$`.
                    guard let pid = probe.childPID(of: index) else {
                        XCTFail("Each command must probe exactly one child PID")
                        continue
                    }
                    if !result.stdout.isEmpty {
                        XCTAssertEqual(result.stdout, String(pid), "The probed PID must be the shell's own")
                    }
                    XCTAssertTrue(probe.didReap(pid), "The runner must reap its child through the seam")
                    var status: Int32 = 0
                    errno = 0
                    XCTAssertEqual(Darwin.waitpid(pid, &status, WNOHANG), -1)
                    XCTAssertEqual(errno, ECHILD, "A stopped child must be reaped before completion")
                }
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        // Also clean up on the pre-fix failure: cancellation causes one more
        // probe, now allowed to reap, so this regression never leaves zombies.
        probe.release()
        task.cancel()
        await task.value
    }

    func testNegativeCacheAgeExpiresAndReplacesTheCachedRead() async throws {
        let clock = InventoryClock()
        let upstream = SequenceInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, now: { clock.now() })
        _ = await inventory.load(fetchExtendedStats: false)
        clock.advance(-3_600)

        let refreshed = await inventory.load(fetchExtendedStats: false)
        let reused = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(try refreshed.get().first?.pid, 2, "A negative cache age must expire")
        XCTAssertEqual(try reused.get().first?.pid, 2, "The post-step read must replace the old cache")
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testBackwardCacheStepAllowsExtendedReadToReplaceBasicRead() async throws {
        let clock = InventoryClock()
        let upstream = SequenceInventory()
        let inventory = CoalescingProcessInventory(upstream: upstream, now: { clock.now() })
        _ = await inventory.load(fetchExtendedStats: false)
        clock.advance(-3_600)
        let extended = await inventory.load(fetchExtendedStats: true)
        let basic = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(try extended.get().first?.pid, 2)
        XCTAssertEqual(try basic.get().first?.pid, 2, "Extended reads must replace a pre-step cache")
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testForwardCacheStepExpiresBasicAndExtendedReads() async throws {
        for extended in [false, true] {
            let clock = InventoryClock()
            let upstream = SequenceInventory()
            let inventory = CoalescingProcessInventory(upstream: upstream, now: { clock.now() })
            _ = await inventory.load(fetchExtendedStats: extended)
            clock.advance(3_600)
            let refreshed = await inventory.load(fetchExtendedStats: extended)
            let reused = await inventory.load(fetchExtendedStats: false)

            XCTAssertEqual(try refreshed.get().first?.pid, 2)
            XCTAssertEqual(try reused.get().first?.pid, 2)
            let calls = await upstream.callCount()
            XCTAssertEqual(calls, 2)
        }
    }

    func testMainProcessWaitIsAttemptBoundedAfterBackwardClockStep() async {
        let harness = ReadinessHarness(firstSleepStep: -3_600)
        let result = await waitForMain(using: harness)

        XCTAssertFalse(result)
        XCTAssertEqual(harness.sleepDurations.count, 3, "A backward step must not defeat the attempt bound")
        XCTAssertEqual(harness.inventoryLoads, 4)
    }

    func testMainProcessWaitHonorsForwardClockStep() async {
        let harness = ReadinessHarness(firstSleepStep: 3_600)
        let result = await waitForMain(using: harness)

        XCTAssertFalse(result)
        XCTAssertEqual(harness.sleepDurations.count, 1, "Elapsed time must end the wait")
        XCTAssertEqual(harness.inventoryLoads, 2)
    }

    func testMainProcessWaitCapsSleepByRemainingTime() async {
        let harness = ReadinessHarness()
        let result = await waitForMain(using: harness)

        XCTAssertFalse(result)
        XCTAssertEqual(harness.sleepDurations.count, 3)
        XCTAssertEqual(harness.sleepDurations.last.map { Double($0) } ?? 0, 50_000_000, accuracy: 1)
        XCTAssertEqual(harness.inventoryLoads, 4)
    }

    func testWatchedFilterRequiresCurrentUserForMainAndHelpers() {
        let filter = watchedQuery()
        for name in ["Main", "Worker"] {
            let path = "/Applications/Example.app/Contents/MacOS/\(name)"
            XCTAssertTrue(filter.matches(watchedProcess(name: name, path: path, uid: getuid())))
            for uid: uid_t? in [getuid() &+ 1, nil] {
                XCTAssertFalse(
                    filter.matches(watchedProcess(name: name, path: path, uid: uid)),
                    "Watched main/helper detection must require current-user ownership"
                )
            }
        }
        for uid: uid_t? in [getuid(), getuid() &+ 1, 0, nil] {
            XCTAssertTrue(filter.matches(watchedProcess(name: "Daemon", path: "/Library/Daemon", uid: uid)))
        }
    }

    func testWatchedMainRequiresMacOSDirectoryButHelpersUseContents() {
        let filter = watchedQuery()
        for name in ["Main", "renamed-main"] {
            XCTAssertTrue(filter.matches(watchedProcess(
                name: name, path: "/Applications/Example.app/Contents/MacOS/Main", uid: getuid()
            )))
            XCTAssertFalse(filter.matches(watchedProcess(
                name: name, path: "/Applications/Example.app/Contents/Helpers/Main", uid: getuid()
            )), "The main process must be inside Contents/MacOS")
        }
        for name in ["Worker", "renamed-helper"] {
            XCTAssertTrue(filter.matches(watchedProcess(
                name: name, path: "/Applications/Example.app/Contents/Helpers/Worker", uid: getuid()
            )))
            XCTAssertFalse(filter.matches(watchedProcess(
                name: name, path: "/Applications/Elsewhere.app/Contents/Helpers/Worker", uid: getuid()
            )))
        }
    }

    private func waitForMain(using harness: ReadinessHarness) async -> Bool {
        // Contain the pre-fix emergency cancellation in a child task.
        await Task {
            await ProcessLifecycleController.waitForProcessNamed(
                "Main", timeoutSeconds: 0.65,
                expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
                runtime: harness.runtime
            )
        }.value
    }

    private func watchedQuery() -> ProcessListQuery {
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Main", helperProcessNames: ["Worker"],
            protectedProcessNames: ["Daemon"], appPath: "/Applications/Example.app"
        )
        return ProcessListQuery(
            searchText: "", filterMode: .watched, watchedScopes: [WatchedProcessScope(preset: preset)],
            cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 500
        )
    }

    private func watchedProcess(name: String, path: String, uid: uid_t?) -> AppProcess {
        AppProcess(
            pid: 1234, parentPID: 1, uid: uid, cpu: 0, memoryMB: 0,
            command: name, executablePath: path, elapsedTime: "00:01", startTime: "start",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }
}

/// Defers each child's first eight probes, as when NOTE_EXIT precedes waitpid
/// readiness. Records the PIDs each command probes and the ones really reaped,
/// so the test never depends on the child printing before its timeout.
private final class DeferredStopWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [pid_t: Int] = [:]
    private var probedPIDs: [Int: Set<pid_t>] = [:]
    private var reapedPIDs: Set<pid_t> = []
    private var released = false

    func wait(
        for index: Int, _ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ options: Int32
    ) -> pid_t {
        let deferProbe = lock.withLock {
            probedPIDs[index, default: []].insert(pid)
            counts[pid, default: 0] += 1
            return !released && counts[pid, default: 0] <= 8
        }
        guard !deferProbe else { return 0 }
        let waitedPID = Darwin.waitpid(pid, status, options)
        if waitedPID == pid { lock.withLock { _ = reapedPIDs.insert(pid) } }
        return waitedPID
    }

    /// The command's child, or nil unless it probed exactly one PID.
    func childPID(of index: Int) -> pid_t? {
        lock.withLock { probedPIDs[index].flatMap { $0.count == 1 ? $0.first : nil } }
    }

    func didReap(_ pid: pid_t) -> Bool { lock.withLock { reapedPIDs.contains(pid) } }
    func release() { lock.withLock { released = true } }
}

private final class InventoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor SequenceInventory: ProcessInventoryProviding {
    private var calls: Int32 = 0

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        calls += 1
        return .success([AppProcess(
            pid: calls, parentPID: 1, uid: 501, cpu: 0, memoryMB: 0,
            command: "Snapshot\(calls)", elapsedTime: "00:01", startTime: "start",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )])
    }

    func callCount() -> Int32 { calls }
}

private final class ReadinessHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let firstSleepStep: TimeInterval
    private var uptime: TimeInterval = 1_000
    private var sleeps: [UInt64] = []
    private var loads = 0

    init(firstSleepStep: TimeInterval = 0) { self.firstSleepStep = firstSleepStep }

    var sleepDurations: [UInt64] { lock.withLock { sleeps } }
    var inventoryLoads: Int { lock.withLock { loads } }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { _ in false },
            launchAgentLabel: { _ in nil },
            runCommand: { command, _ in
                XCTFail("The readiness wait must not run commands")
                return ShellCommandResult(command: command, stdout: "", stderr: "unexpected", exitCode: 1)
            },
            loadProcessInventory: { [self] in
                lock.withLock { loads += 1 }
                return .success([])
            },
            executablePathForPID: { _ in nil },
            sendSignal: { _, _ in XCTFail("The readiness wait must not signal"); return false },
            isProcessAlive: { _ in false },
            sleep: { [self] duration in
                let count = recordSleep(duration)
                // Bound the old wall-clock loop without sleeping or changing
                // the real system clock; the fixed loop never reaches this.
                if count >= 20 { withUnsafeCurrentTask { $0?.cancel() } }
            },
            systemUptime: { [self] in lock.withLock { uptime } },
            isAppBundle: { _ in false }
        )
    }

    private func recordSleep(_ duration: UInt64) -> Int {
        lock.withLock {
            uptime += Double(duration) / 1_000_000_000
            if sleeps.isEmpty { uptime += firstSleepStep }
            sleeps.append(duration)
            return sleeps.count
        }
    }
}
