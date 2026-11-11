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
