import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2 (app shell, launch contexts, window
// handling, quitting during actions). Every AppKit effect goes through a
// recording AppDelegate.Runtime: no activation policy, window, URL handler,
// Accessibility setting or termination reaches the real application.

// MARK: - Shared fakes

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
