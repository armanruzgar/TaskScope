import Darwin
import XCTest
@testable import TaskScope

final class ShellCommandRunnerTests: XCTestCase {
    func testChildPreservesUTF8WithCDateAndNumberFormatting() {
        let sanitized = ShellCommandRunner.childEnvironment(
            from: ["LANG": "de_DE.UTF-8", "LC_NUMERIC": "de_DE.UTF-8", "LC_TIME": "de_DE.UTF-8",
                   "LC_CTYPE": "C", "LC_ALL": "C", "PATH": "/usr/bin"]
        )
        XCTAssertEqual(sanitized, [
            "LC_CTYPE": "UTF-8", "LC_TIME": "C", "LC_NUMERIC": "C", "TZ": "UTC0", "PATH": "/usr/bin"
        ])
    }

    func testChildPrintsPSDecimalsUsingConfiguredLocale() async {
        let result = await ShellCommandRunner.runShellScript(
            #"set -o pipefail; /usr/bin/printf '%s|%s|%s|%s|%s|' "${LC_ALL-unset}" "${LANG-unset}" "$LC_CTYPE" "$LC_TIME" "$LC_NUMERIC"; /bin/ps -o pcpu= -p $$ | /usr/bin/tr -d ' '"#
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("unset|unset|UTF-8|C|C|"), result.stdout)
        XCTAssertFalse(result.stdout.contains(","), "ps must print C-locale decimals: \(result.stdout)")
        XCTAssertNotNil(Double(result.stdout.components(separatedBy: "|").last ?? ""))
    }

    func testChildPinsUTCRegardlessOfInheritedTimeZone() async {
        for timeZone in ["America/New_York", "Europe/Berlin", "UTC0"] {
            XCTAssertEqual(ShellCommandRunner.childEnvironment(from: ["TZ": timeZone])["TZ"], "UTC0")
        }
        XCTAssertEqual(ShellCommandRunner.childEnvironment(from: [:])["TZ"], "UTC0")

        let result = await ShellCommandRunner.runShellScript(#"/usr/bin/printf '%s' "$TZ""#)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "UTC0")
    }

    /// One invalid byte in a process name must not erase the whole output.
    func testInvalidUTF8OutputIsDecodedLossilyInsteadOfDropped() async {
        let result = await ShellCommandRunner.run(executable: "/usr/bin/printf", arguments: ["before\\377\\376after"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.hasPrefix("before"), result.stdout)
        XCTAssertTrue(result.stdout.hasSuffix("after"), result.stdout)
        XCTAssertTrue(result.stdout.contains("\u{FFFD}"))
    }

    /// Commands used to run through `/bin/zsh -f`, where `-f` kept a user's
    /// `.zshenv` from aliasing the tools TaskScope parses or printing into
    /// their output. Now no shell runs at all: no production source may name
    /// a shell, or `env`, as the program to run. (The administrator request's
    /// root script is shell code, but `do shell script` runs it.)
    func testNoProductionCommandRunsThroughAShell() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TaskScope")
        // Hidden folders are skipped, as SwiftPM skips them when it collects the
        // target's sources (a checkout can hold worktrees under `.claude`).
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "The scan must see the production sources at \(sources.path)")

        let programs = ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/csh", "/bin/tcsh", "/bin/ksh", "/bin/dash", "/usr/bin/env"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for program in programs {
                XCTAssertFalse(
                    source.contains("\"\(program)\""),
                    "\(file.lastPathComponent) names \(program) as a program to run"
                )
            }
        }
    }

    func testTerminationBySignalIsReportedAsSuch() async {
        let signalled = await ShellCommandRunner.runShellScript("kill -TERM $$")
        let exited = await ShellCommandRunner.runShellScript("exit 7")

        XCTAssertEqual(signalled.terminatedBySignal, SIGTERM)
        XCTAssertFalse(signalled.succeeded)
        XCTAssertEqual(signalled.failureDescription, "terminated by SIGTERM")
        XCTAssertNil(exited.terminatedBySignal)
        XCTAssertEqual(exited.failureDescription, "exited with status 7")
    }

    /// A stop that races the spawn must never report "cancelled" while the
    /// child keeps running unkilled: whenever the result is a cancellation, the
    /// command's side effect must never appear afterwards.
    func testCancellationRacingStartNeverLeavesTheChildRunningUnreported() async throws {
        for iteration in 0..<30 {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskscope-cancel-race-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let command = "/bin/sleep 0.05; /usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))"
            let task = Task {
                await ShellCommandRunner.runShellScript(command, timeout: 5)
            }
            if iteration % 2 == 0 {
                await Task.yield()
            }
            task.cancel()
            let result = await task.value

            if result.exitCode == ShellCommandRunner.cancelledExitCode {
                try? await Task.sleep(nanoseconds: 150_000_000)
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: marker.path),
                    "iteration \(iteration): the command ran to completion after being reported cancelled"
                )
            } else {
                XCTAssertEqual(result.exitCode, 0, "iteration \(iteration): \(result)")
            }
        }
    }

    /// The cancellation arrives after the child was reaped but before the
    /// command completed: the real exit is reported, and the reaped PID's
    /// group, whose ID may already be reused, is never signalled.
    func testCommandThatExitedBeforeCancellationReportsItsRealExit() async {
        let canceller = ReapWindowCanceller()
        let signals = RecordedGroupSignals()
        let hooks = batch05Hooks { hooks in
            hooks.afterReap = { canceller.cancelInReapWindow() }
            hooks.signalGroup = { signals.record($0, $1) }
        }
        let task = Task {
            await ShellCommandRunner.runShellScript("exit 3", timeout: 10, hooks: hooks)
        }
        canceller.attach(task)

        let result = await task.value

        XCTAssertTrue(canceller.cancelledInReapWindow, "The cancellation must arrive after the reap")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertNil(result.terminatedBySignal)
        XCTAssertFalse(result.stderr.contains("cancelled"))
        XCTAssertEqual(signals.all, [], "A reaped child's group must never be signalled")
    }

    /// Exit notification comes from a dispatch source plus a non-blocking
    /// reap, not from one blocked worker thread per command; many concurrent
    /// short commands must all complete.
    func testManyConcurrentShortCommandsAllCompleteAndAreReaped() async {
        let results = await withTaskGroup(of: ShellCommandResult.self) { group in
            for index in 0..<24 {
                group.addTask {
                    await ShellCommandRunner.runShellScript("/usr/bin/printf '%s' \(index); exit \(index % 3)", timeout: 5)
                }
            }
            var collected: [ShellCommandResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, 24)
        for result in results {
            let index = Int32(result.stdout) ?? -1
            XCTAssertGreaterThanOrEqual(index, 0, "unexpected output: \(result)")
            XCTAssertEqual(result.exitCode, index % 3)
            XCTAssertNil(result.terminatedBySignal)
        }
    }

    func testBurstsOfImmediatelyExitingChildrenCompleteAndAreReaped() async {
        let finished = expectation(description: "all immediate-exit bursts complete")
        let bursts = Task {
            for _ in 0..<8 {
                await withTaskGroup(of: ShellCommandResult.self) { group in
                    for _ in 0..<24 {
                        group.addTask {
                            let probe = DeferredChildWaitProbe(deferredProbes: 3)
                            let started = ContinuousClock.now
                            let result = await ShellCommandRunner.runShellScript(
                                "printf '%s' $$; exit 3", timeout: 4,
                                waitForChild: { probe.wait($0, $1, $2) }
                            )
                            XCTAssertLessThan(
                                started.duration(to: .now), .seconds(2),
                                "An immediate exit must not wait for the command timeout"
                            )
                            return result
                        }
                    }
                    for await result in group {
                        XCTAssertEqual(result.exitCode, 3, result.stderr)
                        guard let pid = Int32(result.stdout), pid > 0 else {
                            XCTFail("Child did not report its PID")
                            continue
                        }
                        var status: Int32 = 0
                        errno = 0
                        let waited = waitpid(pid, &status, WNOHANG)
                        let waitError = errno
                        XCTAssertEqual(waited, -1)
                        XCTAssertEqual(waitError, ECHILD, "Completion must include reaping the child")
                    }
                }
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 15)
        bursts.cancel()
        await bursts.value
    }

    func testRunCapturesOutputAndExitStatus() async {
        let result = await ShellCommandRunner.runShellScript(
            "/usr/bin/printf 'standard output'; /usr/bin/printf 'standard error' >&2; exit 7"
        )

        XCTAssertEqual(result.stdout, "standard output")
        XCTAssertEqual(result.stderr, "standard error")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testRunTimesOutAndReturnsPromptly() async {
        let started = Date()

        let result = await ShellCommandRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)

        XCTAssertEqual(result.exitCode, -3)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRunRespondsToTaskCancellation() async {
        let started = Date()
        let task = Task {
            await ShellCommandRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 10)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertEqual(result.stderr, "Command cancelled.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// On a loaded machine the 0.25 s timeout can arrive before the descendant
    /// has started, ignored TERM, and reported. Such an attempt must still time
    /// out promptly and leave nothing in the shell's process group, but it does
    /// not prove that SIGKILL reached a TERM-ignoring descendant, so it is
    /// retried.
    func testTimeoutTerminatesDescendantsThatIgnoreTermAndHoldPipesOpen() async throws {
        let attempts = 10
        for _ in 0..<attempts {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskscope-timeout-group-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }
            let probe = RecordingChildWaitProbe()

            let started = Date()
            let result = await ShellCommandRunner.runShellScript(
                descendantHoldingPipesCommand(marker: marker),
                timeout: 0.25,
                waitForChild: { probe.wait($0, $1, $2) }
            )
            XCTAssertEqual(result.exitCode, -3)
            XCTAssertTrue(result.stderr.contains("timed out"))
            XCTAssertLessThan(Date().timeIntervalSince(started), 2)
            // Take the shell's PID from the waitpid seam. The shell leads its
            // own process group, so an empty group also rules out a descendant
            // that never reported.
            guard let shell = probe.childPID, shell > 0 else {
                return XCTFail("The runner must probe exactly one child PID")
            }
            await Self.assertProcessDisappears(-shell)

            // `>` creates the marker before printf writes to it, and with the
            // group gone nothing can write to it any more. A missing or empty
            // marker means the stop came before the report.
            guard let report = try? String(contentsOf: marker, encoding: .utf8), !report.isEmpty else {
                continue
            }
            let pids = try processIdentifiers(in: report)
            XCTAssertEqual(pids.group, shell, "The descendant must report the shell as its parent")
            await Self.assertProcessDisappears(pids.descendant)
            return
        }
        XCTFail("None of \(attempts) attempts reported a descendant before the timeout")
    }

    func testCancellationTerminatesDescendantsThatIgnoreTermAndHoldPipesOpen() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-cancel-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let command = descendantHoldingPipesCommand(marker: marker)
        let task = Task {
            await ShellCommandRunner.runShellScript(command, timeout: 10)
        }

        let pids = try await waitForProcessIdentifiers(from: marker)
        // Time the cancellation alone: on a loaded machine the handshake
        // before it can take seconds.
        let cancelled = Date()
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.stderr.hasSuffix("Command cancelled."))
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2)
        await Self.assertProcessDisappears(-pids.group)
        await Self.assertProcessDisappears(pids.descendant)
    }

    func testCancellationBeforeRunDoesNotLaunchCommand() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-pre-run-\(UUID().uuidString)")
        let command = "/usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))"
        let task = Task {
            // Sleep until cancelled, so `run` always starts cancelled even if
            // this task runs first. A cancel racing the spawn is covered by
            // testCancellationRacingStartNeverLeavesTheChildRunningUnreported.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return await ShellCommandRunner.runShellScript(command, timeout: 10)
        }

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationDuringOutputPreservesCapturedStreams() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-output-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            await ShellCommandRunner.runShellScript(
                """
                /usr/bin/printf 'stdout-line\n'
                /usr/bin/printf 'stderr-line\n' >&2
                /usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))
                /bin/sleep 5
                """,
                timeout: 10
            )
        }
        let reachedHandshake = await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(reachedHandshake, "The controlled child never reached its cancellation handshake.")

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.stdout.contains("stdout-line"))
        XCTAssertTrue(result.stderr.contains("stderr-line"))
        XCTAssertTrue(result.stderr.hasSuffix("Command cancelled."))
    }

    func testCancellationNearChildExitCompletesExactlyOnce() async {
        for _ in 0..<40 {
            let task = Task {
                await ShellCommandRunner.runShellScript(
                    "/bin/sleep 0.01; /usr/bin/printf done",
                    timeout: 2
                )
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
            task.cancel()

            let result = await task.value
            XCTAssertTrue(
                result.exitCode == 0 || result.exitCode == -2,
                "Unexpected near-exit result: \(result)"
            )
        }
    }

    func testLargeStandardOutputAndErrorDoNotDeadlock() async {
        let byteCount = 1_048_576
        let result = await ShellCommandRunner.runShellScript(
            """
            /usr/bin/yes O | /usr/bin/head -c \(byteCount)
            /usr/bin/yes E | /usr/bin/head -c \(byteCount) >&2
            """,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, byteCount - 1)
        XCTAssertEqual(result.stderr.utf8.count, byteCount - 1)
    }

    func testTimedOutProcessIsTerminatedAndReapedBeforeReturn() async {
        let probe = RecordingChildWaitProbe()
        let result = await ShellCommandRunner.runShellScript(
            "/usr/bin/printf $$; exec /bin/sleep 5",
            timeout: 0.1,
            waitForChild: { probe.wait($0, $1, $2) }
        )

        XCTAssertEqual(result.exitCode, -3)
        // Take the PID from the waitpid seam: on a loaded machine the timeout
        // can kill the shell before `/usr/bin/printf` prints `$$`.
        guard let pid = probe.childPID, pid > 0 else {
            return XCTFail("The runner must probe exactly one child PID")
        }
        if !result.stdout.isEmpty {
            XCTAssertEqual(result.stdout, String(pid), "The probed PID must be the shell's own")
        }
        XCTAssertTrue(probe.didReap(pid), "The runner must reap its child through the seam")
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    /// The descendant ignores TERM, then writes `group:descendant` (its parent,
    /// the shell, leads the group). A SIGTERM before the trap would have killed
    /// it, so a report proves the stop met a TERM-ignoring descendant and its
    /// `sleep` child, both holding the command's pipes open. The sleep outlasts
    /// every poll, even on a loaded machine, so a missed SIGKILL always shows.
    private func descendantHoldingPipesCommand(marker: URL) -> String {
        let report = ShellCommandRunner.shellQuoted(marker.path)
        return """
        /bin/sh -c 'trap "" TERM; printf "%s:%s" "$PPID" "$$" > "$1"; /bin/sleep 30' sh \(report) &
        wait $!
        """
    }

    private func processIdentifiers(from marker: URL) throws -> (group: Int32, descendant: Int32) {
        try processIdentifiers(in: String(contentsOf: marker, encoding: .utf8))
    }

    private func processIdentifiers(in contents: String) throws -> (group: Int32, descendant: Int32) {
        let components = contents.split(separator: ":")
        guard components.count == 2,
              let group = Int32(components[0]),
              let descendant = Int32(components[1]) else {
            XCTFail("Invalid process-group handshake: \(contents)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return (group, descendant)
    }

    private func waitForProcessIdentifiers(
        from marker: URL
    ) async throws -> (group: Int32, descendant: Int32) {
        // printf writes the report in one call, so any content is all of it.
        _ = await waitUntil { !(FileManager.default.contents(atPath: marker.path)?.isEmpty ?? true) }
        return try processIdentifiers(from: marker)
    }

    /// Polls every 10 ms for up to five seconds. Only for handshakes that no
    /// short timer races: a loaded machine can take seconds to start a shell.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// A pipe stays readable forever once its writer closes, so a read source
    /// whose handler only returns at EOF is re-armed immediately and spins its
    /// I/O queue at 100% CPU. Any command that finishes writing before it exits
    /// -- here by closing its own descriptors -- burns a core for the whole of
    /// its remaining lifetime, and starves the exit source sharing that queue.
    func testCommandThatClosesOutputEarlyDoesNotSpinTheIOQueue() async {
        let before = Self.processCPUSeconds()

        let result = await ShellCommandRunner.runShellScript(
            "/usr/bin/printf 'done'; exec 1>&- 2>&-; /bin/sleep 1",
            timeout: 10
        )

        let consumed = Self.processCPUSeconds() - before
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done")
        XCTAssertLessThan(
            consumed,
            0.25,
            "one second of command burned \(consumed)s of CPU; the read sources are spinning on EOF."
        )
    }

    /// CPU consumed by this process only. The spin runs on TaskScope's own I/O
    /// queue, so a spawned child's time (`RUSAGE_CHILDREN`) would not show it.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    /// A negative `pid` names a process group, as it does for `kill`. Killed
    /// members stay visible until launchd reaps them, which a loaded machine
    /// can take seconds to do, so this polls for up to ten seconds; the
    /// descendants these tests start sleep for 30, so a real survivor still
    /// fails. The intermittent survivor once blamed on XCTest dropping off-main
    /// failures was the runner's own race: a fork escaping its single SIGKILL.
    @MainActor
    private static func assertProcessDisappears(
        _ pid: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
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
}

/// Models NOTE_EXIT arriving before waitpid can reap. Only the runner's own
/// spawned children reach the real waitpid; returning zero never reaps them.
private final class DeferredChildWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(deferredProbes: Int) { remaining = deferredProbes }

    func wait(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ options: Int32) -> pid_t {
        let deferProbe = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        return deferProbe ? 0 : Darwin.waitpid(pid, status, options)
    }
}

/// Records the PIDs the runner probes and the ones the real waitpid reaps, so
/// a test never depends on the child printing its PID before a timeout.
private final class RecordingChildWaitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var probedPIDs: Set<pid_t> = []
    private var reapedPIDs: Set<pid_t> = []

    func wait(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ options: Int32) -> pid_t {
        lock.withLock { _ = probedPIDs.insert(pid) }
        let waitedPID = Darwin.waitpid(pid, status, options)
        if waitedPID == pid { lock.withLock { _ = reapedPIDs.insert(pid) } }
        return waitedPID
    }

    /// The command's child, or nil unless exactly one PID was probed.
    var childPID: pid_t? { lock.withLock { probedPIDs.count == 1 ? probedPIDs.first : nil } }

    func didReap(_ pid: pid_t) -> Bool { lock.withLock { reapedPIDs.contains(pid) } }
}
