import UserNotifications
import XCTest
@testable import TaskScope

/// ProcessManager's notification decisions around its own lifecycle actions.
@MainActor
final class Batch09ProcessManagerNotificationTests: XCTestCase {
    private let preset = WatchedAppPreset(
        displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Example Helper"],
        protectedProcessNames: [], appPath: "/Applications/Example.app"
    )

    private func process(_ pid: Int32, _ name: String) -> AppProcess {
        AppProcess.fixture(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 1, memoryMB: 1,
            command: "/Applications/Example.app/Contents/MacOS/\(name)",
            executablePath: "/Applications/Example.app/Contents/MacOS/\(name)",
            elapsedTime: "01:00", startTime: "start-\(pid)", netInKB: nil, netOutKB: nil,
            diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    // A02-6: Quit is something the user just asked for and sees the result
    // of, so its reads re-baseline instead of announcing the stops. A later
    // external start is announced again.
    func testQuitDoesNotAnnounceTheProcessesItStopped() async {
        let inventory = Batch09MutableInventory([process(41, "Example"), process(42, "Example Helper")])
        let lifecycle = Batch09StoppingLifecycle(inventory: inventory)
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: FakeSignaler.forbidding("No process may be signalled"), lifecycle: lifecycle, settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = true
        manager.dependencies.watchedPresets = { [self.preset] }
        manager.refreshNotificationAuthorization = {}
        var calls: [String] = []
        manager.notifyTransitions = { calls.append("diff:\(Set($0.flatMap(\.runningNames)).sorted())") }
        manager.primeNotificationBaseline = { calls.append("prime:\(Set($0.flatMap(\.runningNames)).sorted())") }

        await manager.refreshWatchedStatus(showMessage: false)
        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(calls, ["prime:[\"Example\", \"Example Helper\"]", "diff:[\"Example\", \"Example Helper\"]"])

        _ = await manager.quitAll(preset)
        XCTAssertEqual(lifecycle.terminated, ["Example", "Example Helper"])
        XCTAssertEqual(calls.last, "prime:[]", "the post-quit read re-baselines")
        XCTAssertFalse(calls.dropFirst(2).contains { $0.hasPrefix("diff") })

        inventory.processes = [process(43, "Example")]
        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(calls.last, "diff:[\"Example\"]", "an external start is still announced")
    }

    // A02-7: each polling tick re-reads an authorization that could not
    // deliver before its read, but only while notifications are enabled.
    // Explicit refreshes do not, so they still join a read in flight.
    func testPollingTickReReadsAuthorizationOnlyWhenNotificationsAreOn() async throws {
        for enabled in [false, true] {
            let sleeper = Batch09OneTickSleeper()
            let manager = ProcessManager(
                processInventory: Batch09MutableInventory([]), verificationInventory: Batch09MutableInventory([]),
                processSignaler: FakeSignaler.forbidding("No process may be signalled"), lifecycle: Batch09StoppingLifecycle(inventory: nil),
                settleAfterProcessChange: {},
                pollingController: ProcessPollingController { await sleeper.sleep(interval: $0) },
                dependencies: .inert
            )
            manager.notifyTransitions = { _ in }
            manager.primeNotificationBaseline = { _ in }
            var reads = 0
            manager.refreshNotificationAuthorization = { reads += 1 }
            manager.enableNotifications = enabled

            await manager.refreshWatchedStatus(showMessage: false)
            XCTAssertEqual(reads, 0, "an explicit refresh reads no authorization")

            manager.setPolling(interval: 10, includeProcessList: false)
            for _ in 0..<400 {
                if await sleeper.requests >= 2 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let requests = await sleeper.requests
            XCTAssertEqual(requests, 2, "one tick ran")
            XCTAssertEqual(reads, enabled ? 1 : 0, "notifications enabled: \(enabled)")
            manager.setPolling(interval: 10, includeProcessList: false, backgroundActivity: false)
        }
    }
}

// MARK: - Fakes

private final class Batch09MutableInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [AppProcess]
    init(_ processes: [AppProcess]) { current = processes }
    var processes: [AppProcess] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

/// Stops the fixture processes by removing them from the fake inventory.
private final class Batch09StoppingLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    private let inventory: Batch09MutableInventory?
    private let lock = NSLock()
    private var names: [String] = []
    init(inventory: Batch09MutableInventory?) { self.inventory = inventory }
    var terminated: [String] { lock.withLock { names } }

    private func stop(_ name: String) -> ProcessTerminationOutcome {
        lock.withLock { names.append(name) }
        guard let inventory else { return .noMatchingProcesses }
        let before = inventory.processes
        inventory.processes = before.filter { $0.name != name }
        return before.count == inventory.processes.count ? .noMatchingProcesses : .signalled
    }

    func appBundleExists(at path: String) -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        XCTFail("No app may be opened")
        return .failed("fixture")
    }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        stop(preset.mainProcessName)
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        stop(name)
    }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        .notNeeded
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        .notNeeded
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        .notNeeded
    }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
}

/// Lets the polling controller run exactly one tick: the first sleep returns
/// at once, every later one ends polling.
private actor Batch09OneTickSleeper {
    private(set) var requests = 0
    func sleep(interval: TimeInterval) -> Bool {
        requests += 1
        return requests == 1
    }
}
