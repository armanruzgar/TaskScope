import Darwin
import XCTest
@testable import TaskScope

/// Drives ProcessManager wired exactly like TaskScopeApp.init
/// (shared CoalescingProcessInventory for lists and observers, an uncached
/// inventory for verification) through a real single-process Stop. Every
/// collaborator is a fake: nothing is signalled for real.
@MainActor
final class Batch03CacheInvalidationTests: XCTestCase {
    func testStopInvalidatesSharedCacheForQueuedListReadAndOutsideObservers() async throws {
        let target = batch03Process(pid: 4242, name: "Target")
        let survivor = batch03Process(pid: 4343, name: "Survivor")
        let world = Batch03World([target, survivor])
        // Long maximum age so the test does not depend on wall-clock timing;
        // production uses 0.5 s.
        let shared = CoalescingProcessInventory(upstream: world, maximumAge: 60)
        let manager = ProcessManager(
            processInventory: shared,
            verificationInventory: world,
            processSignaler: Batch03Signaler(world: world),
            lifecycle: Batch03Lifecycle(),
            settleAfterProcessChange: {},
            currentPID: 999_999,
            dependencies: .inert
        )
        manager.enableNotifications = false

        await manager.loadProcessList(showMessage: false)
        XCTAssertEqual(Set(manager.displayProcesses().map(\.pid)), [4242, 4343])

        let result = await manager.terminate(target)
        XCTAssertEqual(result, .stopped)
        // The manager's own post-mutation refresh is uncached.
        XCTAssertEqual(manager.displayProcesses().map(\.pid), [4343])

        // A later list read (a poll queued behind the Stop) goes through the
        // shared cache and must not resurrect the stopped row.
        await manager.loadProcessList(showMessage: false)
        XCTAssertEqual(manager.displayProcesses().map(\.pid), [4343],
                       "a list read after Stop was served the pre-stop cached list")

        // An observer outside the gate (auto-stop engine, history sampler).
        let observed = try await shared.load(fetchExtendedStats: false).get()
        XCTAssertEqual(observed.map(\.pid), [4343],
                       "an observer of the shared cache was served the pre-stop list")
    }
}

func batch03Process(pid: Int32, name: String) -> AppProcess {
    AppProcess.fixture(
        pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0,
        command: "/Applications/\(name).app/Contents/MacOS/\(name)",
        executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
        elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
        netInKB: 0, netOutKB: 0, diskReadBytes: 0, diskWriteBytes: 0
    )
}

/// The "kernel": an inventory whose rows disappear when a fake signal lands.
final class Batch03World: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AppProcess]
    private var loads = 0

    init(_ rows: [AppProcess]) { self.rows = rows }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            loads += 1
            return .success(rows)
        }
    }

    func remove(_ pid: Int32) { lock.withLock { rows.removeAll { $0.pid == pid } } }
    func contains(_ pid: Int32) -> Bool { lock.withLock { rows.contains { $0.pid == pid } } }
    var loadCount: Int { lock.withLock { loads } }
}

final class Batch03Signaler: ProcessSignaling, @unchecked Sendable {
    private let world: Batch03World
    init(world: Batch03World) { self.world = world }
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        world.remove(pid)
        return true
    }
    func isAlive(_ pid: Int32) -> Bool { world.contains(pid) }
}

actor Batch03Lifecycle: ProcessLifecycleServicing {
    private(set) var calls: [String] = []
    nonisolated func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async { calls.append("settle") }
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        calls.append("terminate.main"); return .signalled
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        calls.append("terminate.helper"); return .signalled
    }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { true }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.unload"); return .notNeeded
    }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        calls.append("agents.unload"); return .notNeeded
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.bootstrap"); return .notNeeded
    }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        calls.append("agents.disable"); return .notNeeded
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("agents.enable"); return .notNeeded
    }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("daemons.ensure"); return .notNeeded
    }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        calls.append("daemons.disable"); return .notNeeded
    }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        calls.append("daemons.enable"); return .notNeeded
    }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { calls.append("open"); return .opened }
}
