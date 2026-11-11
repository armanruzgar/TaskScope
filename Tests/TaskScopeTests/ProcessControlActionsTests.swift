import Darwin
import Foundation
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-19 parts 1 to 3 and other signals: Stop With Children, Pause and Resume,
/// Send Signal, and preset Restart. Every signal goes through the revalidated
/// single-PID path; the only real signals go to a child this test started.
@MainActor
final class ProcessControlActionsTests: XCTestCase {
    private let start = "Sat Jul 26 11:20:17 2026"

    private func row(
        pid: Int32, parent: Int32 = 1, path: String = "/Applications/Example.app/Contents/MacOS/Example",
        uid: uid_t? = getuid(), start: String? = nil, zombie: Bool? = nil, stopped: Bool? = nil
    ) -> AppProcess {
        var process = AppProcess(
            pid: pid, parentPID: parent, uid: uid, cpu: 0, memoryMB: 1, command: path, executablePath: path,
            elapsedTime: "00:10", startTime: start ?? self.start, isZombie: zombie,
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
        process.isStopped = stopped
        return process
    }

    private func manager(
        _ inventory: ControlTestInventory,
        signaler: ControlTestSignaler = ControlTestSignaler(),
        lifecycle: any ProcessLifecycleServicing = ControlTestLifecycle()
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory, processSignaler: signaler, lifecycle: lifecycle,
            settleAfterProcessChange: {}, currentPID: 99_999, dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    // MARK: - Which processes can be paused or signalled

    func testSignalsReachOnlyTheUsersOwnOrdinaryProcesses() {
        func refusal(_ process: AppProcess) -> String? {
            ProcessSignalEligibility.refusal(for: process, currentPID: 99_999, currentUID: getuid())
        }
        XCTAssertNil(refusal(row(pid: 500)))
        XCTAssertNil(refusal(row(pid: 501, path: "/opt/homebrew/bin/node")))
        XCTAssertNil(refusal(row(pid: 502, path: "/usr/bin/make")), "Command-line tools can be paused")
        XCTAssertNil(refusal(row(pid: 503, path: "/System/Applications/Notes.app/Contents/MacOS/Notes")))

        XCTAssertEqual(refusal(row(pid: 99_999)), "TaskScope does not pause or signal itself.")
        XCTAssertEqual(refusal(row(pid: 1)), "This PID cannot be signalled.")
        XCTAssertEqual(refusal(row(pid: 504, uid: getuid() + 1)), "Only your own processes can be paused or signalled.")
        XCTAssertEqual(refusal(row(pid: 505, uid: nil)), "Only your own processes can be paused or signalled.")
        XCTAssertEqual(refusal(row(pid: 506, path: "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect")),
                       "GlobalProtect is controlled only through its preset.")
        XCTAssertEqual(refusal(row(pid: 507, path: "/opt/PanGPA")), "GlobalProtect is controlled only through its preset.")
        for path in [
            "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
            "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
            "/usr/sbin/cfprefsd", "/usr/libexec/trustd", "/sbin/launchd", "/Library/Apple/System/Library/x"
        ] {
            XCTAssertEqual(
                refusal(row(pid: 508, path: path)),
                "It is part of macOS; pausing or signalling it can leave your session unresponsive.",
                path
            )
        }
        var unknownPath = row(pid: 509)
        unknownPath.executablePath = nil
        XCTAssertEqual(refusal(unknownPath), "Its executable could not be verified.")
    }

    func testEachActionNamesItsSignal() {
        XCTAssertEqual(ProcessSignalAction.allCases.map(\.signal), [SIGSTOP, SIGCONT, SIGHUP, SIGINT, SIGUSR1, SIGUSR2])
        XCTAssertEqual(ProcessSignalAction.sendSignalMenu.map(\.menuTitle), [
            "Hangup (SIGHUP)…", "Interrupt (SIGINT)…", "User 1 (SIGUSR1)…", "User 2 (SIGUSR2)…"
        ])
        XCTAssertEqual(ProcessSignalAction.allCases.filter { !$0.requiresConfirmation }, [.resume])
    }

    // MARK: - The revalidated single-PID path

    func testSignalsGoOnlyToTheVerifiedPID() async {
        for action in ProcessSignalAction.allCases {
            let target = row(pid: 700)
            let inventory = ControlTestInventory([.success([target])])
            let signaler = ControlTestSignaler()
            let manager = manager(inventory, signaler: signaler)

            let outcome = await manager.sendSignal(action, to: target)

            XCTAssertEqual(outcome, .delivered, "\(action)")
            XCTAssertEqual(signaler.sent, [ControlTestSignaler.Sent(signal: action.signal, pid: 700)])
            XCTAssertEqual(manager.message, action.deliveredMessage(for: target))
        }
    }

    func testNothingIsSentToAChangedOrMissingProcess() async {
        let target = row(pid: 700)
        let cases: [(Result<[AppProcess], ProcessInventoryError>, ProcessSignalOutcome, String)] = [
            (.success([row(pid: 700, start: "Sun Jul 27 09:00:00 2026")]), .identityChanged, "Example's identity changed; nothing was sent."),
            (.success([row(pid: 700, zombie: true)]), .notRunning, "Example is no longer running."),
            (.success([]), .notRunning, "Example is no longer running."),
            (.failure(.commandFailed("ps failed")), .rejected, "Could not verify Example; nothing was sent.")
        ]
        for (read, expected, message) in cases {
            let signaler = ControlTestSignaler()
            let manager = manager(ControlTestInventory([read]), signaler: signaler)
            let outcome = await manager.sendSignal(.pause, to: target)
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(manager.message, message)
            XCTAssertTrue(signaler.sent.isEmpty, "\(read)")
        }
    }

    func testIneligibleProcessIsRefusedBeforeAnyRead() async {
        let inventory = ControlTestInventory([])
        let signaler = ControlTestSignaler()
        let manager = manager(inventory, signaler: signaler)

        let outcome = await manager.sendSignal(.hangup, to: row(pid: 701, path: "/usr/sbin/cfprefsd"))

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(manager.message, "Hangup is not available for cfprefsd. It is part of macOS; pausing or signalling it can leave your session unresponsive.")
        XCTAssertTrue(signaler.sent.isEmpty)
        XCTAssertEqual(inventory.loads, 0)
    }

    func testAKernelRefusalIsReported() async {
        let target = row(pid: 702)
        let signaler = ControlTestSignaler()
        signaler.answer = .rejected(errno: EPERM)
        let manager = manager(ControlTestInventory([.success([target])]), signaler: signaler)

        let outcome = await manager.sendSignal(.interrupt, to: target)

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(manager.message, "Could not send SIGINT to Example. The system refused the signal.")
    }

    /// The only real SIGSTOP and SIGCONT in the suite, to a child this test
    /// started, through the production signaler; the kernel's process table
    /// then shows it stopped (state T) and running again.
    func testPauseAndResumeReachTheTestsOwnChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
        }
        let target = row(pid: pid, parent: getpid(), path: "/bin/sleep", start: "test-child-\(pid)")
        let manager = ProcessManager(
            processInventory: ControlTestInventory(repeating: .success([target])),
            processSignaler: DarwinProcessSignaler(),
            lifecycle: ControlTestLifecycle(),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false

        let paused = await manager.sendSignal(.pause, to: target)
        XCTAssertEqual(paused, .delivered)
        let stopped = await kernelState(of: pid, isStopped: true)
        XCTAssertTrue(stopped, "The child is stopped")
        XCTAssertTrue(child.isRunning, "Pause keeps the process alive")

        let resumed = await manager.sendSignal(.resume, to: target)
        XCTAssertEqual(resumed, .delivered)
        let running = await kernelState(of: pid, isStopped: false)
        XCTAssertTrue(running, "The child runs again")
        XCTAssertEqual(manager.message, "sleep resumed.")
    }

    private func kernelState(of pid: Int32, isStopped expected: Bool) async -> Bool {
        for _ in 0..<200 {
            if case .found(let entry) = KernelProcessTable.entry(for: pid), entry.isStopped == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// The list read takes the paused state from the same process-table read
    /// that vouches for each row's identity.
    func testTheListReadMarksStoppedRows() async throws {
        let ps = "42 1 \(getuid()) 1 1024 Wed Oct 7 17:04:47 2026 00:01 Example\n43 1 \(getuid()) 2 2048 Wed Oct 7 17:04:47 2026 00:02 Other"
        let table = KernelProcessTable.table(from: [
            KernelProcessEntry(pid: 42, parentPID: 1, uid: getuid(), startSeconds: 1_791_392_687),
            KernelProcessEntry(pid: 43, parentPID: 1, uid: getuid(), startSeconds: 1_791_392_687, isStopped: true)
        ])
        let rows = try await ProcessListReader.currentProcessList(
            fetchExtendedStats: false,
            run: { ShellCommandResult(command: $0, stdout: ps, stderr: "", exitCode: 0) },
            executablePath: { _ in nil },
            startUptime: { _ in nil },
            processTable: { table },
            ownerName: { _ in "me" },
            diskIO: { _ in nil },
            currentPID: 42
        ).get()
        XCTAssertEqual(rows.map(\.isStopped), [false, true])
    }

    func testAPausedRowSaysSo() throws {
        let paused = ProcessRow(
            process: row(pid: 710, stopped: true), isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
            isHighlightedCPU: false, isHighlightedMEM: false, stopAction: {}, toggleSelection: {}
        )
        XCTAssertNoThrow(try paused.inspect().find(text: "Paused"))
        let identity = try paused.inspect().find(ViewType.HStack.self).find(ViewType.VStack.self)
        XCTAssertTrue(try identity.accessibilityValue().string().contains("paused"))

        let running = ProcessRow(
            process: row(pid: 711, stopped: false), isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
            isHighlightedCPU: false, isHighlightedMEM: false, stopAction: {}, toggleSelection: {}
        )
        XCTAssertThrowsError(try running.inspect().find(text: "Paused"))
    }

    func testPauseAsksFirstAndResumeDoesNot() async {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let target = row(pid: 720, stopped: true)
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, manager: manager(
            ControlTestInventory(repeating: .success([target])), signaler: ControlTestSignaler()
        ), state: state)

        view.requestSignal(.pause, for: target)
        XCTAssertEqual(state.pendingSignal?.action, .pause)
        XCTAssertEqual(state.pendingSignal?.confirmTitle, "Pause Example")
        XCTAssertEqual(state.pendingSignal?.title, "Pause Process?")
        state.clearSignal()

        view.requestSignal(.resume, for: target)
        XCTAssertNil(state.pendingSignal, "Resume needs no confirmation")
        await state.waitForActions()
        view.requestSignal(.hangup, for: target)
        XCTAssertEqual(state.pendingSignal?.confirmTitle, "Send SIGHUP to Example")
    }

    // MARK: - Stop With Children

    func testDescendantsComeFromTheInventoryWithoutTaskScopeOrLoops() {
        let ownPID: Int32 = 99_999
        func descendants(of parent: AppProcess, in inventory: [AppProcess]) -> ProcessFamily.Members {
            ProcessFamily.descendants(of: parent, in: inventory) {
                ProcessSignalEligibility.ineligibility(for: $0, currentPID: ownPID, currentUID: getuid()) == nil
            }
        }
        let inventory = [
            row(pid: 100), row(pid: 101, parent: 100), row(pid: 103, parent: 100),
            row(pid: 102, parent: 101), row(pid: 104, parent: 103),
            row(pid: 105, parent: 100, zombie: true),
            row(pid: ownPID, parent: 100), row(pid: 106, parent: ownPID),
            row(pid: 200), row(pid: 201, parent: 200),
            // A recycled PID can make two rows each other's parent.
            row(pid: 300, parent: 301), row(pid: 301, parent: 300)
        ]
        let family = descendants(of: row(pid: 100), in: inventory)
        XCTAssertEqual(family.included.map(\.pid), [101, 103, 102, 104])
        XCTAssertEqual(family.leftOutCount, 2, "TaskScope and its child are left out")
        XCTAssertEqual(descendants(of: row(pid: 300, parent: 301), in: inventory).included.map(\.pid), [301])
        XCTAssertTrue(descendants(of: row(pid: 201, parent: 200), in: inventory).included.isEmpty)
    }

    func testStopWithChildrenUsesTheBatchReviewAndRevalidatesEachPID() async throws {
        let parent = row(pid: 800)
        let child = row(pid: 801, parent: 800, path: "/Applications/Example.app/Contents/MacOS/Worker")
        let grandchild = row(pid: 802, parent: 801, path: "/opt/homebrew/bin/node")
        let fixture = await Batch10.fixture(processes: [parent, child, grandchild])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)

        view.requestStopWithChildren(parent)

        let pending = try XCTUnwrap(state.pendingBatchTermination)
        XCTAssertEqual(pending.targets.map(\.pid), [800, 801, 802])
        XCTAssertEqual(pending.title, "Stop Example and Its Child Processes?")
        XCTAssertEqual(pending.confirmTitle, "Stop 3 Processes")
        XCTAssertTrue(pending.summary.hasPrefix("Stop Example and its 2 child processes, one at a time."), pending.summary)

        // The grandchild's PID now runs something else: it is not signalled.
        let verification = ControlTestInventory([.success([
            parent, child, row(pid: 802, parent: 801, path: "/opt/homebrew/bin/node", start: "Sun Jul 27 09:00:00 2026")
        ])])
        let signaler = ControlTestSignaler()
        let batchManager = ProcessManager(
            processInventory: verification, processSignaler: signaler, lifecycle: ControlTestLifecycle(),
            settleAfterProcessChange: {}, currentPID: 99_999, dependencies: .inert
        )
        batchManager.enableNotifications = false
        await batchManager.batchTerminate(pending.targets)
        XCTAssertEqual(signaler.sent.map(\.pid), [800, 801])
        XCTAssertEqual(signaler.sent.map(\.signal), [SIGTERM, SIGTERM])
    }

    func testChildLookupFollowsEachInventoryRead() async {
        let parent = row(pid: 820)
        let inventory = ControlTestInventory([
            .success([parent, row(pid: 821, parent: 820), row(pid: 99_999, parent: 822), row(pid: 822)]),
            .success([parent])
        ])
        let manager = manager(inventory)
        await manager.loadProcessList(showMessage: false)
        XCTAssertTrue(manager.hasChildProcesses(parent))
        XCTAssertFalse(manager.hasChildProcesses(row(pid: 821, parent: 820)))
        XCTAssertFalse(manager.hasChildProcesses(row(pid: 822)), "TaskScope is not a child to stop")

        await manager.loadProcessList(showMessage: false)
        XCTAssertFalse(manager.hasChildProcesses(parent), "The answer follows the newest read")
    }

    /// Review follow-up: on launchd the family is nearly every process, and a
    /// session component's children include what keeps the session running.
    func testStopWithChildrenIsRefusedForLaunchdAndSystemProcesses() async {
        let launchd = row(pid: 1, parent: 0, path: "/sbin/launchd", uid: 0)
        let loginwindow = row(pid: 840, parent: 1, path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")
        let app = row(pid: 841, parent: 1)
        let fixture = await Batch10.fixture(processes: [
            launchd, loginwindow, app,
            row(pid: 842, parent: 841, path: "/opt/homebrew/bin/node"),
            row(pid: 843, parent: 840, path: "/opt/homebrew/bin/node")
        ])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)

        view.requestStopWithChildren(launchd)
        XCTAssertNil(state.pendingBatchTermination, "launchd's children are most of the session")
        XCTAssertEqual(
            fixture.manager.message,
            "Stop With Children is not available for launchd. This is launchd or the kernel task; stopping its children would stop most of your session."
        )
        XCTAssertNotNil(view.stopWithChildrenUnavailableReason(for: launchd))

        view.requestStopWithChildren(loginwindow)
        XCTAssertNil(state.pendingBatchTermination)
        XCTAssertEqual(
            fixture.manager.message,
            "Stop With Children is not available for loginwindow. It is part of macOS; stopping it and its children can log you out or leave your session unresponsive."
        )

        XCTAssertNil(view.stopWithChildrenUnavailableReason(for: app), "An ordinary app with a child is offered")
        view.requestStopWithChildren(app)
        XCTAssertEqual(state.pendingBatchTermination?.targets.map(\.pid), [841, 842])
    }

    func testIneligibleDescendantsAreLeftOutWithTheirSubtrees() async throws {
        let parent = row(pid: 850)
        let fixture = await Batch10.fixture(processes: [
            parent,
            row(pid: 851, parent: 850, path: "/Applications/Example.app/Contents/MacOS/Worker"),
            // Not the user's: left out, and so is the user's process under it.
            row(pid: 852, parent: 850, path: "/Library/PrivilegedHelperTools/com.example.helper", uid: 0),
            row(pid: 853, parent: 852, path: "/opt/homebrew/bin/node"),
            // A macOS component started for the app.
            row(pid: 854, parent: 850, path: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        ])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)

        view.requestStopWithChildren(parent)

        let pending = try XCTUnwrap(state.pendingBatchTermination)
        XCTAssertEqual(pending.targets.map(\.pid), [850, 851])
        XCTAssertTrue(
            pending.summary.contains("3 more processes in its tree are left out: only your own processes, other than TaskScope, GlobalProtect and parts of macOS, are stopped, and nothing below a process that is left out."),
            pending.summary
        )
    }

    /// Review follow-up: children are found by the parent's PID, so a row whose
    /// PID now belongs to another process must not stop that process's children.
    func testStopWithChildrenNeedsTheParentsCurrentIdentity() async {
        let fixture = await Batch10.fixture(processes: [
            row(pid: 860), row(pid: 861, parent: 860, path: "/opt/homebrew/bin/node")
        ])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)

        // The row the menu was opened on, from before PID 860 was reused.
        view.requestStopWithChildren(row(pid: 860, start: "Fri Jul 25 08:00:00 2026"))
        XCTAssertNil(state.pendingBatchTermination, "The new PID 860's child must not be stopped")
        XCTAssertEqual(fixture.manager.message, "Example's identity changed; nothing was stopped.")

        view.requestStopWithChildren(row(pid: 870))
        XCTAssertNil(state.pendingBatchTermination)
        XCTAssertEqual(fixture.manager.message, "Example is no longer running.")

        view.requestStopWithChildren(row(pid: 860))
        XCTAssertEqual(state.pendingBatchTermination?.targets.map(\.pid), [860, 861])
    }

    func testAProcessWithoutChildrenOffersNoFamilyStop() async {
        let lone = row(pid: 810)
        let fixture = await Batch10.fixture(processes: [lone])
        defer { fixture.stores.cleanup() }
        let state = ProcessConfirmationState()
        Batch10.popover(fixture, state: state).requestStopWithChildren(lone)
        XCTAssertNil(state.pendingBatchTermination)
    }

    // MARK: - Restart

    func testRestartQuitsThenOpensWithOneReport() async {
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(label: "com.example.agent", plistPath: "/Users/Shared/com.example.agent.plist")]
        )
        let lifecycle = ControlTestLifecycle()
        lifecycle.unloadResult = LifecycleBatchResult(jobs: [LifecycleJobResult(label: "com.example.agent", state: .changed, detail: "Unloaded and verified.")])
        lifecycle.bootstrapResult = LifecycleBatchResult(jobs: [LifecycleJobResult(label: "com.example.agent", state: .changed, detail: "Loaded and verified.")])
        let running = row(pid: 900)
        // Quit: before and after.
        let inventory = ControlTestInventory([
            .success([running]), .success([]),
            // Open: before restoring services, after them, after launching.
            .success([]), .success([]), .success([running])
        ])
        let manager = manager(inventory, lifecycle: lifecycle)
        manager.dependencies.watchedPresets = { [preset] }

        let result = await manager.restart(preset)

        XCTAssertEqual(result, TaskScopeCommandResult(status: .completed, message: "Restarted Example."))
        XCTAssertEqual(manager.message, "Restarted Example.")
        XCTAssertEqual(lifecycle.calls, ["unload", "terminate:all", "settle", "daemon.ensure", "bootstrap", "open", "wait"])
        XCTAssertEqual(manager.lifecycleReport?.title, "Example Restart")
        XCTAssertEqual(manager.lifecycleReport?.jobs.map(\.detail), ["Unloaded and verified.", "Loaded and verified."])
    }

    func testRestartOpensNothingWhenTheQuitFails() async {
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        let lifecycle = ControlTestLifecycle()
        let manager = manager(ControlTestInventory([.failure(.commandFailed("ps failed"))]), lifecycle: lifecycle)

        let result = await manager.restart(preset)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Could not restart Example: Could not read the process list; Example was not stopped.")
        XCTAssertFalse(lifecycle.calls.contains("open"))
        XCTAssertEqual(manager.lifecycleDiagnostics.failures(for: preset.id).first?.action, .close)
    }

    /// Review follow-up: Restart's Open step turns Keep Off off, so a kept-off
    /// preset is not restarted, and its card says why.
    func testRestartIsNotAvailableWhileThePresetIsKeptOff() async throws {
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: [], protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        let lifecycle = ControlTestLifecycle()
        let manager = manager(ControlTestInventory(repeating: .success([])), lifecycle: lifecycle)
        manager.dependencies.watchedPresets = { [preset] }
        manager.dependencies.isPresetKeptOff = { _ in true }
        var intentWrites: [Bool] = []
        manager.dependencies.setPresetKeptOff = { _, keptOff in intentWrites.append(keptOff) }

        let result = await manager.restart(preset)

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(
            result.message,
            "Restart is not available while Keep Example Off is on: restarting opens Example, which turns Keep Off off. Turn Keep Off off first."
        )
        XCTAssertEqual(manager.message, result.message)
        XCTAssertTrue(lifecycle.calls.isEmpty, "\(lifecycle.calls)")
        XCTAssertTrue(intentWrites.isEmpty, "Keep Off must stay on")

        let card = PresetCard(snapshot: .init(preset: preset, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {},
                              onQuitAll: {}, isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
                              onRestart: {})
        let restart = try card.inspect().find(button: "Restart…")
        XCTAssertTrue(restart.isDisabled())
        XCTAssertEqual(
            try restart.help().string(),
            "Not available while Keep Off is on: restarting opens the app, which turns Keep Off off."
        )
        let running = PresetCard(snapshot: .init(preset: preset, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {},
                                 onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
                                 onRestart: {})
        XCTAssertFalse(try running.inspect().find(button: "Restart…").isDisabled())
    }

    func testRestartIsNotOfferedForGlobalProtect() async throws {
        let lifecycle = ControlTestLifecycle()
        let manager = manager(ControlTestInventory([]), lifecycle: lifecycle)
        let result = await manager.restart(.globalProtect)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.message, "Restart is not offered for the built-in GlobalProtect preset. Use Quit All, then Open.")
        XCTAssertTrue(lifecycle.calls.isEmpty)

        let custom = WatchedAppPreset(displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Example Helper"],
                                      protectedProcessNames: [], appPath: "/Applications/Example.app")
        let customCard = PresetCard(snapshot: .init(preset: custom, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {},
                                    onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
                                    onRestart: {})
        XCTAssertNoThrow(try customCard.inspect().find(button: "Restart…"))
        let builtInCard = PresetCard(snapshot: .init(preset: .globalProtect, runningNames: []), onOpen: {}, onQuitApp: {},
                                     onQuitHelpers: {}, onQuitAll: {}, isKeptOff: false, isKeepOffControlEnabled: true,
                                     onKeepOffChanged: { _ in }, onRestart: {})
        XCTAssertThrowsError(try builtInCard.inspect().find(button: "Restart…"))

        let pending = ProcessConfirmationState.PendingPresetAction(preset: custom, action: .restart)
        XCTAssertEqual(pending.title, "Restart Example?")
        XCTAssertEqual(pending.confirmTitle, "Restart")
        XCTAssertEqual(
            TaskScopePopoverView.presetConfirmationMessage(for: pending),
            "TaskScope will quit Example and its helpers (Example, Example Helper), as Quit App and Helpers does, then open it again. "
                + "If the quit does not complete, nothing is opened. One report shows both steps. "
                + PresetStopScope.forceStopDisclosure
        )
    }
}

// MARK: - Fakes

private final class ControlTestInventory: ProcessInventoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[AppProcess], ProcessInventoryError>]
    private let repeating: Result<[AppProcess], ProcessInventoryError>?
    private var count = 0

    init(_ results: [Result<[AppProcess], ProcessInventoryError>]) {
        self.results = results
        repeating = nil
    }

    init(repeating result: Result<[AppProcess], ProcessInventoryError>) {
        results = []
        repeating = result
    }

    var loads: Int { lock.withLock { count } }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        lock.withLock {
            count += 1
            if let repeating { return repeating }
            guard !results.isEmpty else {
                XCTFail("Unscripted inventory read")
                return .failure(.commandFailed("unscripted"))
            }
            return results.count == 1 ? results[0] : results.removeFirst()
        }
    }
}

private final class ControlTestSignaler: ProcessSignaling, @unchecked Sendable {
    struct Sent: Equatable {
        var signal: Int32
        var pid: Int32
    }

    var answer: ProcessSignalDelivery = .delivered
    private(set) var sent: [Sent] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        deliver(signal, to: pid) == .delivered
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        sent.append(Sent(signal: signal, pid: pid))
        return answer
    }

    func isAlive(_ pid: Int32) -> Bool { false }
}

private final class ControlTestLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var unloadResult = LifecycleBatchResult.notNeeded
    var bootstrapResult = LifecycleBatchResult.notNeeded

    var calls: [String] { lock.withLock { recorded } }
    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    func appBundleExists(at path: String) -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { record("open"); return .opened }
    func settleAfterProcessChange() async { record("settle") }
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { record("terminate:main"); return .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminate.helper"); return .signalled
    }
    func terminateProcesses(for preset: WatchedAppPreset, scope: PresetStopScope) async -> [ProcessTerminationOutcome] {
        record("terminate:\(scope)"); return [.signalled]
    }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { record("wait"); return true }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("unload"); return unloadResult }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        record("unload.preserving"); return unloadResult
    }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("bootstrap"); return bootstrapResult }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        record("disable"); return .notNeeded
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("enable"); return .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("daemon.ensure"); return .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        XCTFail("No administrator step"); return .notNeeded
    }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { record("daemon.enable"); return .notNeeded }
}
