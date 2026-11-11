import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2 (app shell, launch contexts, window
// handling, quitting during actions). Every AppKit effect goes through a
// recording AppDelegate.Runtime: no activation policy, window, URL handler,
// Accessibility setting or termination reaches the real application.

// MARK: - Shared fakes

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
