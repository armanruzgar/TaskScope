import AppKit
import XCTest
@testable import TaskScope

@MainActor
final class Batch01LaunchTests: XCTestCase {
    private let suiteName = "TaskScope.Batch01.launch.\(UUID().uuidString)"
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testActivatedInteractiveLaunchStaysInteractiveWhenIntentArrivesInsideGracePeriod() async throws {
        let bus = AppCommandBus()
        bus.install { _ in .init(status: .completed, message: "refreshed") }
        let events = LaunchEvents()
        events.isActive = true
        let delegate = makeDelegate(bus: bus, events: events)
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        defer { events.releaseGrace(); delegate.applicationWillTerminate(notification) }
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        delegate.applicationDidBecomeActive(notification)
        XCTAssertEqual(delegate.launchPhase, .starting)
        var updates = 0
        delegate.requestShortcutParameterRefresh {
            updates += 1
            bus.prepareForIntentExecution()
        }
        XCTAssertEqual(updates, 0)

        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
        XCTAssertEqual(delegate.launchContext, .interactive)
        XCTAssertEqual(delegate.launchPhase, .starting)
        XCTAssertEqual(events.restores, 0)
        events.releaseGrace()
        for _ in 0..<100 where delegate.launchPhase != .running { await Task.yield() }
        XCTAssertEqual(delegate.launchPhase, .running)
        XCTAssertTrue(delegate.windowPresentationAllowed)
        XCTAssertEqual(events.policies.last, .regular)
        XCTAssertEqual(events.presentations, 1)
        XCTAssertEqual(updates, 1)
    }

    func testColdIntentAndColdURLStillSuppressAutomaticPresentation() async {
        for isURL in [false, true] {
            let bus = AppCommandBus()
            let events = LaunchEvents()
            let delegate = makeDelegate(bus: bus, events: events)
            let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
            defer { events.releaseGrace(); delegate.applicationWillTerminate(notification) }
            delegate.applicationWillFinishLaunching(notification)
            delegate.applicationDidFinishLaunching(notification)
            var updates = 0
            delegate.requestShortcutParameterRefresh {
                updates += 1
                bus.prepareForIntentExecution()
            }
            XCTAssertEqual(updates, 0)
            if isURL {
                // Launch Services can activate a cold URL launch before its URL arrives.
                delegate.applicationDidBecomeActive(notification)
                events.receiveURL?()
            } else {
                bus.prepareForIntentExecution()
            }
            XCTAssertEqual(delegate.launchContext, .urlAutomation)
            XCTAssertFalse(delegate.windowPresentationAllowed)
            XCTAssertEqual(events.policies.last, .accessory)
            XCTAssertEqual(events.presentations, 0)
            XCTAssertEqual(updates, 1, "Background launches publish once their context is settled")
        }
    }

    func testOwnParameterRefreshWaitsForFirstActivationAndCoalescesLaunchUpdates() async throws {
        let bus = AppCommandBus()
        let events = LaunchEvents()
        let delegate = makeDelegate(bus: bus, events: events)
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        defer { events.releaseGrace(); delegate.applicationWillTerminate(notification) }
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        let query = WatchedPresetEntityQuery(
            catalog: WatchedPresetCatalog(key: "presets", objectForKey: defaults.objectReader),
            prepareForIntent: { bus.prepareForIntentExecution() }
        )
        var updates = 0
        var queryTask: Task<[WatchedPresetEntity], Error>?
        let update = {
            updates += 1
            // Model linkd calling back into the entity query after our refresh.
            queryTask = Task { try await query.suggestedEntities() }
        }
        delegate.requestShortcutParameterRefresh(update: update)
        delegate.requestShortcutParameterRefresh(update: update)
        XCTAssertEqual(updates, 0, "No self-query while launch presentation is undecided")
        events.releaseGrace()
        for _ in 0..<100 where delegate.launchPhase != .running { await Task.yield() }
        XCTAssertEqual(delegate.launchPhase, .running)
        XCTAssertEqual(delegate.launchContext, .interactive)
        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(updates, 0, "An inactive launch must keep waiting for its first activation")
        XCTAssertEqual(events.policies.last, .regular)

        delegate.applicationDidBecomeActive(notification)
        XCTAssertEqual(updates, 1, "Launch-time requests coalesce into one refresh")
        let entities = try await queryTask?.value
        XCTAssertEqual(entities?.map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(delegate.launchContext, .interactive)
        XCTAssertTrue(delegate.windowPresentationAllowed)
        XCTAssertEqual(events.restores, 0)
        delegate.requestShortcutParameterRefresh { updates += 1 }
        XCTAssertEqual(updates, 2, "Later preset edits refresh immediately")
    }

    private func makeDelegate(bus: AppCommandBus, events: LaunchEvents) -> AppDelegate {
        let defaults = defaults!
        let session = TaskScopeLaunchSession(
            context: .interactive,
            runtime: .init(
                bundleIdentifier: "example.Batch01", processID: 10, userID: 501,
                runningInstances: { [] }, reopen: { _ in XCTFail("Unexpected handoff") },
                terminate: { XCTFail("Unexpected termination") }
            ),
            standardDefaults: { defaults }
        )
        return AppDelegate(
            launchSession: session, commandBus: bus,
            terminationHandler: .init(install: { _ in {} }, terminate: {}),
            runtime: .init(
                launchSignal: { .init(arguments: ["TaskScope"], launchedAsLoginItem: false, receivedOpenURL: false) },
                isActive: { events.isActive }, setActivationPolicy: { events.policies.append($0) },
                registerURLHandler: { events.receiveURL = $0 }, configureAccessibility: {}, registerHotkey: {},
                hideAutomaticWindows: {}, restorePreviousApplication: { events.restores += 1 },
                presentMainWindow: { events.presentations += 1 },
                waitForInteractiveLaunch: { await events.waitForGrace() }
            )
        )
    }
}

@MainActor
private final class LaunchEvents {
    var isActive = false
    var policies: [NSApplication.ActivationPolicy] = []
    var presentations = 0
    var restores = 0
    var receiveURL: (() -> Void)?
    private var graceReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForGrace() async {
        guard !graceReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func releaseGrace() {
        graceReleased = true
        continuation?.resume()
        continuation = nil
    }
}
