import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2 (app shell, launch contexts, window
// handling, quitting during actions). Every AppKit effect goes through a
// recording AppDelegate.Runtime: no activation policy, window, URL handler,
// Accessibility setting or termination reaches the real application.

// MARK: - Shared fakes

/// Recording stand-in for every AppKit effect of AppDelegate.
@MainActor
final class Batch02DelegateRecorder {
    var active = false
    var policies: [NSApplication.ActivationPolicy] = []
    var events: [String] = []
    var urlCallback: (() -> Void)?
    var startedContexts: [TaskScopeLaunchContext] = []
    var mutationActive = false
    var replies: [Bool] = []
    var otherWindowOpen = false

    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

/// In-memory defaults (nothing reaches cfprefsd), unique per call.
func batch02Defaults() -> InMemoryUserDefaults {
    InMemoryUserDefaults(suiteName: "TaskScope.Batch02.\(UUID().uuidString)")!
}

@MainActor
func makeBatch02Session(
    _ context: TaskScopeLaunchContext,
    instances: [TaskScopeLaunchSession.Instance] = [],
    startTime: TimeInterval = .greatestFiniteMagnitude,
    events: ((String) -> Void)? = nil,
    standardDefaults: (() -> UserDefaults)? = nil
) -> TaskScopeLaunchSession {
    TaskScopeLaunchSession(
        context: context,
        runtime: .init(
            bundleIdentifier: "example.TaskScope.Batch02",
            processID: 10,
            userID: 501,
            runningInstances: { instances },
            reopen: { pid in
                if let events { events("reopen \(pid)") } else { XCTFail("Unexpected handoff") }
            },
            terminate: {
                if let events { events("terminate") } else { XCTFail("Unexpected termination") }
            },
            startTime: startTime
        ),
        standardDefaults: standardDefaults ?? { batch02Defaults() }
    )
}

@MainActor
func makeBatch02Delegate(
    _ session: TaskScopeLaunchSession,
    _ recorder: Batch02DelegateRecorder,
    bus: AppCommandBus? = nil,
    arguments: [String] = ["TaskScope"],
    launchedAsLoginItem: Bool = false,
    waitForInteractiveLaunch: @escaping () async -> Void = {},
    waitForTerminationTick: @escaping @MainActor () async -> Void = { await Task.yield() },
    terminationWaitTicks: Int = 50,
    waitForVerificationExpiry: @escaping @MainActor () async -> Void = {}
) -> AppDelegate {
    AppDelegate(
        launchSession: session,
        commandBus: bus ?? AppCommandBus(),
        terminationHandler: TaskScopeTerminationHandler(install: { _ in {} }, terminate: {}),
        runtime: .init(
            launchSignal: {
                .init(arguments: arguments, launchedAsLoginItem: launchedAsLoginItem, receivedOpenURL: false)
            },
            isActive: { recorder.active },
            setActivationPolicy: { recorder.policies.append($0) },
            registerURLHandler: { callback in
                recorder.events.append("register URL handler")
                recorder.urlCallback = callback
            },
            configureAccessibility: { recorder.events.append("configure Accessibility") },
            registerHotkey: { recorder.events.append("register hotkey") },
            hideAutomaticWindows: { recorder.events.append("hide windows") },
            restorePreviousApplication: { recorder.events.append("restore previous app") },
            presentMainWindow: { recorder.events.append("present main window") },
            waitForInteractiveLaunch: waitForInteractiveLaunch,
            startAppRuntime: { context, _ in recorder.startedContexts.append(context) },
            stopAppRuntime: { recorder.events.append("stop runtime") },
            isMutationActive: { recorder.mutationActive },
            stopRunningCommands: { recorder.events.append("stop running commands") },
            replyToTermination: { recorder.replies.append($0) },
            waitForTerminationTick: waitForTerminationTick,
            terminationWaitTicks: terminationWaitTicks,
            waitForVerificationExpiry: waitForVerificationExpiry,
            terminateApplication: { recorder.events.append("terminate application") },
            hasOtherOpenWindow: { _ in recorder.otherWindowOpen }
        )
    )
}

@MainActor
final class Batch02Answer {
    var result: TaskScopeCommandResult?
}

/// Submits a command and waits at most `seconds` for its answer, so a command
/// left queued fails the test instead of hanging the suite.
@MainActor
func batch02Submit(
    _ command: TaskScopeCommand, to bus: AppCommandBus, within seconds: Double = 2
) async -> TaskScopeCommandResult? {
    let answer = Batch02Answer()
    let submission = Task { @MainActor in answer.result = await bus.submit(command) }
    for _ in 0..<Int(seconds * 200) where answer.result == nil {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    if answer.result == nil { submission.cancel() }
    return answer.result
}

actor Batch02Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// An NSWindow that is never shown; it only records being ordered out.
final class Batch02RecordingWindow: NSWindow {
    private(set) var orderOutCount = 0

    convenience init(title: String, styleMask: NSWindow.StyleMask = [.titled, .closable]) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                  styleMask: styleMask, backing: .buffered, defer: true)
        self.title = title
        isReleasedWhenClosed = false
    }

    override func orderOut(_ sender: Any?) {
        orderOutCount += 1
    }
}

// MARK: - AppDelegate launch and window handling (A01-10, T02-5, A01-13, A01-3)

@MainActor
final class Batch02AppDelegateTests: XCTestCase {
    private let notification = Notification(name: NSApplication.willFinishLaunchingNotification)

    /// T02-5 (a), (b): a quiet launch stays a windowless accessory even after
    /// TaskScope becomes active.
    func testQuietLaunchesStayWindowlessAccessoriesAfterActivation() {
        let launches: [(TaskScopeLaunchContext, [String], Bool)] = [
            (.loginItem, ["TaskScope"], true),
            (.automation, ["TaskScope", "--automation"], false)
        ]
        for (context, arguments, loginItem) in launches {
            let recorder = Batch02DelegateRecorder()
            let session = makeBatch02Session(context)
            defer { session.cleanUp() }
            let delegate = makeBatch02Delegate(session, recorder, arguments: arguments, launchedAsLoginItem: loginItem)
            delegate.applicationWillFinishLaunching(notification)
            delegate.applicationDidFinishLaunching(notification)
            defer { delegate.applicationWillTerminate(notification) }
            XCTAssertEqual(delegate.launchContext, context)
            XCTAssertEqual(delegate.launchPhase, .running)

            recorder.active = true
            delegate.applicationDidBecomeActive(notification)

            XCTAssertFalse(delegate.windowPresentationAllowed, "\(context): activation must not present windows")
            XCTAssertEqual(delegate.launchContext, context, "\(context): activation must not promote the launch")
            XCTAssertEqual(recorder.count("present main window"), 0, "\(context)")
            XCTAssertEqual(recorder.policies, [.accessory, .accessory], "\(context): no Dock icon for a quiet launch")
        }
    }

    /// A01-10, T02-5 (d): an ordinary launch that is active when the grace
    /// period ends presents its window once and becomes a regular app.
    func testActiveInteractiveLaunchPresentsItsWindowOnceAfterTheGracePeriod() async {
        let recorder = Batch02DelegateRecorder()
        recorder.active = true
        let gate = Batch02Gate()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, waitForInteractiveLaunch: { await gate.wait() })
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(delegate.windowPresentationAllowed, "No window during the grace period")
        XCTAssertEqual(recorder.count("present main window"), 0)

        await gate.open()
        for _ in 0..<200 where delegate.launchPhase != .running { await Task.yield() }

        XCTAssertEqual(delegate.launchPhase, .running)
        XCTAssertEqual(delegate.launchContext, .interactive)
        XCTAssertTrue(delegate.windowPresentationAllowed, "An active Dock or Finder launch must show its window")
        XCTAssertEqual(recorder.count("present main window"), 1)
        XCTAssertEqual(recorder.policies.last, .regular)
    }

    /// A01-10: an ordinary launch that is still inactive when the grace period
    /// ends keeps its Dock icon and presents its window on the first activation.
    func testInactiveInteractiveLaunchPresentsItsWindowOnActivation() async {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        for _ in 0..<200 where delegate.launchPhase != .running { await Task.yield() }
        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.policies.last, .regular, "An inactive Dock launch keeps its Dock icon")
        XCTAssertEqual(recorder.count("present main window"), 0)

        recorder.active = true
        delegate.applicationDidBecomeActive(notification)

        XCTAssertTrue(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.count("present main window"), 1)
        delegate.applicationDidBecomeActive(notification)
        XCTAssertEqual(recorder.count("present main window"), 1, "Presented once")
    }

    /// A01-10: a restored or default window that becomes main during a quiet
    /// launch is hidden again.
    func testQuietLaunchHidesAnAutomaticWindowThatBecomesMain() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.loginItem)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, launchedAsLoginItem: true)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }

        let main = Batch02RecordingWindow(title: TaskScopeScene.main.title)
        let unrelated = Batch02RecordingWindow(title: "Settings")
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: main)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: unrelated)

        XCTAssertEqual(main.orderOutCount, 1, "The automatic main window must be hidden")
        XCTAssertEqual(unrelated.orderOutCount, 0, "Other windows are left alone")
    }

    /// A01-10, T02-5 (f): will-finish registers the URL handler, and a cold URL
    /// during the grace period demotes the launch to a quiet URL launch.
    func testColdURLDuringGracePeriodDemotesTheLaunch() async throws {
        let recorder = Batch02DelegateRecorder()
        recorder.active = true
        let gate = Batch02Gate()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, waitForInteractiveLaunch: { await gate.wait() })
        delegate.applicationWillFinishLaunching(notification)
        XCTAssertEqual(recorder.count("register URL handler"), 1)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }

        let callback = try XCTUnwrap(recorder.urlCallback, "will-finish must register the URL handler")
        callback()
        await gate.open()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(delegate.launchContext, .urlAutomation)
        XCTAssertEqual(delegate.launchPhase, .running)
        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.count("present main window"), 0, "A cold URL launch presents no window")
        XCTAssertEqual(recorder.policies.last, .accessory)
    }

    /// T02-5 (e): did-finish bounds Accessibility messaging once.
    func testDidFinishConfiguresAccessibilityOnce() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        XCTAssertEqual(recorder.count("configure Accessibility"), 1)
    }

    /// T02-5 (g): quitting stops the runtime (saving settings) and runs the
    /// installed termination work (restoring Activity Monitor) once.
    func testWillTerminateStopsTheRuntimeAndRunsTheTerminationWork() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        var runs = 0
        delegate.willTerminate = { runs += 1 }
        delegate.applicationWillTerminate(notification)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(recorder.count("stop runtime"), 1)
        XCTAssertEqual(recorder.count("stop running commands"), 1)
    }

    /// T02-5 (c): startup verification never permits windows.
    func testPermitWindowPresentationIsANoOpForStartupVerification() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.startupVerification)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, arguments: ["TaskScope", "--verify-startup"])
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        let policies = recorder.policies

        delegate.permitWindowPresentation()

        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.policies, policies)
    }

    /// A01-3: the runtime starts from did-finish with the resolved context, not
    /// from a SwiftUI view modifier, and never in startup verification.
    func testDidFinishStartsTheRuntimeOnceWithTheResolvedContext() async {
        let cases: [(TaskScopeLaunchContext, [String], Bool, [TaskScopeLaunchContext])] = [
            (.interactive, ["TaskScope"], false, [.interactive]),
            (.loginItem, ["TaskScope"], true, [.loginItem]),
            (.startupVerification, ["TaskScope", "--verify-startup"], false, [])
        ]
        for (context, arguments, loginItem, expected) in cases {
            let recorder = Batch02DelegateRecorder()
            let session = makeBatch02Session(context)
            defer { session.cleanUp() }
            let delegate = makeBatch02Delegate(session, recorder, arguments: arguments, launchedAsLoginItem: loginItem)
            delegate.applicationWillFinishLaunching(notification)
            XCTAssertEqual(recorder.startedContexts, [], "\(context): nothing starts before did-finish")
            delegate.applicationDidFinishLaunching(notification)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(recorder.startedContexts, expected, "\(context)")
            delegate.applicationWillTerminate(notification)
        }
    }

    /// A01-13: after a quiet launch, closing the last TaskScope window returns
    /// the app to the menu bar; an ordinary launch keeps its Dock icon.
    func testClosingTheLastWindowAfterAQuietLaunchReturnsToTheMenuBar() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.loginItem)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, launchedAsLoginItem: true)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }

        // What showTaskScopeWindow() does first when the user opens the window.
        delegate.permitWindowPresentation()
        XCTAssertEqual(recorder.policies.last, .regular)

        let main = Batch02RecordingWindow(title: TaskScopeScene.main.title)
        recorder.otherWindowOpen = true
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: main)
        XCTAssertEqual(recorder.policies.last, .regular, "Another TaskScope window is still open")

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification, object: Batch02RecordingWindow(title: "Settings")
        )
        XCTAssertEqual(recorder.policies.last, .regular, "Closing Settings does not change the policy")

        recorder.otherWindowOpen = false
        recorder.events.removeAll()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: main)
        XCTAssertEqual(recorder.policies.last, .accessory, "Back to menu-bar only")
        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.events, ["restore previous app"])

        // Opening the window again makes TaskScope a regular app again.
        delegate.permitWindowPresentation()
        XCTAssertEqual(recorder.policies.last, .regular)
    }

    func testClosingTheWindowOfAnOrdinaryLaunchKeepsItsDockIcon() async {
        let recorder = Batch02DelegateRecorder()
        recorder.active = true
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder)
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        for _ in 0..<200 where delegate.launchPhase != .running { await Task.yield() }
        XCTAssertTrue(delegate.windowPresentationAllowed)
        let policies = recorder.policies

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification, object: Batch02RecordingWindow(title: TaskScopeScene.main.title)
        )

        XCTAssertEqual(recorder.policies, policies)
        XCTAssertTrue(delegate.windowPresentationAllowed)
    }

    /// A01-13 / L07-11: only titled main, About and Onboarding windows count;
    /// the menu-bar panel does not.
    func testOnlyTitledSceneWindowsAreTaskScopeWindows() {
        for scene in TaskScopeScene.allCases {
            XCTAssertTrue(AppDelegate.isTaskScopeWindow(Batch02RecordingWindow(title: scene.title)), scene.title)
        }
        XCTAssertFalse(AppDelegate.isTaskScopeWindow(Batch02RecordingWindow(title: "Settings")))
        XCTAssertFalse(AppDelegate.isTaskScopeWindow(
            Batch02RecordingWindow(title: TaskScopeScene.main.title, styleMask: [.borderless])
        ))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = TaskScopeScene.main.title
        XCTAssertFalse(AppDelegate.isTaskScopeWindow(panel))
    }
}

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
        let inventory = Batch02FixedInventory(result: .success([]))
        let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory,
                                     processSignaler: Batch02InertSignaler(), lifecycle: lifecycle,
                                     settleAfterProcessChange: {})
        manager.enableNotifications = false
        manager.watchedAppsProvider = { [.globalProtect] }
        manager.isKeepOffIntentWritableProvider = { true }

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

// MARK: - Launch admission (A01-7, A01-5, L05-3, T05-5)

@MainActor
final class Batch02LaunchTests: XCTestCase {
    private let notification = Notification(name: NSApplication.willFinishLaunchingNotification)

    /// A01-7: two copies started together cannot both hand off and quit. Only
    /// the later one yields; equal start times fall back to the lower PID.
    func testALaunchYieldsOnlyToAnOlderInstance() {
        let cases: [(other: TaskScopeLaunchSession.Instance, ownStart: TimeInterval, handsOff: Bool)] = [
            (.init(processID: 42, userID: 501, bundleIdentifier: "example.TaskScope.Batch02", startTime: 50), 100, true),
            (.init(processID: 42, userID: 501, bundleIdentifier: "example.TaskScope.Batch02", startTime: 200), 100, false),
            (.init(processID: 9, userID: 501, bundleIdentifier: "example.TaskScope.Batch02", startTime: 100), 100, true),
            (.init(processID: 42, userID: 501, bundleIdentifier: "example.TaskScope.Batch02", startTime: 100), 100, false)
        ]
        for (other, ownStart, handsOff) in cases {
            var events: [String] = []
            let session = makeBatch02Session(.interactive, instances: [other], startTime: ownStart,
                                             events: { events.append($0) })
            defer { session.cleanUp() }
            XCTAssertEqual(session.continueLaunching(), !handsOff, "\(other) own start \(ownStart)")
            XCTAssertEqual(session.allowsRuntime, !handsOff)
            XCTAssertEqual(events, handsOff ? ["reopen \(other.processID)", "terminate"] : [])
        }
    }

    /// A01-5: a startup-verification process answers every command at once
    /// instead of leaving it queued forever.
    func testStartupVerificationAnswersCommandsInsteadOfQueueingThem() async {
        let session = makeBatch02Session(.startupVerification)
        defer { session.cleanUp() }
        let bus = AppCommandBus()
        session.installCommandHandler(on: bus) { _ in
            XCTFail("Startup verification must never run a command")
            return .init(status: .completed, message: "ran")
        }

        let answer = await batch02Submit(.refresh, to: bus)

        XCTAssertNotNil(answer, "The command was left queued behind a handler that is never installed")
        XCTAssertEqual(answer, AppCommandCoordinator.startupVerificationRejection)
        XCTAssertEqual(answer?.status, .rejected)
    }

    /// L05-3: a startup-verification instance quits by itself after its bounded
    /// life; no other launch context does.
    func testStartupVerificationQuitsByItselfAfterItsBoundedLife() async {
        let gate = Batch02Gate()
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.startupVerification)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, arguments: ["TaskScope", "--verify-startup"],
                                           waitForVerificationExpiry: { await gate.wait() })
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.count("terminate application"), 0, "Not before its time")

        await gate.open()
        for _ in 0..<50 where recorder.count("terminate application") == 0 { await Task.yield() }

        XCTAssertEqual(recorder.count("terminate application"), 1)

        for context in [TaskScopeLaunchContext.interactive, .loginItem] {
            let other = Batch02DelegateRecorder()
            let otherSession = makeBatch02Session(context)
            defer { otherSession.cleanUp() }
            let otherDelegate = makeBatch02Delegate(otherSession, other, launchedAsLoginItem: context == .loginItem)
            otherDelegate.applicationWillFinishLaunching(notification)
            otherDelegate.applicationDidFinishLaunching(notification)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(other.count("terminate application"), 0, "\(context) never quits by itself")
            otherDelegate.applicationWillTerminate(notification)
        }
    }

    /// T05-5: the packaging script launches the staged app with
    /// `--automation --verify-startup`. That must stay startup verification,
    /// whatever else the launch carries, so it never opens the real preferences
    /// or starts polling, Auto Stop rules or Keep Off enforcement.
    func testThePackagingScriptsVerificationLaunchIsStartupVerification() throws {
        let scriptArguments = try Self.verificationArgumentsFromBuildScript()
        XCTAssertTrue(scriptArguments.contains("--verify-startup"), "\(scriptArguments)")
        let argumentLists = [
            ["TaskScope"] + scriptArguments,
            ["TaskScope", "--background", "--verify-startup"],
            ["TaskScope", "--verify-startup", "--automation"]
        ]
        for arguments in argumentLists {
            for (loginItem, openURL) in [(false, false), (true, false), (false, true), (true, true)] {
                let context = TaskScopeLaunchContext.detect(TaskScopeLaunchSignal(
                    arguments: arguments, launchedAsLoginItem: loginItem, receivedOpenURL: openURL
                ))
                XCTAssertEqual(context, .startupVerification, "\(arguments) loginItem=\(loginItem) URL=\(openURL)")
            }
        }

        let context = TaskScopeLaunchContext.detect(TaskScopeLaunchSignal(
            arguments: ["TaskScope"] + scriptArguments, launchedAsLoginItem: false, receivedOpenURL: false
        ))
        var standardReads = 0
        let session = makeBatch02Session(
            context,
            instances: [.init(processID: 42, userID: 501, bundleIdentifier: "example.TaskScope.Batch02", startTime: 0)],
            standardDefaults: {
                standardReads += 1
                return batch02Defaults()
            }
        )
        defer { session.cleanUp() }
        XCTAssertFalse(session.allowsRuntime)
        XCTAssertTrue(session.continueLaunching(), "Verification never hands off to the running app")
        XCTAssertEqual(standardReads, 0, "Verification never opens the standard preferences")
    }

    /// The arguments `script/build_and_run.sh` passes after the executable when
    /// it starts the staged app for startup verification.
    private static func verificationArgumentsFromBuildScript() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let line = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("\"$executable\"") && $0.contains("--verify-startup") },
            "build_and_run.sh no longer launches the executable with --verify-startup"
        )
        let afterExecutable = try XCTUnwrap(line.components(separatedBy: "\"$executable\"").last)
        return afterExecutable
            .split(separator: " ")
            .map(String.init)
            .prefix { $0.hasPrefix("--") }
            .map { $0 }
    }
}

// MARK: - Lifecycle fakes

struct Batch02FixedInventory: ProcessInventoryProviding {
    let result: Result<[AppProcess], ProcessInventoryError>

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        result
    }
}

final class Batch02ScriptedInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]

    init(results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            guard !results.isEmpty else { return .failure(.commandFailed("exhausted")) }
            return results.count == 1 ? results[0] : results.removeFirst()
        }
    }
}

/// Never signals; reports every PID as gone.
struct Batch02InertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { true }
    func isAlive(_ pid: Int32) -> Bool { false }
}

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

/// Records every lifecycle call and performs none. The VPN disconnect
/// "succeeds", so a stop wrongly routed to Keep Off would show its privileged
/// steps here.
final class Batch02RecordingLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _unloadedAgentLabels: [[String]] = []
    private var _unloadedDaemonJobCounts: [Int] = []

    var calls: [String] { lock.withLock { _calls } }
    var unloadedAgentLabels: [[String]] { lock.withLock { _unloadedAgentLabels } }
    var unloadedDaemonJobCounts: [Int] { lock.withLock { _unloadedDaemonJobCounts } }

    private func record(_ call: String) {
        lock.withLock { _calls.append(call) }
    }

    private func recordUnload(_ preset: WatchedAppPreset) {
        lock.withLock {
            _calls.append("agents.unload")
            _unloadedAgentLabels.append(preset.lifecycleUserLaunchAgentJobs.map(\.label))
            _unloadedDaemonJobCounts.append(preset.lifecycleSystemLaunchDaemonJobs.count)
        }
    }

    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        record("vpn.disconnect")
        return .disconnected
    }
    func appBundleExists(at path: String) -> Bool { record("exists"); return true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { record("open"); return .opened }
    func settleAfterProcessChange() async { record("settle") }
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminate:\(preset.mainProcessName)")
        return .signalled
    }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminate.helper:\(name)")
        return .signalled
    }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        record("wait:\(preset.mainProcessName)")
        return true
    }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        recordUnload(preset)
        return .notNeeded
    }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        recordUnload(preset)
        return .notNeeded
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("agents.load")
        return .notNeeded
    }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        record("agents.disable")
        return .notNeeded
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("agents.enable")
        return .notNeeded
    }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("daemon.ensure")
        return .notNeeded
    }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        record("daemon.disable:\(allowAdministratorPrompt)")
        return .notNeeded
    }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("daemon.enable")
        return .notNeeded
    }
}
