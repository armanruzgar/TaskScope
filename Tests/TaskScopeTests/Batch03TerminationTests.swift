import Darwin
import Foundation
import XCTest
@testable import TaskScope

/// Preset stops through an injected runtime. The "kernel" is a closure: the
/// runtime records every signal and nothing is sent to a real process.
final class Batch03TerminationTests: XCTestCase {
    private let main = batch03Process(pid: 42, name: "Example")
    private let helperOne = batch03Helper(pid: 43, name: "HelperOne")
    private let helperTwo = batch03Helper(pid: 44, name: "HelperTwo")

    private var preset: WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example",
            helperProcessNames: ["HelperOne", "HelperTwo"], protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
    }

    /// Before, every helper name had its own graceful window and two reads, so
    /// targets that ignore SIGTERM held the action open for 3 s per name. The
    /// main process is still stopped first, on its own.
    func testPresetStopStopsTheMainProcessFirstThenGivesHelpersOneSharedWindow() async {
        let world = Batch03TerminationWorld(rows: [main, helperOne, helperTwo])

        let outcomes = await ProcessLifecycleController.terminateProcesses(
            for: preset, scope: .all, currentPID: 999_999, runtime: world.runtime
        )

        XCTAssertEqual(outcomes, [.signalled, .signalled, .signalled])
        XCTAssertEqual(world.signals.map(\.signal), [SIGTERM, SIGKILL, SIGTERM, SIGTERM, SIGKILL, SIGKILL])
        XCTAssertEqual(world.signals.map(\.pid), [42, 42, 43, 44, 43, 44])
        XCTAssertEqual(world.readCount, 4, "one read before and after each of the two windows")
        XCTAssertEqual(world.sleepCount, 24, "two three-second windows of 250 ms polls")
    }

    /// Helpers that shut down with the main process are never signalled.
    func testHelpersThatExitWithTheMainProcessAreNeverSignalled() async {
        let world = Batch03TerminationWorld(
            rows: [main, helperOne, helperTwo],
            exitOnSignal: [42: [42, 43, 44]]
        )

        let outcomes = await ProcessLifecycleController.terminateProcesses(
            for: preset, scope: .all, currentPID: 999_999, runtime: world.runtime
        )

        XCTAssertEqual(outcomes, [.signalled, .noMatchingProcesses, .noMatchingProcesses])
        XCTAssertEqual(world.signals.map(\.signal), [SIGTERM])
        XCTAssertEqual(world.signals.map(\.pid), [42])
    }

    func testScopesLimitWhichNamesAreStopped() async {
        let appWorld = Batch03TerminationWorld(rows: [main, helperOne, helperTwo], exitOnSignal: [42: [42]])
        let app = await ProcessLifecycleController.terminateProcesses(
            for: preset, scope: .app, currentPID: 999_999, runtime: appWorld.runtime
        )
        XCTAssertEqual(app, [.signalled])
        XCTAssertEqual(appWorld.signals.map(\.pid), [42])

        let helperWorld = Batch03TerminationWorld(
            rows: [main, helperOne, helperTwo], exitOnSignal: [43: [43], 44: [44]]
        )
        let helpers = await ProcessLifecycleController.terminateProcesses(
            for: preset, scope: .helpers, currentPID: 999_999, runtime: helperWorld.runtime
        )
        XCTAssertEqual(helpers, [.signalled, .signalled])
        XCTAssertEqual(helperWorld.signals.map(\.pid), [43, 44])
        XCTAssertEqual(helperWorld.readCount, 2)
    }

    /// The service's stop goes through its own injected runtime, never the
    /// live one, and keeps the main-first order.
    func testServiceStopsThroughItsInjectedRuntime() async {
        let world = Batch03TerminationWorld(
            rows: [main, helperOne, helperTwo], exitOnSignal: [42: [42], 43: [43], 44: [44]]
        )
        let service = SystemProcessLifecycleService(runtime: world.runtime)

        let outcomes = await service.terminateProcesses(for: preset, scope: .all)

        XCTAssertEqual(outcomes, [.signalled, .signalled, .signalled])
        XCTAssertEqual(world.signals.map(\.signal), [SIGTERM, SIGTERM, SIGTERM])
        XCTAssertEqual(world.signals.map(\.pid), [42, 43, 44])
        XCTAssertEqual(world.readCount, 4)
    }

    func testUnreadableInitialInventoryNeverSignals() async {
        let world = Batch03TerminationWorld(rows: [main], failsRead: true)

        let result = await ProcessTerminationController.terminate(
            named: "Example", policy: .gracefulThenForce,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            excludingPID: 999_999, runtime: world.runtime
        )

        XCTAssertEqual(result, .inventoryUnavailable)
        XCTAssertTrue(world.signals.isEmpty)
        XCTAssertEqual(world.readCount, 1)
    }

    func testGroupedOutcomesKeepRejectionAndMissingNamesSeparate() async {
        let world = Batch03TerminationWorld(rows: [helperOne], rejectsSignals: true)

        let results = await ProcessTerminationController.terminate(
            requests: [
                .init(name: "HelperOne", expectedExecutableDirectory: "/Applications/Example.app/Contents/"),
                .init(name: "Missing", expectedExecutableDirectory: "/Applications/Example.app/Contents/")
            ],
            policy: .gracefulThenForce, excludingPID: 999_999, runtime: world.runtime
        )

        XCTAssertEqual(results, [.signalRejected, .noMatchingProcesses])
        XCTAssertEqual(world.signals.map(\.signal), [SIGTERM, SIGKILL])
    }

    /// A process that two requested names both match is signalled once.
    func testAProcessMatchedByTwoNamesIsSignalledOnce() async {
        let world = Batch03TerminationWorld(rows: [helperOne])
        let request = ProcessTerminationController.Request(
            name: "HelperOne", expectedExecutableDirectory: "/Applications/Example.app/Contents/"
        )

        let results = await ProcessTerminationController.terminate(
            requests: [request, request], policy: .gracefulThenForce,
            excludingPID: 999_999, runtime: world.runtime
        )

        XCTAssertEqual(results, [.signalled, .signalled])
        XCTAssertEqual(world.signals.map(\.signal), [SIGTERM, SIGKILL])
    }
}

private func batch03Helper(pid: Int32, name: String) -> AppProcess {
    var row = batch03Process(pid: pid, name: name)
    row.command = "/Applications/Example.app/Contents/Helpers/\(name)"
    row.executablePath = row.command
    return row
}

private final class Batch03TerminationWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AppProcess]
    private let failsRead: Bool
    private let rejectsSignals: Bool
    /// A signalled PID and the PIDs that exit as soon as it receives any
    /// signal. Without an entry a target ignores SIGTERM and exits on SIGKILL.
    private let exitOnSignal: [Int32: Set<Int32>]
    private var reads = 0
    private var sleeps = 0
    private var sent: [(signal: Int32, pid: Int32)] = []

    init(
        rows: [AppProcess],
        failsRead: Bool = false,
        rejectsSignals: Bool = false,
        exitOnSignal: [Int32: Set<Int32>] = [:]
    ) {
        self.rows = rows
        self.failsRead = failsRead
        self.rejectsSignals = rejectsSignals
        self.exitOnSignal = exitOnSignal
    }

    var readCount: Int { lock.withLock { reads } }
    var sleepCount: Int { lock.withLock { sleeps } }
    var signals: [(signal: Int32, pid: Int32)] { lock.withLock { sent } }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime.fake(
            userID: getuid(),
            fileExists: { _ in false },
            launchAgentLabel: { _ in nil },
            runCommand: { command, _ in
                ShellCommandResult(command: command, stdout: "", stderr: "unexpected", exitCode: 1)
            },
            loadProcessInventory: { [self] in
                lock.withLock {
                    reads += 1
                    return failsRead ? .failure(.commandFailed("ps failed")) : .success(rows)
                }
            },
            executablePathForPID: { [self] pid in
                lock.withLock { rows.first { $0.pid == pid }?.executablePath }
            },
            sendSignal: { [self] signal, pid in
                lock.withLock {
                    sent.append((signal, pid))
                    guard !rejectsSignals else { return false }
                    let exiting = exitOnSignal[pid] ?? (signal == SIGKILL ? [pid] : [])
                    rows.removeAll { exiting.contains($0.pid) }
                    return true
                }
            },
            isProcessAlive: { [self] pid in
                lock.withLock { rows.contains { $0.pid == pid } }
            },
            sleep: { [self] _ in lock.withLock { sleeps += 1 } },
            systemUptime: { 0 },
            isAppBundle: { _ in false }
        )
    }
}
