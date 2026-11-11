import UserNotifications
import XCTest
@testable import TaskScope

/// Notification delivery through the service's test seams: no request ever
/// reaches UNUserNotificationCenter.
@MainActor
final class Batch09NotificationDeliveryTests: XCTestCase {
    private let slack = WatchedAppPreset(
        displayName: "Slack", mainProcessName: "Slack",
        helperProcessNames: ["Slack Helper", "Slack Helper (GPU)", "Slack Helper (Renderer)"],
        protectedProcessNames: [], appPath: "/Applications/Slack.app"
    )
    private let zoom = WatchedAppPreset(
        displayName: "Zoom", mainProcessName: "zoom.us", helperProcessNames: [],
        protectedProcessNames: [], appPath: "/Applications/zoom.us.app"
    )

    private func service(
        _ state: NotificationService.AuthorizationState,
        isAvailable: Bool = true,
        delivered: @escaping (UNNotificationRequest) -> Void
    ) -> NotificationService {
        NotificationService(
            isAvailable: isAvailable, authorizationState: state,
            readAuthorization: { state }, deliver: { delivered($0) }
        )
    }

    // T04-14: the started/stopped mapping, the text and the request.
    func testAuthorizedServicePostsTheStartAndStopOfEachProcess() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        service.prime([WatchedAppSnapshot(preset: slack, runningNames: ["Slack Helper"])])

        service.diffAndNotify([WatchedAppSnapshot(preset: slack, runningNames: ["Slack"])])

        XCTAssertEqual(requests.map(\.content.title), ["Process Started", "Process Stopped"])
        XCTAssertEqual(requests.map(\.content.body), ["Slack is now running.", "Slack Helper is no longer running."])
        XCTAssertEqual(requests.map(\.identifier), [
            "TaskScope.watched.\(slack.id.uuidString).started",
            "TaskScope.watched.\(slack.id.uuidString).stopped"
        ])
        XCTAssertEqual(Set(requests.map(\.content.threadIdentifier)), ["TaskScope.watched.\(slack.id.uuidString)"])
        XCTAssertTrue(requests.allSatisfy { $0.trigger == nil })
    }

    func testProvisionalAuthorizationAlsoDelivers() {
        var requests: [UNNotificationRequest] = []
        let service = service(.provisional) { requests.append($0) }
        service.prime([WatchedAppSnapshot(preset: zoom, runningNames: [])])
        service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"])])
        XCTAssertEqual(requests.map(\.content.body), ["zoom.us is now running."])
    }

    func testUndeliverableOrUnavailableServicesPostNothing() {
        for (state, available) in [(NotificationService.AuthorizationState.denied, true), (.notDetermined, true),
                                   (.unknown, true), (.authorized, false)] {
            var requests: [UNNotificationRequest] = []
            let service = service(state, isAvailable: available) { requests.append($0) }
            service.prime([WatchedAppSnapshot(preset: zoom, runningNames: [])])
            service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"])])
            service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: [])])
            XCTAssertTrue(requests.isEmpty, "\(state), available: \(available)")
        }
    }

    // A02-6: one request per preset and direction, not one per process name.
    func testAPresetWhoseProcessesAllStopProducesOneNotification() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        let everything: Set<String> = ["Slack", "Slack Helper", "Slack Helper (GPU)", "Slack Helper (Renderer)"]
        service.prime([WatchedAppSnapshot(preset: slack, runningNames: everything)])

        service.diffAndNotify([WatchedAppSnapshot(preset: slack, runningNames: [])])

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.title, "Processes Stopped")
        XCTAssertEqual(
            requests.first?.content.body,
            "Slack, Slack Helper, Slack Helper (GPU), and Slack Helper (Renderer) are no longer running."
        )
    }

    func testPresetsAreAnnouncedSeparatelyAndDisabledPresetsNotAtAll() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        var muted = zoom
        muted.id = UUID()
        muted.notificationsEnabled = false
        service.prime([
            WatchedAppSnapshot(preset: slack, runningNames: []),
            WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"]),
            WatchedAppSnapshot(preset: muted, runningNames: [])
        ])

        service.diffAndNotify([
            WatchedAppSnapshot(preset: slack, runningNames: ["Slack", "Slack Helper"]),
            WatchedAppSnapshot(preset: zoom, runningNames: []),
            WatchedAppSnapshot(preset: muted, runningNames: ["zoom.us"])
        ])

        XCTAssertEqual(requests.map(\.content.body), [
            "Slack and Slack Helper are now running.",
            "zoom.us is no longer running."
        ])
        XCTAssertEqual(requests.map(\.content.threadIdentifier), [
            "TaskScope.watched.\(slack.id.uuidString)", "TaskScope.watched.\(zoom.id.uuidString)"
        ])
    }

    // A02-6 with batch 7's A09-5: presets that share a process name are
    // diffed apart, and the shared name is shown with the preset's name.
    func testPresetsSharingAProcessNameAreAnnouncedApart() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        let downloader = WatchedAppPreset(
            displayName: "JDownloader2", mainProcessName: "JavaApplicationStub", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/JDownloader2.app"
        )
        let rocket = WatchedAppPreset(
            displayName: "OpenRocket", mainProcessName: "JavaApplicationStub", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/OpenRocket.app"
        )
        service.prime([
            WatchedAppSnapshot(preset: downloader, runningNames: ["JavaApplicationStub"]),
            WatchedAppSnapshot(preset: rocket, runningNames: ["JavaApplicationStub"])
        ])

        service.diffAndNotify([
            WatchedAppSnapshot(preset: downloader, runningNames: []),
            WatchedAppSnapshot(preset: rocket, runningNames: ["JavaApplicationStub"])
        ])

        XCTAssertEqual(requests.map(\.content.body), ["JDownloader2: JavaApplicationStub is no longer running."])
        XCTAssertEqual(requests.map(\.identifier), ["TaskScope.watched.\(downloader.id.uuidString).stopped"])
    }

    // A02-7: an authorization granted in System Settings is picked up before
    // the next diff instead of only at the next app activation.
    func testUndeliverableStateIsReReadAndADeliverableOneIsNot() async {
        var reads = 0
        var current = NotificationService.AuthorizationState.denied
        let service = NotificationService(
            isAvailable: true, authorizationState: .denied,
            readAuthorization: { reads += 1; return current }, deliver: { _ in }
        )

        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(service.authorizationState, .denied)

        current = .authorized
        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(service.authorizationState, .authorized)
        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(reads, 2, "nothing is read while delivery is possible")
    }
}

/// ProcessManager's notification decisions around its own lifecycle actions.
@MainActor
final class Batch09ProcessManagerNotificationTests: XCTestCase {
    private let preset = WatchedAppPreset(
        displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Example Helper"],
        protectedProcessNames: [], appPath: "/Applications/Example.app"
    )

    private func process(_ pid: Int32, _ name: String) -> AppProcess {
        AppProcess(
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
            processSignaler: Batch09InertSignaler(), lifecycle: lifecycle, settleAfterProcessChange: {}
        )
        manager.enableNotifications = true
        manager.watchedAppsProvider = { [self.preset] }
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
                processSignaler: Batch09InertSignaler(), lifecycle: Batch09StoppingLifecycle(inventory: nil),
                settleAfterProcessChange: {},
                pollingController: ProcessPollingController { await sleeper.sleep(interval: $0) }
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

/// LoginItemManager's delayed verification refresh, with an injected delay.
@MainActor
final class Batch09LoginItemVerificationTests: XCTestCase {
    // T05-12 (a): a state macOS settles after the call reaches the UI once the
    // verification delay has passed.
    func testVerificationRefreshPublishesAStateThatSettlesLater() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .requiresApproval)
        let gate = Batch09DelayGate()
        let manager = LoginItemManager(service: service, verificationDelay: { try await gate.wait() })

        manager.setEnabled(true)
        XCTAssertEqual(manager.state, .enabled, "the immediate refresh sees the registration")
        service.settle()
        XCTAssertEqual(manager.state, .enabled)

        try await waitUntil { await gate.waiting == 1 }
        await gate.open()
        try await waitUntil { manager.state == .requiresApproval }
        XCTAssertEqual(manager.message, "Launch at Login requires approval in System Settings.")
    }

    // T05-12 (b): a newer change cancels the pending verification, so only one
    // late refresh happens.
    func testANewerChangeCancelsThePendingVerification() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .enabled)
        let probe = Batch09CancellationProbe()
        let manager = LoginItemManager(service: service, verificationDelay: {
            if await probe.begin() == 1 {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    await probe.markCancelled()
                    throw error
                }
            }
        })

        manager.setEnabled(true)
        try await waitUntil { await probe.calls == 1 }
        let readsBeforeSecondChange = service.stateReads
        manager.setEnabled(true)
        let readsAfterSecondChange = service.stateReads

        try await waitUntil { await probe.cancelled }
        try await waitUntil { service.stateReads == readsAfterSecondChange + 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.stateReads, readsAfterSecondChange + 1, "exactly one late refresh")
        XCTAssertGreaterThan(readsAfterSecondChange, readsBeforeSecondChange)
    }

    // T05-12 (c): releasing the manager cancels its pending verification.
    func testReleasingTheManagerCancelsThePendingVerification() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .enabled)
        let probe = Batch09CancellationProbe()
        var manager: LoginItemManager? = LoginItemManager(service: service, verificationDelay: {
            _ = await probe.begin()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                await probe.markCancelled()
                throw error
            }
        })
        manager?.setEnabled(true)
        try await waitUntil { await probe.calls == 1 }

        manager = nil

        try await waitUntil { await probe.cancelled }
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met in time", file: file, line: line)
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

private struct Batch09InertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { XCTFail("No process may be signalled"); return false }
    func isAlive(_ pid: Int32) -> Bool { false }
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

private final class Batch09SettlingLoginService: LoginItemServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemState
    private var reads = 0
    private let settled: LoginItemState
    init(state: LoginItemState, settlesTo settled: LoginItemState) {
        current = state
        self.settled = settled
    }
    var stateReads: Int { lock.withLock { reads } }
    var state: LoginItemState {
        lock.withLock {
            reads += 1
            return current
        }
    }
    func settle() { lock.withLock { current = settled } }
    func register() throws { lock.withLock { current = .enabled } }
    func unregister() throws { lock.withLock { current = .notRegistered } }
    func openSystemSettings() {}
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

private actor Batch09DelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }
    func wait() async throws {
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private actor Batch09CancellationProbe {
    private(set) var calls = 0
    private(set) var cancelled = false
    func begin() -> Int {
        calls += 1
        return calls
    }
    func markCancelled() { cancelled = true }
}
