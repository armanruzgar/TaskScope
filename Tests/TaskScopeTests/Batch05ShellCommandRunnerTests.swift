import AppKit
import Darwin
import XCTest
@testable import TaskScope

/// Shell runner regressions: stop escalation, descriptors, reaping, quitting.
/// Every signal goes to a process group the test's own command created.
final class Batch05ShellCommandRunnerTests: XCTestCase {
    /// The 500 ms SIGKILL fallback is the only thing that ends a command whose
    /// group leader itself ignores SIGTERM.
    func testTimeoutKillsAGroupLeaderThatIgnoresTERM() async {
        let probe = Batch05ChildProbe()
        let started = ContinuousClock.now

        let result = await ShellCommandRunner.run(
            "trap '' TERM; /bin/sleep 30; /bin/sleep 0",
            timeout: 0.2,
            waitForChild: { probe.wait($0, $1, $2) }
        )

        XCTAssertEqual(result.exitCode, ShellCommandRunner.timedOutExitCode, "\(result)")
        XCTAssertLessThan(
            started.duration(to: .now), .seconds(15),
            "The timeout must end a leader that ignores TERM, not wait for its 30-second sleep"
        )
        guard let shell = probe.childPID else {
            return XCTFail("The runner must probe exactly one child PID")
        }
        await Self.assertDisappears(-shell)
    }

    /// The shipped app ignores SIGTERM process-wide (its termination handler
    /// turns it into an AppKit quit). Ignored dispositions survive exec, so the
    /// spawn must reset them or every stop's SIGTERM would be ignored.
    func testCommandsStartWithDefaultDispositionsWhileTheAppIgnoresTERM() async {
        let previous = signal(SIGTERM, SIG_IGN)
        let direct = await ShellCommandRunner.run("kill -TERM $$; echo survived")
        let nested = await ShellCommandRunner.run("/bin/sh -c 'kill -TERM $$; echo survived'")
        signal(SIGTERM, previous)

        XCTAssertEqual(direct.terminatedBySignal, SIGTERM, "\(direct)")
        XCTAssertFalse(direct.stdout.contains("survived"), "\(direct)")
        XCTAssertFalse(nested.stdout.contains("survived"), "\(nested)")
    }

    /// A member that survives one SIGKILL to the group (a fork in progress
    /// escapes it; here the first SIGKILL is dropped to make that certain) must
    /// still be killed: a stop completes only once the group is empty.
    func testStopKillsUntilTheProcessGroupIsEmpty() async throws {
        let marker = Self.temporaryFile("kill-until-empty")
        defer { try? FileManager.default.removeItem(at: marker) }
        let signals = FirstGroupKillDropper()
        let hooks = batch05Hooks { hooks in
            hooks.signalGroup = { signals.send($0, $1) }
        }
        let command = """
        /bin/sh -c 'trap "" TERM; printf "%s:%s" "$PPID" "$$" > "$1"; /bin/sleep 30' sh \
        \(ShellCommandRunner.shellQuoted(marker.path)) &
        wait $!
        """
        let task = Task { await ShellCommandRunner.run(command, timeout: 30, hooks: hooks) }

        let pids = try await Self.reportedProcessIdentifiers(at: marker)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode, "\(result)")
        XCTAssertTrue(signals.droppedAKill, "The test must have dropped one SIGKILL")
        await Self.assertDisappears(-pids.group)
        await Self.assertDisappears(pids.descendant)
    }

    /// When something else collects the child's exit status, waitpid fails
    /// with ECHILD. The command must still complete, and its group, whose ID
    /// may already name other processes, must never be signalled.
    func testLostExitStatusCompletesWithoutSignallingTheGroup() async {
        let signals = RecordedGroupSignals()
        let hooks = batch05Hooks { hooks in
            hooks.signalGroup = { signals.record($0, $1) }
        }
        // Reaps for real, then answers the way a second reaper is answered.
        let lostStatus: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { pid, status, options in
            let waited = Darwin.waitpid(pid, status, options)
            guard waited == pid else { return waited }
            errno = ECHILD
            return -1
        }

        let result = await Self.result(within: .seconds(15)) {
            await ShellCommandRunner.run("exit 3", timeout: 60, waitForChild: lostStatus, hooks: hooks)
        }

        guard let result else {
            return XCTFail("run() never returned after waitpid reported ECHILD")
        }
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertEqual(result.stderr, "The command's exit status could not be collected.")
        XCTAssertNil(result.terminatedBySignal)
        XCTAssertEqual(signals.all, [], "A child whose status is lost must never be signalled")
    }

    /// The real trigger: with SIGCHLD ignored in this process the kernel reaps
    /// every child itself, so waitpid only ever answers ECHILD.
    func testCommandsCompleteWhileSIGCHLDIsIgnored() async {
        let signals = RecordedGroupSignals()
        let hooks = batch05Hooks { hooks in
            hooks.signalGroup = { signals.record($0, $1) }
        }

        let previous = signal(SIGCHLD, SIG_IGN)
        let result = await Self.result(within: .seconds(15)) {
            await ShellCommandRunner.run("exit 3", timeout: 60, hooks: hooks)
        }
        signal(SIGCHLD, previous)

        guard let result else {
            return XCTFail("run() never returned while the kernel reaped its child")
        }
        XCTAssertEqual(result.exitCode, -1, "\(result)")
        XCTAssertEqual(result.stderr, "The command's exit status could not be collected.")
        XCTAssertEqual(signals.all, [])
    }

    /// Without a free descriptor, `Pipe()` handed out descriptor 0 (standard
    /// input), which was made nonblocking and spawned with, and the failure
    /// read "Bad file descriptor". The real error must be reported, nothing
    /// left open, and descriptor 0 left alone.
    func testPipeCreationFailureIsReportedWithoutTouchingStandardInput() async {
        let standardInputFlags = fcntl(STDIN_FILENO, F_GETFL)
        for failingCall in [1, 2] {
            let pipes = ScriptedPipeFactory(failingCall: failingCall)
            let hooks = batch05Hooks { hooks in
                hooks.makePipe = { pipes.make($0) }
            }

            let result = await ShellCommandRunner.run("/usr/bin/true", hooks: hooks)

            XCTAssertEqual(result.exitCode, -1, "\(result)")
            XCTAssertEqual(result.stderr, "Could not start the command: Too many open files.")
            XCTAssertEqual(pipes.callCount, failingCall)
            for descriptor in pipes.created {
                errno = 0
                XCTAssertEqual(fcntl(descriptor, F_GETFD), -1, "Descriptor \(descriptor) was left open")
                XCTAssertEqual(errno, EBADF)
            }
        }
        XCTAssertEqual(fcntl(STDIN_FILENO, F_GETFL), standardInputFlags, "Descriptor 0 must not be touched")
    }

    /// A run that starts cancelled creates no descriptors, so it has nothing to
    /// drain: the old drain was a blocking read that waited for as long as
    /// another command's child held an inherited copy of the write end.
    func testRunThatStartsCancelledCreatesNoDescriptors() async {
        let pipes = ScriptedPipeFactory(failingCall: 0)
        let hooks = batch05Hooks { hooks in
            hooks.makePipe = { pipes.make($0) }
        }
        let task = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return await ShellCommandRunner.run("/usr/bin/true", timeout: 10, hooks: hooks)
        }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode)
        XCTAssertEqual(pipes.callCount, 0)
    }

    /// A child inherits only its three standard streams: never another
    /// command's pipes, nor any other descriptor the app holds without
    /// FD_CLOEXEC. Its standard input is an empty /dev/null.
    func testCommandsInheritOnlyTheirStandardStreams() async {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        // Above anything the shell or ls open for themselves.
        let inheritable = fcntl(descriptors[1], F_DUPFD, 200)
        defer { [descriptors[0], descriptors[1], inheritable].forEach { _ = close($0) } }
        XCTAssertGreaterThanOrEqual(inheritable, 200)
        XCTAssertEqual(fcntl(inheritable, F_GETFD) & FD_CLOEXEC, 0)

        let listing = await ShellCommandRunner.run("/bin/ls /dev/fd")
        let open = Set(listing.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })

        XCTAssertEqual(listing.exitCode, 0, "\(listing)")
        XCTAssertTrue(open.isSuperset(of: [0, 1, 2]), listing.stdout)
        XCTAssertFalse(open.contains(inheritable), "The child inherited descriptor \(inheritable): \(listing.stdout)")

        let input = await ShellCommandRunner.run("/bin/cat; echo status=$?", timeout: 5)
        XCTAssertEqual(input.stdout, "status=0", "\(input)")
    }

    /// Quitting stops every command in flight and waits for them, instead of
    /// leaving them running re-parented to launchd with no timeout, and no
    /// command starts after that.
    func testShutDownStopsCommandsInFlightAndRefusesNewOnes() async {
        let registry = ShellCommandRunner.ExecutionRegistry()
        let hooks = batch05Hooks { hooks in
            hooks.registry = registry
        }
        let started = Self.temporaryFile("shutdown-started")
        let finished = Self.temporaryFile("shutdown-finished")
        defer {
            try? FileManager.default.removeItem(at: started)
            try? FileManager.default.removeItem(at: finished)
        }
        let probe = Batch05ChildProbe()
        let command = "/usr/bin/touch \(ShellCommandRunner.shellQuoted(started.path)); /bin/sleep 30; "
            + "/usr/bin/touch \(ShellCommandRunner.shellQuoted(finished.path))"
        let task = Task {
            await ShellCommandRunner.run(command, timeout: 60, waitForChild: { probe.wait($0, $1, $2) }, hooks: hooks)
        }
        let running = await Self.eventually { FileManager.default.fileExists(atPath: started.path) }
        XCTAssertTrue(running, "The command never started")

        XCTAssertTrue(registry.shutDown(waitingAtMost: 10), "Every command must finish within the bound")
        let result = await task.value
        XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode, "\(result)")
        if let shell = probe.childPID {
            await Self.assertDisappears(-shell)
        } else {
            XCTFail("The runner must probe exactly one child PID")
        }

        let refused = await ShellCommandRunner.run(
            "/usr/bin/touch \(ShellCommandRunner.shellQuoted(finished.path))",
            hooks: hooks
        )
        XCTAssertEqual(refused.exitCode, ShellCommandRunner.cancelledExitCode)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path), "No command may run after shutdown")
    }

    /// The app delegate stops the commands still running when TaskScope quits,
    /// and the app's commands are tracked by the registry it stops.
    @MainActor
    func testQuittingStopsTheCommandsStillRunning() {
        let defaults = InMemoryUserDefaults(suiteName: "TaskScope.Batch05.Quit.\(UUID().uuidString)")!
        let session = TaskScopeLaunchSession(
            context: .interactive,
            runtime: .init(
                bundleIdentifier: "example.TaskScope", processID: 10, userID: 501,
                runningInstances: { [] }, reopen: { _ in }, terminate: {}
            ),
            standardDefaults: { defaults }
        )
        var stops = 0
        let delegate = AppDelegate(
            launchSession: session,
            commandBus: AppCommandBus(),
            terminationHandler: TaskScopeTerminationHandler(install: { _ in {} }, terminate: {}),
            runtime: .init(
                launchSignal: { .init(arguments: ["TaskScope"], launchedAsLoginItem: false, receivedOpenURL: false) },
                isActive: { false }, setActivationPolicy: { _ in }, registerURLHandler: { _ in },
                configureAccessibility: {}, registerHotkey: {}, hideAutomaticWindows: {},
                restorePreviousApplication: {}, presentMainWindow: {}, waitForInteractiveLaunch: {},
                stopRunningCommands: { stops += 1 }
            )
        )

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(stops, 1)
        XCTAssertTrue(ShellCommandRunner.Hooks().registry === ShellCommandRunner.liveExecutions)
    }

    // MARK: - Helpers

    static func temporaryFile(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-\(label)-\(UUID().uuidString)")
    }

    /// Polls every 10 ms for up to 15 seconds: a loaded machine can take
    /// seconds to start a shell.
    static func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// Reads `group:descendant`, written in one printf call by the command.
    static func reportedProcessIdentifiers(at marker: URL) async throws -> (group: Int32, descendant: Int32) {
        _ = await eventually { !(FileManager.default.contents(atPath: marker.path)?.isEmpty ?? true) }
        let contents = try String(contentsOf: marker, encoding: .utf8)
        let components = contents.split(separator: ":")
        guard components.count == 2, let group = Int32(components[0]), let descendant = Int32(components[1]) else {
            XCTFail("Invalid process-group handshake: \(contents)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return (group, descendant)
    }

    /// A negative `pid` names a process group, as it does for `kill`. Killed
    /// members stay visible until they are reaped, so this polls for up to ten
    /// seconds; every surviving process in these tests sleeps for 30.
    static func assertDisappears(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let survivor = pid < 0 ? "A process in group \(-pid)" : "Descendant PID \(pid)"
        XCTFail("\(survivor) survived command termination.", file: file, line: line)
    }

    /// The operation's result, or nil when it has not returned in time. A run
    /// that never returns is left suspended rather than hanging the test.
    static func result(
        within limit: Duration,
        of operation: @escaping @Sendable () async -> ShellCommandResult
    ) async -> ShellCommandResult? {
        let box = ResultBox()
        Task { box.store(await operation()) }
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let value = box.value { return value }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return box.value
    }
}

/// Runner hooks with some replaced, as an immutable value a task can capture.
func batch05Hooks(_ configure: (inout ShellCommandRunner.Hooks) -> Void) -> ShellCommandRunner.Hooks {
    var hooks = ShellCommandRunner.Hooks()
    configure(&hooks)
    return hooks
}

/// Records the PIDs the runner probes, so a test never depends on the child
/// printing its PID before a stop.
final class Batch05ChildProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probedPIDs: Set<pid_t> = []

    func wait(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ options: Int32) -> pid_t {
        lock.withLock { _ = probedPIDs.insert(pid) }
        return Darwin.waitpid(pid, status, options)
    }

    /// The command's child, or nil unless exactly one PID was probed.
    var childPID: pid_t? { lock.withLock { probedPIDs.count == 1 ? probedPIDs.first : nil } }
}

/// Records the group signals a run sends without delivering any of them.
final class RecordedGroupSignals: @unchecked Sendable {
    struct Signal: Equatable {
        var group: pid_t
        var signal: Int32
    }

    private let lock = NSLock()
    private var signals: [Signal] = []

    func record(_ group: pid_t, _ signal: Int32) -> Int32 {
        lock.withLock { signals.append(Signal(group: group, signal: signal)) }
        errno = ESRCH
        return -1
    }

    var all: [Signal] { lock.withLock { signals } }
}

/// Delivers group signals for real, except the first SIGKILL.
final class FirstGroupKillDropper: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = false

    func send(_ group: pid_t, _ signal: Int32) -> Int32 {
        let drop = lock.withLock { () -> Bool in
            guard signal == SIGKILL, !dropped else { return false }
            dropped = true
            return true
        }
        return drop ? 0 : Darwin.kill(-group, signal)
    }

    var droppedAKill: Bool { lock.withLock { dropped } }
}

/// Creates real pipes, except that call number `failingCall` fails as if the
/// process had no free descriptor (0 never fails).
final class ScriptedPipeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCall: Int
    private var calls = 0
    private var descriptors: [Int32] = []

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func make(_ pipeDescriptors: UnsafeMutablePointer<Int32>) -> Int32 {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call == failingCall {
            errno = EMFILE
            return -1
        }
        let result = Darwin.pipe(pipeDescriptors)
        if result == 0 {
            lock.withLock { descriptors += [pipeDescriptors[0], pipeDescriptors[1]] }
        }
        return result
    }

    var callCount: Int { lock.withLock { calls } }
    var created: [Int32] { lock.withLock { descriptors } }
}

/// Cancels a run from inside its reap window (`Hooks.afterReap`): after the
/// child was reaped and before the command completed.
final class ReapWindowCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private let attached = DispatchSemaphore(value: 0)
    private var task: Task<ShellCommandResult, Never>?
    private var cancelled = false

    func attach(_ task: Task<ShellCommandResult, Never>) {
        lock.withLock { self.task = task }
        attached.signal()
    }

    /// A very fast child can be reaped before `attach` runs; wait for it.
    func cancelInReapWindow() {
        guard attached.wait(timeout: .now() + 5) == .success else { return }
        let task = lock.withLock { () -> Task<ShellCommandResult, Never>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    var cancelledInReapWindow: Bool { lock.withLock { cancelled } }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ShellCommandResult?

    func store(_ result: ShellCommandResult) {
        lock.withLock { stored = result }
    }

    var value: ShellCommandResult? { lock.withLock { stored } }
}
