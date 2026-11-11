import Darwin
import XCTest
@testable import TaskScope

/// `ShellCommandRunner.run(executable:arguments:)` runs a program without a
/// shell. The tests that matter most run the same program both ways, directly
/// and through `/bin/zsh -f -c` as every command used to run, and pin that
/// timeouts, process-group containment and the scrubbed environment are
/// unchanged. Every child is one the test starts itself, and every signal goes
/// to a process group such a child leads.
final class ShellCommandRunnerArgvTests: XCTestCase {
    private typealias Support = Batch05ShellCommandRunnerTests

    /// The ways a program can be run: directly, or as one command string
    /// through `/bin/zsh -f -c`, the way every command ran before. The string
    /// quotes every word, so both forms ask for the same argument vector.
    private enum Form: CaseIterable, CustomStringConvertible {
        case argumentVector, shellString

        var description: String { self == .argumentVector ? "argument vector" : "shell string" }

        func run(
            _ executable: String,
            _ arguments: [String],
            timeout: TimeInterval = 15,
            waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
                Darwin.waitpid($0, $1, $2)
            },
            hooks: ShellCommandRunner.Hooks = ShellCommandRunner.Hooks()
        ) async -> ShellCommandResult {
            switch self {
            case .argumentVector:
                return await ShellCommandRunner.run(
                    executable: executable, arguments: arguments,
                    timeout: timeout, waitForChild: waitForChild, hooks: hooks
                )
            case .shellString:
                let commandLine = ([executable] + arguments).map(ShellCommandRunner.shellQuoted).joined(separator: " ")
                return await ShellCommandRunner.run(
                    executable: "/bin/zsh", arguments: ["-f", "-c", commandLine],
                    timeout: timeout, waitForChild: waitForChild, hooks: hooks
                )
            }
        }
    }

    // MARK: - Arguments

    /// Nothing between TaskScope and the program reads the arguments: quotes,
    /// `$`, globs, command separators and line breaks arrive unchanged.
    func testArgumentsReachTheProgramUnchanged() async {
        let arguments = [
            "two words", "'single'", "\"double\"", "$HOME", "$(/usr/bin/id)", "`/usr/bin/id`", "*",
            "a;b", "a|b", "a&b", "a>b", "line one\nline two", "back\\slash", "", "-n", "=cmd", "~", "é",
        ]

        let result = await ShellCommandRunner.run(
            executable: "/usr/bin/printf", arguments: ["[%s]"] + arguments, timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0, "\(result)")
        XCTAssertEqual(result.stdout, arguments.map { "[\($0)]" }.joined())
        XCTAssertEqual(result.stderr, "")
    }

    func testExitStatusAndSignalsAreReported() async {
        let failed = await ShellCommandRunner.run(executable: "/usr/bin/false")
        let exited = await ShellCommandRunner.run(executable: "/bin/sh", arguments: ["-c", "exit 7"])
        let signalled = await ShellCommandRunner.run(executable: "/bin/sh", arguments: ["-c", "kill -TERM $$"])
        let output = await ShellCommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 3"]
        )

        XCTAssertEqual(failed.exitCode, 1, "\(failed)")
        XCTAssertNil(failed.terminatedBySignal)
        XCTAssertEqual(exited.exitCode, 7, "\(exited)")
        XCTAssertEqual(exited.failureDescription, "exited with status 7")
        XCTAssertEqual(signalled.terminatedBySignal, SIGTERM, "\(signalled)")
        XCTAssertEqual(signalled.failureDescription, "terminated by SIGTERM")
        XCTAssertEqual(output.stdout, "out")
        XCTAssertEqual(output.stderr, "err")
        XCTAssertEqual(output.exitCode, 3)
    }

    /// The result names the command so that pasting it into a shell would run
    /// the same argument vector; it is never run itself.
    func testResultNamesTheCommandItRan() async {
        let result = await ShellCommandRunner.run(
            executable: "/usr/bin/printf", arguments: ["%s", "it's here", "plain-word"]
        )

        XCTAssertEqual(result.command, #"/usr/bin/printf %s 'it'\''s here' plain-word"#)
        XCTAssertEqual(ExternalCommand("/bin/launchctl", ["print", "gui/501/com.example.agent"]).description,
                       "/bin/launchctl print gui/501/com.example.agent")
        XCTAssertEqual(ExternalCommand("/bin/echo", ["", "=x", "a b", "$x", "é"]).description,
                       #"/bin/echo '' '=x' 'a b' '$x' 'é'"#)
        XCTAssertEqual(ExternalCommand.launchctl("print-disabled", "system"),
                       ExternalCommand("/bin/launchctl", ["print-disabled", "system"]))
        XCTAssertEqual(ExternalCommand("/bin/ps", ["-p", "1"]).argumentVector, ["/bin/ps", "-p", "1"])
    }

    // MARK: - Refusals

    /// A program path is never looked up: a relative one would run whatever
    /// the current directory holds under that name.
    func testRelativeProgramPathIsRefusedWithoutStarting() async {
        for executable in ["printf", "./printf", "usr/bin/printf", ""] {
            let probe = Batch05ChildProbe()
            let result = await ShellCommandRunner.run(
                executable: executable, arguments: ["started"],
                waitForChild: { probe.wait($0, $1, $2) }
            )

            XCTAssertEqual(result.exitCode, -1, "\(executable): \(result)")
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "Could not start the command: its program path is not absolute.")
            XCTAssertNil(probe.childPID, "\(executable): nothing may be spawned")
        }
    }

    /// A NUL would cut its argument short: the program would act on a
    /// different value than the one the caller built.
    func testArgumentWithANulCharacterIsRefusedWithoutStarting() async {
        let marker = Support.temporaryFile("argv-nul")
        defer { try? FileManager.default.removeItem(at: marker) }

        let truncatedArgument = await ShellCommandRunner.run(
            executable: "/usr/bin/touch", arguments: [marker.path + "\u{0}.ignored"]
        )
        let truncatedProgram = await ShellCommandRunner.run(
            executable: "/usr/bin/touch\u{0}/ignored", arguments: [marker.path]
        )
        let truncatedShellString = await ShellCommandRunner.run(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "/usr/bin/touch \(ShellCommandRunner.shellQuoted(marker.path))\u{0}; /usr/bin/false"]
        )

        for result in [truncatedArgument, truncatedProgram, truncatedShellString] {
            XCTAssertEqual(result.exitCode, -1, "\(result)")
            XCTAssertEqual(result.stderr, "Could not start the command: an argument contains a NUL character.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "No command may run")
    }

    func testMissingProgramFailsToStart() async {
        let result = await ShellCommandRunner.run(
            executable: "/usr/bin/taskscope-no-such-program-\(UUID().uuidString)"
        )

        XCTAssertEqual(result.exitCode, -1, "\(result)")
        XCTAssertNil(result.terminatedBySignal)
        XCTAssertEqual(result.stderr, "Could not start the command: No such file or directory.")
    }

    /// Once quitting has stopped the commands in flight, a command given as an
    /// argument vector is refused like any other.
    func testShutDownRefusesArgumentVectorCommands() async {
        let registry = ShellCommandRunner.ExecutionRegistry()
        let hooks = batch05Hooks { $0.registry = registry }
        let marker = Support.temporaryFile("argv-after-shutdown")
        defer { try? FileManager.default.removeItem(at: marker) }
        XCTAssertTrue(registry.shutDown(waitingAtMost: 1))

        let refused = await ShellCommandRunner.run(
            executable: "/usr/bin/touch", arguments: [marker.path], hooks: hooks
        )

        XCTAssertEqual(refused.exitCode, ShellCommandRunner.cancelledExitCode, "\(refused)")
        XCTAssertEqual(refused.stderr, "Command cancelled.")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "No command may run after shutdown")
    }

    // MARK: - Unchanged behavior, pinned for both forms

    /// Without a shell, the spawned process is the program itself.
    func testArgumentVectorSpawnsTheProgramItself() async {
        let probe = Batch05ChildProbe()
        let task = Task {
            await ShellCommandRunner.run(
                executable: "/bin/sleep", arguments: ["30"], timeout: 60,
                waitForChild: { probe.wait($0, $1, $2) }
            )
        }
        let spawned = await Support.eventually { probe.childPID != nil }
        XCTAssertTrue(spawned, "The program never started")
        guard let pid = probe.childPID else { task.cancel(); return }

        XCTAssertEqual(ProcessListReader.executablePath(for: pid), "/bin/sleep")

        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode, "\(result)")
        await Support.assertDisappears(-pid)
    }

    func testBothFormsStartTheCommandAsLeaderOfANewProcessGroup() async {
        for form in Form.allCases {
            let probe = Batch05ChildProbe()
            let task = Task {
                await form.run("/bin/sleep", ["30"], timeout: 60, waitForChild: { probe.wait($0, $1, $2) })
            }
            let spawned = await Support.eventually { probe.childPID != nil }
            XCTAssertTrue(spawned, "\(form): the command never started")
            guard let pid = probe.childPID else { task.cancel(); continue }

            XCTAssertEqual(getpgid(pid), pid, "\(form): the child must lead its own process group")
            XCTAssertNotEqual(getpgid(pid), getpgrp(), "\(form): the child must leave the test's process group")

            task.cancel()
            let result = await task.value
            XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode, "\(form): \(result)")
            XCTAssertEqual(result.stderr, "Command cancelled.", "\(form)")
            await Support.assertDisappears(-pid)
        }
    }

    func testBothFormsTimeOutAlike() async {
        for form in Form.allCases {
            let probe = Batch05ChildProbe()
            let started = ContinuousClock.now

            let result = await form.run(
                "/bin/sleep", ["30"], timeout: 0.2, waitForChild: { probe.wait($0, $1, $2) }
            )

            XCTAssertEqual(result.exitCode, ShellCommandRunner.timedOutExitCode, "\(form): \(result)")
            XCTAssertEqual(result.stderr, "Command timed out after 0.2 seconds.", "\(form)")
            XCTAssertNil(result.terminatedBySignal, "\(form): TaskScope's own stop is not the child's story")
            XCTAssertLessThan(started.duration(to: .now), .seconds(10), "\(form)")
            guard let pid = probe.childPID else {
                XCTFail("\(form): the runner must probe exactly one child PID")
                continue
            }
            await Support.assertDisappears(-pid)
        }
    }

    /// A descendant that ignores TERM and holds the command's pipes open is
    /// killed with the rest of the group, in both forms. On a loaded machine
    /// the timeout can arrive before the descendant reported, which proves
    /// nothing about it, so such an attempt is repeated.
    func testBothFormsKillTheWholeGroupOnTimeout() async throws {
        for form in Form.allCases {
            var proven = false
            for _ in 0..<5 where !proven {
                let marker = Support.temporaryFile("argv-timeout-group")
                defer { try? FileManager.default.removeItem(at: marker) }
                let probe = Batch05ChildProbe()

                let result = await Self.runDescendantHoldingPipes(
                    form, marker: marker, timeout: 1, waitForChild: { probe.wait($0, $1, $2) }
                )

                XCTAssertEqual(result.exitCode, ShellCommandRunner.timedOutExitCode, "\(form): \(result)")
                guard let leader = probe.childPID else {
                    XCTFail("\(form): the runner must probe exactly one child PID")
                    break
                }
                await Support.assertDisappears(-leader)
                guard let report = try? String(contentsOf: marker, encoding: .utf8), !report.isEmpty else {
                    continue
                }
                let pids = try Self.processIdentifiers(in: report)
                XCTAssertEqual(pids.group, leader, "\(form): the descendant's parent must lead the group")
                await Support.assertDisappears(pids.descendant)
                proven = true
            }
            XCTAssertTrue(proven, "\(form): no attempt reported a descendant before the timeout")
        }
    }

    func testBothFormsKillTheWholeGroupOnCancellation() async throws {
        for form in Form.allCases {
            let marker = Support.temporaryFile("argv-cancel-group")
            defer { try? FileManager.default.removeItem(at: marker) }
            let task = Task {
                await ShellCommandRunnerArgvTests.runDescendantHoldingPipes(form, marker: marker, timeout: 60)
            }

            let pids = try await Support.reportedProcessIdentifiers(at: marker)
            task.cancel()
            let result = await task.value

            XCTAssertEqual(result.exitCode, ShellCommandRunner.cancelledExitCode, "\(form): \(result)")
            XCTAssertTrue(result.stderr.hasSuffix("Command cancelled."), "\(form): \(result.stderr)")
            await Support.assertDisappears(-pids.group)
            await Support.assertDisappears(pids.descendant)
        }
    }

    /// Both forms give the program the same scrubbed environment; the string
    /// form's shell only adds the few variables zsh exports itself.
    func testBothFormsScrubTheEnvironmentAlike() async {
        let inherited = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "LOGNAME": "taskscope-test",
            "TASKSCOPE_KEPT": "kept value with spaces",
            "LANG": "de_DE.UTF-8",
            "LC_ALL": "de_DE.UTF-8",
            "LC_TIME": "de_DE.UTF-8",
            "LC_NUMERIC": "de_DE.UTF-8",
            "LC_CTYPE": "C",
            "TZ": "Europe/Berlin",
            "BASH_ENV": "/var/empty/bash_env",
            "ENV": "/var/empty/env",
            "SHELLOPTS": "xtrace",
            "BASHOPTS": "extglob",
            "PS4": "$(/usr/bin/id)",
            "CDPATH": "/var/empty",
            "GLOBIGNORE": "*",
            "IFS": "x",
            "BASH_FUNC_printf%%": "() { echo hijacked; }",
            "DYLD_PRINT_LIBRARIES": "1",
        ]
        let hooks = batch05Hooks { $0.inheritedEnvironment = { inherited } }
        let expected = ShellCommandRunner.childEnvironment(from: inherited)
        XCTAssertEqual(expected, [
            "PATH": "/usr/bin:/bin", "HOME": "/var/empty", "LOGNAME": "taskscope-test",
            "TASKSCOPE_KEPT": "kept value with spaces",
            "LC_CTYPE": "UTF-8", "LC_TIME": "C", "LC_NUMERIC": "C", "TZ": "UTC0",
        ])

        let direct = await Form.argumentVector.run("/usr/bin/env", [], hooks: hooks)
        let shell = await Form.shellString.run("/usr/bin/env", [], hooks: hooks)

        XCTAssertEqual(direct.exitCode, 0, "\(direct)")
        XCTAssertEqual(shell.exitCode, 0, "\(shell)")
        XCTAssertEqual(Self.environment(in: direct.stdout), expected, "Nothing may add to the scrubbed environment")
        let shellExports: Set<String> = ["SHLVL", "PWD", "OLDPWD", "_"]
        XCTAssertEqual(
            Self.environment(in: shell.stdout).filter { !shellExports.contains($0.key) }, expected,
            "Both forms must scrub the environment alike"
        )
    }

    /// The program inherits only its standard streams, and its standard input
    /// is an empty /dev/null, as in the string form.
    func testArgumentVectorCommandsInheritOnlyTheirStandardStreams() async {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.pipe(&descriptors), 0)
        let inheritable = fcntl(descriptors[1], F_DUPFD, 200)
        defer { [descriptors[0], descriptors[1], inheritable].forEach { _ = close($0) } }
        XCTAssertGreaterThanOrEqual(inheritable, 200)
        XCTAssertEqual(fcntl(inheritable, F_GETFD) & FD_CLOEXEC, 0)

        let listing = await ShellCommandRunner.run(executable: "/bin/ls", arguments: ["/dev/fd"])
        let open = Set(listing.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        let input = await ShellCommandRunner.run(executable: "/bin/cat", timeout: 5)

        XCTAssertEqual(listing.exitCode, 0, "\(listing)")
        XCTAssertTrue(open.isSuperset(of: [0, 1, 2]), listing.stdout)
        XCTAssertFalse(open.contains(inheritable), "The child inherited descriptor \(inheritable): \(listing.stdout)")
        XCTAssertEqual(input.exitCode, 0, "\(input)")
        XCTAssertEqual(input.stdout, "", "Standard input must be empty")
    }

    /// The app ignores SIGTERM process-wide; a program spawned without a shell
    /// must still start with the default disposition, or a stop's SIGTERM
    /// would be ignored.
    func testArgumentVectorCommandsStartWithDefaultSignalDispositions() async {
        let previous = signal(SIGTERM, SIG_IGN)
        let result = await ShellCommandRunner.run(
            executable: "/bin/sh", arguments: ["-c", "kill -TERM $$; echo survived"]
        )
        signal(SIGTERM, previous)

        XCTAssertEqual(result.terminatedBySignal, SIGTERM, "\(result)")
        XCTAssertFalse(result.stdout.contains("survived"), "\(result)")
    }

    // MARK: - Administrator requests

    /// The AppleScript is osascript's one `-e` argument, with the root script
    /// and the prompt each in one AppleScript string literal: quotes and
    /// backslashes escaped, line breaks written as `\n`.
    func testAdministratorRequestIsOsascriptWithTheAppleScriptAsOneArgument() {
        let command = ExternalCommand.administratorScript(
            "/bin/launchctl enable 'system/com.example' || exit $?\nif true; then\n  echo \"done\"\nfi",
            prompt: #"TaskScope needs "approval" (C:\Temp)."#
        )

        XCTAssertEqual(command.executable, "/usr/bin/osascript")
        XCTAssertEqual(command.arguments, [
            "-e",
            #"do shell script "/bin/launchctl enable 'system/com.example' || exit $?\nif true; then\n  echo \"done\"\nfi""#
                + #" with administrator privileges with prompt "TaskScope needs \"approval\" (C:\\Temp).""#,
        ])
    }

    /// Removing the shell changes nothing osascript receives: for the real
    /// root scripts, the old shell-quoted command line and the new argument
    /// vector deliver the same bytes. A harmless stand-in prints what it was
    /// given; osascript itself never runs.
    func testAdministratorRequestDeliversTheSameAppleScriptAsTheShellQuotedForm() async {
        let job = WatchedAppPreset.globalProtectSystemDaemon
        let scripts = [
            ProcessLifecycleController.adminBootstrapScript(for: job),
            ProcessLifecycleController.adminDisableScript(for: job),
            ProcessLifecycleController.adminDisableScript(for: job, preservingLoadedDaemon: true),
            "/bin/launchctl enable \(ShellCommandRunner.shellQuoted("system/\(job.label)"))",
        ]
        for script in scripts {
            let request = ExternalCommand.administratorScript(
                script, prompt: "TaskScope needs administrator approval (\(job.label))."
            )
            let appleScript = request.arguments[1]
            let oldCommandLine = "/usr/bin/printf '[%s]' -e \(ShellCommandRunner.shellQuoted(appleScript))"

            let throughShell = await ShellCommandRunner.run(
                executable: "/bin/zsh", arguments: ["-f", "-c", oldCommandLine], timeout: 10
            )
            let direct = await ShellCommandRunner.run(
                executable: "/usr/bin/printf", arguments: ["[%s]"] + request.arguments, timeout: 10
            )

            XCTAssertEqual(throughShell.exitCode, 0, "\(throughShell)")
            XCTAssertEqual(direct.exitCode, 0, "\(direct)")
            XCTAssertEqual(direct.stdout, "[-e][\(appleScript)]")
            XCTAssertEqual(direct.stdout, throughShell.stdout, "The shell form and the argument vector must agree")
        }
    }

    // MARK: - Helpers

    /// The group leader starts a descendant that ignores TERM, writes
    /// `leader:descendant` to `marker`, and sleeps for 30 seconds holding the
    /// command's pipes open. The marker path reaches the descendant as an
    /// argument, never as shell source.
    private static func runDescendantHoldingPipes(
        _ form: Form,
        marker: URL,
        timeout: TimeInterval,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        }
    ) async -> ShellCommandResult {
        let descendant = #"trap "" TERM; printf "%s:%s" "$PPID" "$$" > "$1"; /bin/sleep 30"#
        let leader = "/bin/sh -c \(ShellCommandRunner.shellQuoted(descendant)) sh \"$1\" &\nwait $!"
        return await form.run(
            "/bin/sh", ["-c", leader, "sh", marker.path], timeout: timeout, waitForChild: waitForChild
        )
    }

    private static func processIdentifiers(in contents: String) throws -> (group: Int32, descendant: Int32) {
        let components = contents.split(separator: ":")
        guard components.count == 2, let group = Int32(components[0]), let descendant = Int32(components[1]) else {
            XCTFail("Invalid process-group handshake: \(contents)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return (group, descendant)
    }

    private static func environment(in output: String) -> [String: String] {
        var variables: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            variables[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return variables
    }
}
