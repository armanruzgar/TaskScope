import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2 (app shell, launch contexts, window
// handling, quitting during actions). Every AppKit effect goes through a
// recording AppDelegate.Runtime: no activation policy, window, URL handler,
// Accessibility setting or termination reaches the real application.

// MARK: - Shared fakes

// MARK: - Quitting during an action (A01-4)

@MainActor
final class Batch02QuitTests: XCTestCase {
    private let notification = Notification(name: NSApplication.willFinishLaunchingNotification)

    private func launchedDelegate(
        _ recorder: Batch02DelegateRecorder,
        waitForTerminationTick: @escaping @MainActor () async -> Void = { await Task.yield() },
        terminationWaitTicks: Int = 50
    ) -> (AppDelegate, TaskScopeLaunchSession) {
        let session = makeBatch02Session(.loginItem)
        let delegate = makeBatch02Delegate(
            session, recorder, launchedAsLoginItem: true,
            waitForTerminationTick: waitForTerminationTick, terminationWaitTicks: terminationWaitTicks
        )
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        return (delegate, session)
    }

    func testQuitWithNothingInFlightTerminatesAtOnce() {
        let recorder = Batch02DelegateRecorder()
        let (delegate, session) = launchedDelegate(recorder)
        defer { session.cleanUp() }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(recorder.count("stop runtime"), 0)
        XCTAssertEqual(recorder.count("stop running commands"), 0, "Will-terminate stops what is left")
        XCTAssertEqual(recorder.replies, [])
    }

    func testQuitDuringAnActionWaitsForItThenStopsRunningCommands() async {
        let recorder = Batch02DelegateRecorder()
        recorder.mutationActive = true
        var ticks = 0
        let (delegate, session) = launchedDelegate(recorder, waitForTerminationTick: {
            ticks += 1
            if ticks == 3 { recorder.mutationActive = false }
            await Task.yield()
        })
        defer { session.cleanUp() }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(recorder.count("stop runtime"), 1, "No new polling or Auto Stop work while quitting")
        XCTAssertEqual(recorder.replies, [], "The quit waits for the action")
        for _ in 0..<200 where recorder.replies.isEmpty { await Task.yield() }

        XCTAssertEqual(ticks, 3, "The quit continues as soon as the action finished")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("stop") }, ["stop runtime", "stop running commands"])
        XCTAssertEqual(recorder.replies, [true])
    }

    func testQuitDuringAStuckActionIsBounded() async {
        let recorder = Batch02DelegateRecorder()
        recorder.mutationActive = true
        var ticks = 0
        let (delegate, session) = launchedDelegate(
            recorder, waitForTerminationTick: { ticks += 1; await Task.yield() }, terminationWaitTicks: 7
        )
        defer { session.cleanUp() }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        for _ in 0..<500 where recorder.replies.isEmpty { await Task.yield() }

        XCTAssertEqual(ticks, 7, "A stuck action delays quit or logout only for the bounded wait")
        XCTAssertEqual(recorder.count("stop running commands"), 1, "Its administrator prompt or launchctl is stopped")
        XCTAssertEqual(recorder.replies, [true])
    }

    func testARepeatedQuitRequestWhileWaitingIsAnsweredOnce() async {
        let recorder = Batch02DelegateRecorder()
        recorder.mutationActive = true
        let gate = Batch02Gate()
        let (delegate, session) = launchedDelegate(recorder, waitForTerminationTick: { await gate.wait() })
        defer { session.cleanUp() }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        recorder.mutationActive = false
        await gate.open()
        for _ in 0..<200 where recorder.replies.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(recorder.replies, [true])
        XCTAssertEqual(recorder.count("stop runtime"), 1)
        XCTAssertEqual(recorder.count("stop running commands"), 1)
    }

    /// The deferral reads the real operation gate: a Keep Off waiting at its
    /// administrator step holds the quit until the step returns.
    func testQuitDuringARealKeepOffWaitsForItsAdministratorStep() async {
        let lifecycle = Batch02BlockingLifecycle()
        let inventory = ScriptedInventory([.success([])], repeatsLast: true)
        let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory,
                                     processSignaler: FakeSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {}, dependencies: .inert)
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [.globalProtect] }
        manager.dependencies.isKeepOffIntentWritable = { true }

        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.loginItem)
        defer { session.cleanUp() }
        let delegate = AppDelegate(
            launchSession: session, commandBus: AppCommandBus(),
            terminationHandler: TaskScopeTerminationHandler(install: { _ in {} }, terminate: {}),
            runtime: .init(
                launchSignal: { .init(arguments: ["TaskScope"], launchedAsLoginItem: true, receivedOpenURL: false) },
                isActive: { false }, setActivationPolicy: { _ in },
                registerURLHandler: { _ in }, configureAccessibility: {}, registerHotkey: {},
                hideAutomaticWindows: {}, restorePreviousApplication: {}, presentMainWindow: {},
                waitForInteractiveLaunch: {},
                isMutationActive: { manager.isMutationActive },
                stopRunningCommands: { recorder.events.append("stop running commands") },
                replyToTermination: { recorder.replies.append($0) },
                waitForTerminationTick: { try? await Task.sleep(nanoseconds: 5_000_000) },
                terminationWaitTicks: 1_000
            )
        )

        let keepOff = Task { @MainActor in await manager.keepOff(.globalProtect) }
        await lifecycle.waitUntilSystemDisableEntered()
        XCTAssertTrue(manager.isMutationActive)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(recorder.replies, [], "Quit waits while the administrator step is pending")

        await lifecycle.releaseSystemDisable()
        _ = await keepOff.value
        for _ in 0..<400 where recorder.replies.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertFalse(manager.isMutationActive)
        XCTAssertEqual(recorder.replies, [true])
        XCTAssertEqual(recorder.events, ["stop running commands"])
    }
}

// MARK: - Lifecycle fakes

/// Holds Keep Off at its system-daemon (administrator) step until released.
actor Batch02BlockingLifecycle: ProcessLifecycleServicing {
    private var systemEntered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult { .disconnected }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        .notNeeded
    }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        systemEntered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { release = $0 }
        return .notNeeded
    }
    func waitUntilSystemDisableEntered() async {
        if systemEntered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func releaseSystemDisable() {
        release?.resume()
        release = nil
    }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        .signalled
    }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        .notNeeded
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    nonisolated func appBundleExists(at path: String) -> Bool { false }
    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        XCTFail("No launch is permitted")
        return .failed("No launch is permitted")
    }
}
