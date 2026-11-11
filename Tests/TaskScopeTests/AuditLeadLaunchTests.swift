import AppKit
import XCTest
@testable import TaskScope

/// A01-12 and the A01-2 lead from the November 2026 audit. A probe app built
/// like TaskScope (accessory at will-finish, regular after 0.5 s) lost its
/// activation about 0.1 s after `open` launched it in 5 of 5 launches, while
/// the same app left regular kept it; the unified log of two real TaskScope
/// launches showed the same. An ordinary launch then ended its grace period
/// inactive and showed no window until a second click.
@MainActor
final class AuditLeadLaunchTests: XCTestCase {
    private let notification = Notification(name: NSApplication.willFinishLaunchingNotification)

    func testAnOrdinaryLaunchIsNeverMadeAnAccessory() async {
        let recorder = Batch02DelegateRecorder()
        recorder.active = true
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder)

        delegate.applicationWillFinishLaunching(notification)
        XCTAssertEqual(delegate.launchContext, .pending)
        XCTAssertEqual(recorder.policies, [.regular], "an undecided launch keeps the activation it is given")

        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        for _ in 0..<200 where delegate.launchPhase != .running { await Task.yield() }
        XCTAssertEqual(delegate.launchContext, .interactive)
        XCTAssertTrue(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.count("present main window"), 1)
        XCTAssertFalse(recorder.policies.contains(.accessory), "\(recorder.policies)")
    }

    /// A cold-open URL arrives after will-finish. The launch still ends as a
    /// windowless accessory that hands the front back to the previous app.
    func testAColdURLLaunchStillEndsInTheBackground() async {
        let recorder = Batch02DelegateRecorder()
        recorder.active = true
        let gate = Batch02Gate()
        let session = makeBatch02Session(.interactive)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, waitForInteractiveLaunch: { await gate.wait() })
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }

        recorder.urlCallback?()

        XCTAssertEqual(delegate.launchContext, .urlAutomation)
        XCTAssertEqual(recorder.policies.last, .accessory)
        XCTAssertFalse(delegate.windowPresentationAllowed)
        XCTAssertEqual(recorder.count("restore previous app"), 1)
        await gate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(recorder.count("present main window"), 0)
    }

    /// A launch already known to be quiet at will-finish is still an
    /// accessory from the start.
    func testAQuietLaunchKnownAtWillFinishIsAnAccessoryFromTheStart() {
        let recorder = Batch02DelegateRecorder()
        let session = makeBatch02Session(.loginItem)
        defer { session.cleanUp() }
        let delegate = makeBatch02Delegate(session, recorder, launchedAsLoginItem: true)
        delegate.applicationWillFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(notification) }
        XCTAssertEqual(delegate.launchContext, .loginItem)
        XCTAssertEqual(recorder.policies, [.accessory])
    }
}
