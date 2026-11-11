import Darwin
import XCTest
@testable import TaskScope

/// The shared fakes in Support/ (L07-8, T01-15) do what tests rely on: strict
/// by default, explicit when lenient.
final class SharedFakesTests: XCTestCase {
    // MARK: ScriptedInventory

    func testInventoryReturnsTheScriptInOrderAndCountsReads() async {
        let first = AppProcess.fixture(pid: 10, name: "First")
        let inventory = ScriptedInventory([.success([first]), .failure(.parseFailed)])

        let read1 = await inventory.load(fetchExtendedStats: true)
        let read2 = await inventory.load(fetchExtendedStats: false)

        XCTAssertEqual(try read1.get().map(\.pid), [10])
        XCTAssertEqual(read2, .failure(.parseFailed))
        XCTAssertEqual(inventory.readCount, 2)
        XCTAssertEqual(inventory.extendedStatsRequests, [true, false])
    }

    func testAReadPastTheScriptFailsTheTest() async {
        let inventory = ScriptedInventory([.success([])])
        _ = await inventory.load(fetchExtendedStats: false)

        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("read 2 was not scripted") }
        XCTExpectFailure("An unscripted read must fail the test", options: options)
        let extra = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(extra, .failure(.commandFailed("The test did not script this process inventory read.")))
    }

    func testRepeatsLastReplaysOnlyWhenAskedFor() async {
        let inventory = ScriptedInventory([.success([]), .failure(.cancelled)], repeatsLast: true)
        _ = await inventory.load(fetchExtendedStats: false)
        for _ in 0..<3 {
            let replay = await inventory.load(fetchExtendedStats: false)
            XCTAssertEqual(replay, .failure(.cancelled))
        }

        let fixed = ScriptedInventory(processes: [.fixture(pid: 7)])
        for _ in 0..<3 {
            let read = await fixed.load(fetchExtendedStats: false)
            XCTAssertEqual(try read.get().map(\.pid), [7])
        }
        fixed.setProcesses([])
        let emptied = await fixed.load(fetchExtendedStats: false)
        XCTAssertEqual(try emptied.get(), [])
    }

    func testAHeldReadWaitsForItsRelease() async {
        let inventory = ScriptedInventory([.success([.fixture(pid: 1)]), .success([])], holding: [1])
        let first = Task { await inventory.load(fetchExtendedStats: false) }
        await inventory.waitForRead(1)

        let second = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try second.get(), [], "Only the held read waits")
        XCTAssertEqual(inventory.readCount, 2)

        inventory.release(read: 1)
        let released = await first.value
        XCTAssertEqual(try released.get().map(\.pid), [1])
    }

    func testAReadReleasedBeforeItStartsDoesNotWait() async {
        let inventory = ScriptedInventory([.success([])], holding: [1])
        inventory.release(read: 1)
        let read = await inventory.load(fetchExtendedStats: false)
        XCTAssertEqual(try read.get(), [])
    }

    // MARK: FakeSignaler

    func testSignalerRecordsEveryRequestAndAnswersPerPID() {
        let signaler = FakeSignaler(alive: [1, 2, 3], rejected: [2], missing: [3])

        XCTAssertEqual(signaler.deliver(SIGTERM, to: 1), .delivered)
        XCTAssertEqual(signaler.deliver(SIGTERM, to: 2), .rejected(errno: EPERM))
        XCTAssertEqual(signaler.deliver(SIGKILL, to: 3), .noSuchProcess)
        XCTAssertFalse(signaler.send(SIGTERM, to: 2))
        signaler.reject(1, errno: EINVAL)
        XCTAssertEqual(signaler.deliver(SIGKILL, to: 1), .rejected(errno: EINVAL))

        XCTAssertEqual(signaler.sent, [
            .init(signal: SIGTERM, pid: 1), .init(signal: SIGTERM, pid: 2), .init(signal: SIGKILL, pid: 3),
            .init(signal: SIGTERM, pid: 2), .init(signal: SIGKILL, pid: 1)
        ])
        XCTAssertTrue(signaler.isAlive(1))
        XCTAssertFalse(signaler.isAlive(3), "A missing PID is not alive")
        XCTAssertFalse(signaler.isAlive(4))
    }

    func testTargetsExitOnlyOnTheConfiguredSignal() {
        let onTerm = FakeSignaler(alive: [5], exitsOnTerminate: true)
        XCTAssertTrue(onTerm.send(SIGKILL, to: 5))
        XCTAssertTrue(onTerm.isAlive(5), "SIGKILL does not end it")
        XCTAssertTrue(onTerm.send(SIGTERM, to: 5))
        XCTAssertFalse(onTerm.isAlive(5))
        XCTAssertTrue(onTerm.send(SIGKILL, to: 5), "Later signals are still reported delivered")

        let onKill = FakeSignaler(everyPIDAlive: true, exitsOnKill: true)
        XCTAssertTrue(onKill.isAlive(99))
        _ = onKill.send(SIGTERM, to: 99)
        XCTAssertTrue(onKill.isAlive(99))
        _ = onKill.send(SIGKILL, to: 99)
        XCTAssertFalse(onKill.isAlive(99))
        onKill.setAlive(99, true)
        XCTAssertTrue(onKill.isAlive(99))
    }

    // MARK: FakeLifecycle

    func testAnUnstubbedLifecycleCallFailsTheTestAndFailsClosed() async {
        let lifecycle = FakeLifecycle()
        let preset = WatchedAppPreset.fixture()

        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("Unexpected lifecycle call") }
        XCTExpectFailure("An unstubbed call must fail the test", options: options)
        let outcome = await lifecycle.terminateMainProcess(for: preset)
        let agents = await lifecycle.disableUserLaunchAgents(for: preset, preservingVPNService: true)

        XCTAssertEqual(outcome, .inventoryUnavailable)
        XCTAssertFalse(agents.succeeded)
        XCTAssertEqual(lifecycle.calls, ["terminate:Example", "agents.disable"])
        XCTAssertEqual(lifecycle.preservedVPNServices, [true])
    }

    func testAllSucceedingAnswersEveryCallAndRecordsIt() async {
        let lifecycle = FakeLifecycle.allSucceeding()
        let preset = WatchedAppPreset.fixture()

        let outcomes = await lifecycle.terminateProcesses(for: preset, scope: .all)
        let unloaded = await lifecycle.unloadUserLaunchAgents(for: preset, preservingPIDs: [42])
        let disabled = await lifecycle.disableSystemLaunchDaemons(for: preset, allowAdministratorPrompt: false)
        let opened = await lifecycle.openAppBundle(at: preset.appPath)
        await lifecycle.settleAfterProcessChange()

        XCTAssertEqual(outcomes, [.signalled, .signalled])
        XCTAssertEqual(unloaded, .notNeeded)
        XCTAssertEqual(disabled, .notNeeded)
        XCTAssertEqual(opened, .opened)
        XCTAssertTrue(lifecycle.appBundleExists(at: preset.appPath))
        XCTAssertEqual(lifecycle.calls, [
            "terminate:Example", "terminate.helper:ExampleHelper", "agents.unload",
            "daemon.disable:false", "open", "settle", "exists"
        ])
        XCTAssertEqual(lifecycle.preservedPIDs, [[42]])
        XCTAssertEqual(lifecycle.presetsByCall["terminate"]?.map(\.id), [preset.id])
    }

    func testAStubAnswersForItsCallOnly() async {
        let lifecycle = FakeLifecycle()
        lifecycle.daemonsResult = .notNeeded
        lifecycle.waitResult = false
        let preset = WatchedAppPreset.fixture()

        let ensured = await lifecycle.ensureSystemLaunchDaemons(for: preset)
        let waited = await lifecycle.waitForMainProcess(for: preset, timeoutSeconds: 1)

        XCTAssertEqual(ensured, .notNeeded)
        XCTAssertFalse(waited)
        XCTAssertEqual(lifecycle.calls, ["daemon", "wait"])
    }

    // MARK: ProcessLifecycleRuntime.fake

    func testRuntimeMembersTheTestDidNotProvideFailTheTest() async {
        let runtime = ProcessLifecycleRuntime.fake(fileExists: { $0 == "/exists" })
        XCTAssertTrue(runtime.fileExists("/exists"))

        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("Unexpected runtime call") }
        XCTExpectFailure("An unprovided member must fail the test", options: options)
        let signalled = runtime.sendSignal(SIGTERM, 4242)
        let command = await runtime.runCommand(.launchctl("print", "gui/501"), 1)

        XCTAssertFalse(signalled, "An unprovided signal is never reported sent")
        XCTAssertFalse(command.succeeded)
    }

    // MARK: AppProcess.fixture

    func testProcessFixtureDefaultsMatchTheModelInitializer() {
        let process = AppProcess.fixture(pid: 42, name: "Safari")
        XCTAssertEqual(process.pid, 42)
        XCTAssertEqual(process.parentPID, 1)
        XCTAssertEqual(process.name, "Safari")
        XCTAssertEqual(process.command, "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertNil(process.uid)
        XCTAssertNil(process.executablePath)
        XCTAssertEqual(process.startTime, "")
        XCTAssertNil(process.netInKB)

        let full = AppProcess.fixture(pid: 43, uid: 501, command: "/bin/sleep", executablePath: "/bin/sleep", startTime: "start")
        XCTAssertEqual(full, AppProcess(
            pid: 43, parentPID: 1, uid: 501, cpu: 0, memoryMB: 0, command: "/bin/sleep", executablePath: "/bin/sleep",
            elapsedTime: "00:01", startTime: "start", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        ))
    }
}
