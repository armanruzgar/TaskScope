import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class AppShellRegressionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.AppShell.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testDuplicateLaunchHandsOffBeforeRuntimeOrPreferences() async {
        for context in [TaskScopeLaunchContext.interactive, .loginItem, .automation, .urlAutomation] {
            var events: [String] = []
            let session = TaskScopeLaunchSession(
                context: context,
                runtime: runtime(instances: [instance(pid: 42)]) {
                    events.append($0)
                },
                standardDefaults: {
                    events.append("preferences")
                    return self.defaults
                }
            )
            defer { session.cleanUp() }

            let bus = AppCommandBus()
            bus.install { _ in .init(status: .completed, message: "original handler") }
            session.installCommandHandler(on: bus) { _ in
                XCTFail("A duplicate must not install its command handler")
                return .init(status: .failed, message: "duplicate handler")
            }
            let delegate = makeDelegate(session: session, bus: bus, event: { events.append($0) })
            let notification = Notification(name: NSApplication.willFinishLaunchingNotification)
            defer { delegate.applicationWillTerminate(notification) }
            delegate.applicationWillFinishLaunching(notification)
            delegate.applicationDidFinishLaunching(notification)
            XCTAssertNil(bus.onIntentExecution, "A duplicate must not install an intent observer")
            let result = await bus.submit(.refresh)
            XCTAssertEqual(result.message, "original handler")
            XCTAssertFalse(session.continueLaunching(), "A duplicate must not continue launching")
            XCTAssertFalse(session.allowsRuntime, "A duplicate must not start polling or accept commands")
            XCTAssertEqual(events, ["reopen 42", "terminate"], "Handoff must not read shared preferences")
            XCTAssertFalse(session.continueLaunching())
            XCTAssertEqual(events, ["reopen 42", "terminate"], "Handoff occurs only once")
        }
    }

    @MainActor
    func testLaunchIgnoresSelfOtherUsersAndOtherBundleIdentifiers() {
        let session = TaskScopeLaunchSession(
            context: .loginItem,
            runtime: runtime(instances: [
                instance(pid: 10),
                instance(pid: 42, uid: 502),
                instance(pid: 43, bundleIdentifier: "example.Other")
            ]) { _ in XCTFail("An unrelated process must not cause a handoff") },
            standardDefaults: { self.defaults }
        )
        defer { session.cleanUp() }
        XCTAssertTrue(session.continueLaunching())
        XCTAssertTrue(session.allowsRuntime)
        XCTAssertTrue(session.userDefaults === defaults)
    }

    @MainActor
    func testVerificationStoresAndOnboardingAreIsolatedAndCleanedUp() {
        defaults.set(true, forKey: "TaskScope.onboarded.v1")
        let existing = SettingsStore(userDefaults: defaults)
        existing.keepGlobalProtectOff = true
        for key in [WatchedAppsStore.defaultPersistenceKey, "TaskScope.autoStopRules.v1",
                    "TaskScope.autoStopEvents.v1", "TaskScope.savedSelections.v1"] {
            defaults.set(Data([0xFE, 0xED]), forKey: key)
        }
        let before = defaults.persistentDomain(forName: suiteName)!
        var standardReads = 0
        let session = TaskScopeLaunchSession(
            context: .startupVerification,
            runtime: runtime(instances: [instance(pid: 42)]) { _ in
                XCTFail("Verification must not hand off to the running app")
            },
            standardDefaults: {
                standardReads += 1
                return self.defaults
            }
        )
        defer { session.cleanUp() }
        let stores = TaskScopeLaunchStores(session: session, inventory: ScriptedInventory(processes: []))
        var events: [String] = []
        let bus = AppCommandBus()
        let delegate = makeDelegate(session: session, bus: bus, arguments: ["TaskScope", "--verify-startup"],
                                    event: { events.append($0) })
        let notification = Notification(name: NSApplication.willFinishLaunchingNotification)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        XCTAssertNil(bus.onIntentExecution)
        XCTAssertFalse(events.contains("register hotkey"), "Verification must not register a hotkey")

        XCTAssertTrue(session.continueLaunching())
        XCTAssertFalse(session.allowsRuntime)
        XCTAssertEqual(standardReads, 0, "Verification must never request the real preferences")
        XCTAssertTrue(stores.showOnboarding, "Verification must not read the real onboarding flag")
        XCTAssertFalse(stores.settings.keepGlobalProtectOff)
        XCTAssertNil(stores.watchedApps.persistenceIssue)
        let isolatedDomains = session.userDefaults.volatileDomainNames.filter { $0.hasPrefix("TaskScope.Startup.") }
        XCTAssertEqual(isolatedDomains.count, 1)
        if let name = isolatedDomains.first {
            XCTAssertNil(session.userDefaults.persistentDomain(forName: name)?[WatchedAppsStore.defaultPersistenceKey])
            XCTAssertNotNil(session.userDefaults.data(forKey: WatchedAppsStore.defaultPersistenceKey))
        }
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)! as NSDictionary, before as NSDictionary)
        session.userDefaults.set(true, forKey: "TaskScope.onboarded.v1")
        session.cleanUp()
        XCTAssertNil(session.userDefaults.object(forKey: "TaskScope.onboarded.v1"))
    }

    @MainActor
    func testTerminationSignalRequestsGracefulTerminationAndCancelsRegistration() {
        var signalHandler: (@MainActor @Sendable () -> Void)?
        var installs = 0
        var terminations = 0
        var cancellations = 0
        let handler = TaskScopeTerminationHandler(
            install: { callback in
                installs += 1
                signalHandler = callback
                return { cancellations += 1 }
            },
            terminate: { terminations += 1 }
        )
        let session = TaskScopeLaunchSession(context: .interactive,
            runtime: runtime(instances: []) { _ in XCTFail("Unexpected handoff") },
            standardDefaults: { self.defaults })
        let delegate = makeDelegate(session: session, bus: AppCommandBus(), terminationHandler: handler)
        let notification = Notification(name: NSApplication.willFinishLaunchingNotification)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationWillFinishLaunching(notification)
        signalHandler?()
        XCTAssertEqual(installs, 1, "SIGTERM handling must be installed once")
        XCTAssertEqual(terminations, 1, "SIGTERM must request the normal application termination path")
        delegate.applicationWillTerminate(notification)
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testEveryIntentQuerySignalsAutomationBeforeReturningEntities() async throws {
        let bus = AppCommandBus()
        var signals = 0
        var context = TaskScopeLaunchContext.pending
        bus.onIntentExecution = {
            signals += 1
            context = TaskScopeLaunchContext.receivingAutomation(current: context, phase: .starting,
                                                                  source: .intent, hasInteractiveSignal: false)
        }
        let query = WatchedPresetEntityQuery(
            catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: defaults.objectReader),
            prepareForIntent: { bus.prepareForIntentExecution() }
        )
        _ = try await query.entities(for: [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(signals, 1)
        XCTAssertEqual(context, .urlAutomation, "A query-only cold launch must suppress presentation")
        _ = try await query.entities(matching: "Global")
        XCTAssertEqual(signals, 2)
        _ = try await query.entities(matching: " ")
        XCTAssertEqual(signals, 3)
        _ = try await query.suggestedEntities()
        XCTAssertEqual(signals, 4)
    }

    @MainActor
    func testLateIntentDemotesOnlyLaunchWithoutInteractiveSignal() async throws {
        for interactiveSignal in ["none", "activation", "reopen"] {
            let session = TaskScopeLaunchSession(context: .interactive,
                runtime: runtime(instances: []) { _ in XCTFail("Unexpected handoff") },
                standardDefaults: { self.defaults })
            let bus = AppCommandBus()
            session.installCommandHandler(on: bus) { _ in .init(status: .completed, message: "refreshed") }
            var events: [String] = []
            let delegate = makeDelegate(session: session, bus: bus, event: { events.append($0) })
            let notification = Notification(name: NSApplication.willFinishLaunchingNotification)
            defer { delegate.applicationWillTerminate(notification) }
            delegate.applicationWillFinishLaunching(notification)
            // Record the real activation callback while windows are still suppressed.
            if interactiveSignal == "activation" { delegate.applicationDidBecomeActive(notification) }
            delegate.applicationDidFinishLaunching(notification)
            XCTAssertEqual(events.filter { $0 == "register hotkey" }.count, 1)
            for _ in 0..<100 where delegate.launchPhase != .running { await Task.yield() }
            XCTAssertEqual(delegate.launchPhase, .running)
            XCTAssertFalse(delegate.windowPresentationAllowed)
            if interactiveSignal == "reopen" {
                var shown = 0
                delegate.showMainWindow = { shown += 1 }
                XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
                XCTAssertEqual(shown, 1)
            }
            _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
            let expected: TaskScopeLaunchContext = interactiveSignal == "none" ? .urlAutomation : .interactive
            XCTAssertEqual(delegate.launchContext, expected)
            let query = WatchedPresetEntityQuery(catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: defaults.objectReader),
                                                prepareForIntent: { bus.prepareForIntentExecution() })
            _ = try await query.suggestedEntities()
            XCTAssertEqual(delegate.launchContext, expected)
        }
    }

    @MainActor
    func testDuplicateReopenShowsQuietRunningInstanceBeforeExiting() {
        let runningSession = TaskScopeLaunchSession(context: .loginItem,
            runtime: runtime(instances: []) { _ in XCTFail("Unexpected handoff") },
            standardDefaults: { self.defaults })
        let runningDelegate = makeDelegate(session: runningSession, bus: AppCommandBus(), launchedAsLoginItem: true)
        let notification = Notification(name: NSApplication.willFinishLaunchingNotification)
        runningDelegate.applicationWillFinishLaunching(notification)
        runningDelegate.applicationDidFinishLaunching(notification)
        defer { runningDelegate.applicationWillTerminate(notification) }
        XCTAssertFalse(runningDelegate.windowPresentationAllowed)
        XCTAssertEqual(runningDelegate.launchContext, .loginItem)
        var events: [String] = []
        runningDelegate.showMainWindow = { [weak runningDelegate] in
            events.append("show window")
            runningDelegate?.permitWindowPresentation()
        }
        let runningURL = URL(fileURLWithPath: "/Applications/RunningCopy.app")
        let handoff = TaskScopeInstanceHandoff(
            applicationURL: { pid in XCTAssertEqual(pid, 42); return runningURL },
            yieldActivation: { pid in XCTAssertEqual(pid, 42); events.append("yield activation") },
            openApplication: { url, configuration in
                XCTAssertEqual(url, runningURL)
                XCTAssertTrue(configuration.activates)
                XCTAssertFalse(configuration.createsNewApplicationInstance)
                events.append("reopen")
                XCTAssertFalse(runningDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            }
        )
        var duplicateRuntime = runtime(instances: [instance(pid: 42)]) { events.append($0) }
        duplicateRuntime.reopen = { handoff.perform(processID: $0) }
        let duplicate = TaskScopeLaunchSession(context: .interactive, runtime: duplicateRuntime,
            standardDefaults: { XCTFail("A duplicate must not read preferences"); return self.defaults })
        defer { duplicate.cleanUp() }
        XCTAssertFalse(duplicate.continueLaunching())
        XCTAssertTrue(runningDelegate.windowPresentationAllowed)
        XCTAssertEqual(events, ["yield activation", "reopen", "show window", "terminate"])
    }

    @MainActor
    func testCadenceChangesDoNotFloodVisibleHistory() async throws {
        let inventory = ScriptedInventory(processes: [])
        let history = ProcessHistory(inventory: inventory)
        history.beginSampling(cadence: 10)
        defer { history.endSampling() }
        for _ in 0..<200 where history.samples.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(history.samples.count, 1)
        for cadence in 11...15 {
            history.updateConsumerCadence(Double(cadence))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(history.samples.count, 1, "Changing cadence must reschedule without sampling")
        let loads = inventory.readCount
        XCTAssertEqual(loads, 1, "Cadence changes must not trigger extra inventory reads")
    }

    @MainActor
    func testCadenceRescheduleStillSamplesAndPausesWithoutConsumers() async throws {
        let inventory = ScriptedInventory(processes: [])
        let history = ProcessHistory(inventory: inventory)
        history.beginSampling(cadence: 60)
        defer { history.stop() }
        for _ in 0..<200 where history.samples.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        history.updateConsumerCadence(2)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(history.samples.count, 1, "Rescheduling must wait for the new cadence")
        for _ in 0..<600 where history.samples.count == 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(history.samples.count, 2, "Rescheduling must preserve future sampling")
        history.endSampling()
        history.updateConsumerCadence(2)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(history.state, .paused)
        XCTAssertEqual(history.samples.count, 2)
    }

    @MainActor
    func testAboutAndOnboardingUseTheApplicationIcon() throws {
        let icon = NSApplication.shared.applicationIconImage
        XCTAssertEqual(try AboutView().inspect().find(ViewType.Image.self).actualImage().nsImage(), icon)
        XCTAssertEqual(try OnboardingView(onComplete: {}).inspect().find(ViewType.Image.self).actualImage().nsImage(), icon)
    }

    @MainActor
    func testRestoringThePreviousApplicationRequiresActivationAndUsesTheMostRecentApp() {
        let other = AppShellPreviousApplication(processIdentifier: 123, isTerminated: false)
        let tracker = PreviousApplicationTracker(ownProcessID: other.processIdentifier + 1, initial: nil)
        var events: [String] = []
        let restore = { (active: Bool) in
            tracker.restore(isActive: active, deactivate: { events.append("deactivate") },
                            activate: { events.append("activate \($0.processIdentifier)") })
        }

        restore(true)
        XCTAssertEqual(events, ["deactivate"], "Nothing recorded yet, so nothing is activated")

        let center = NotificationCenter()
        tracker.startObserving(center)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: other])
        XCTAssertEqual(tracker.application?.processIdentifier, other.processIdentifier)

        events.removeAll()
        restore(false)
        XCTAssertEqual(events, [], "A background TaskScope must not hand activation to another app")

        restore(true)
        XCTAssertEqual(events, ["deactivate", "activate \(other.processIdentifier)"])

        let selfTracker = PreviousApplicationTracker(ownProcessID: other.processIdentifier, initial: other)
        XCTAssertNil(selfTracker.application, "TaskScope never records itself as the previous app")
        selfTracker.record(other)
        XCTAssertNil(selfTracker.application)
    }

    @MainActor
    private func makeDelegate(
        session: TaskScopeLaunchSession,
        bus: AppCommandBus,
        arguments: [String] = ["TaskScope"],
        launchedAsLoginItem: Bool = false,
        terminationHandler: TaskScopeTerminationHandler? = nil,
        event: @escaping (String) -> Void = { _ in }
    ) -> AppDelegate {
        AppDelegate(
            launchSession: session, commandBus: bus,
            terminationHandler: terminationHandler ?? TaskScopeTerminationHandler(
                install: { _ in event("install termination handler"); return {} }, terminate: {}),
            runtime: .init(
                launchSignal: { .init(arguments: arguments, launchedAsLoginItem: launchedAsLoginItem, receivedOpenURL: false) },
                isActive: { false }, setActivationPolicy: { _ in },
                registerURLHandler: { _ in event("register URL handler") },
                configureAccessibility: { event("configure Accessibility") },
                registerHotkey: { event("register hotkey") },
                hideAutomaticWindows: {}, restorePreviousApplication: {}, presentMainWindow: {},
                waitForInteractiveLaunch: {}
            )
        )
    }

    @MainActor
    private func runtime(
        instances: [TaskScopeLaunchSession.Instance],
        event: @escaping (String) -> Void
    ) -> TaskScopeLaunchSession.Runtime {
        .init(
            bundleIdentifier: "example.TaskScope",
            processID: 10,
            userID: 501,
            runningInstances: { instances },
            reopen: { event("reopen \($0)") },
            terminate: { event("terminate") }
        )
    }

    @MainActor
    private func instance(
        pid: pid_t, uid: uid_t = 501, bundleIdentifier: String = "example.TaskScope"
    ) -> TaskScopeLaunchSession.Instance {
        .init(processID: pid, userID: uid, bundleIdentifier: bundleIdentifier)
    }
}

private struct AppShellPreviousApplication: PreviousApplication {
    var processIdentifier: pid_t
    var isTerminated: Bool
}
