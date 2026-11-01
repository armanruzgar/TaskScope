import XCTest
@testable import TaskScope

final class ProcessListReaderTests: XCTestCase {
    private let liveRow = "42 1 501 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /Applications/Example.app/Contents/MacOS/Example"

    func testProductionSchemaKeepsDisplayCommandSeparateFromTrustedExecutablePath() throws {
        XCTAssertEqual(
            ProcessListReader.processListCommand,
            "/bin/ps -awwwxo pid=,ppid=,uid=,pcpu=,rss=,lstart=,etime=,comm="
        )
        XCTAssertFalse(ProcessListReader.processListCommand.contains(" -ac"))

        var processes = [try XCTUnwrap(ProcessListReader.parseProcessLine(liveRow[...]))]

        XCTAssertEqual(processes[0].command, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(processes[0].uid, 501)
        XCTAssertNil(processes[0].executablePath)

        ProcessListReader.attachExecutablePaths(
            to: &processes,
            resolvedPaths: [42: "/Applications/Example.app/Contents/MacOS/Example"],
            validatedStartTimes: [42: "Sat Jul 26 11:20:17 2026"]
        )

        XCTAssertEqual(processes[0].command, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(
            processes[0].executablePath,
            "/Applications/Example.app/Contents/MacOS/Example"
        )
        XCTAssertEqual(processes[0].displayCommand, "/Applications/Example.app/Contents/MacOS/Example")
    }

    func testExecutablePathEnrichmentFailsClosedWhenPIDStartTimeChanges() throws {
        let line = "42 1 501 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 Example"[...]
        var processes = [try XCTUnwrap(ProcessListReader.parseProcessLine(line))]

        ProcessListReader.attachExecutablePaths(
            to: &processes,
            resolvedPaths: [42: "/Applications/Example.app/Contents/MacOS/Example"],
            validatedStartTimes: [42: "Sat Jul 26 11:20:18 2026"]
        )

        XCTAssertNil(processes[0].executablePath)
    }

    func testParseProcessLineHandlesCommandsWithSpaces() {
        let process = ProcessListReader.parseProcessLine(
            "123 1 501 12.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /Applications/Example App.app/Contents/MacOS/Example App"[...]
        )

        XCTAssertEqual(process?.pid, 123)
        XCTAssertEqual(process?.parentPID, 1)
        XCTAssertEqual(process?.uid, 501)
        XCTAssertEqual(process?.cpu, 12.5)
        XCTAssertEqual(process?.memoryMB, 2.0)
        XCTAssertEqual(process?.startTime, "Sat Jul 26 11:20:17 2026")
        XCTAssertEqual(process?.elapsedTime, "01:02:03")
        XCTAssertEqual(process?.command, "/Applications/Example App.app/Contents/MacOS/Example App")
        XCTAssertEqual(process?.name, "Example App")
        XCTAssertNil(process?.netInKB)
        XCTAssertNil(process?.diskReadBytes)
    }

    func testParseProcessLinePreservesNonASCIIName() throws {
        let process = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "123 1 501 12.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 /tmp/Café Größe"[...]
        ))

        XCTAssertEqual(process.command, "/tmp/Café Größe")
        XCTAssertEqual(process.name, "Café Größe")
        XCTAssertEqual(process.cpu, 12.5)
        XCTAssertEqual(process.startTime, "Sat Jul 26 11:20:17 2026")
    }

    /// Exactly eleven tokens is a row whose `comm` is empty (or whitespace, which
    /// `ps` prints as nothing); it is kept with an empty command.
    func testElevenTokenRowIsAnEmptyCommandName() throws {
        let process = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "77 1 501 0.0 100 Sat Jul 26 11:20:17 2026 00:01   "[...]
        ))

        XCTAssertEqual(process.pid, 77)
        XCTAssertEqual(process.elapsedTime, "00:01")
        XCTAssertEqual(process.command, "")
        XCTAssertEqual(process.name, "")
    }

    /// The legacy six-token schema and any other token count are no longer
    /// parsed; such a row is dropped by the caller, never guessed at.
    func testRowsThatDoNotFitTheSchemaAreRejected() {
        XCTAssertNil(ProcessListReader.parseProcessLine("not enough columns"[...]))
        XCTAssertNil(ProcessListReader.parseProcessLine("abc 1 501 0.0 10 Sat Jul 26 11:20:17 2026 00:01 command"[...]))
        XCTAssertNil(
            ProcessListReader.parseProcessLine("123 1 12.5 2048 01:02:03 /Applications/Example"[...]),
            "the legacy six-token layout must not be accepted"
        )
        XCTAssertNil(
            ProcessListReader.parseProcessLine("42 1 7.5 2048 Sat Jul 26 11:20:17 2026 01:02:03 Example"[...]),
            "an eleven-token row without uid is the old schema, not an empty command"
        )
        XCTAssertNil(
            ProcessListReader.parseProcessLine("42 1 501 7.5 2048 Sat Jul 26 11:20:17 00:01"[...]),
            "ten tokens is a truncated row"
        )
    }

    /// `ps` prints `0,5` under de_DE. The command runs with LC_NUMERIC=C, but the
    /// parser accepts a comma decimal rather than dropping the row.
    func testCommaDecimalParses() throws {
        let process = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "42 1 501 0,5 2048 Sat Jul 26 11:20:17 2026 01:02:03 Example"[...]
        ))

        XCTAssertEqual(process.cpu, 0.5)
    }

    /// A localized five-token start time keeps the row shape and parses; the
    /// identity comparison later uses the same string on both sides.
    func testLocalizedFiveTokenStartTimeStillFitsTheSchema() throws {
        let process = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "42 1 501 0.4 16352 So. 30 Aug. 13:23:26 2026 02-08:18:04 /sbin/example"[...]
        ))

        XCTAssertEqual(process.startTime, "So. 30 Aug. 13:23:26 2026")
        XCTAssertEqual(process.elapsedTime, "02-08:18:04")
        XCTAssertEqual(process.name, "example")
    }

    func testProcessListOutputDropsMalformedRowsAndKeepsValidOnes() throws {
        let output = "\(liveRow)\nmalformed partial row"

        let processes = try ProcessListReader.parseProcessListOutput(output).get()
        XCTAssertEqual(processes.map(\.pid), [42])
    }

    /// launchd (pid 1) and the kernel task (pid 0) must never become signal
    /// targets, so the parser drops those rows while keeping the inventory.
    func testParserDropsPIDsThatMustNeverBeSignalled() throws {
        let output = """
        0 0 0 0.0 100 Sat Jul 26 11:20:17 2026 01:02:03 kernel_task
        1 0 0 0.0 100 Sat Jul 26 11:20:17 2026 01:02:03 /sbin/launchd
        \(liveRow)
        """

        XCTAssertNil(ProcessListReader.parseProcessLine(
            "1 0 0 0.0 100 Sat Jul 26 11:20:17 2026 01:02:03 /sbin/launchd"[...]
        ))
        let processes = try ProcessListReader.parseProcessListOutput(output).get()
        XCTAssertEqual(processes.map(\.pid), [42])
    }

    /// TaskScope itself is always running, so output with no usable rows is a
    /// broken read rather than an empty machine.
    func testEmptyOutputIsAParseFailureNotAnEmptyInventory() {
        XCTAssertEqual(ProcessListReader.parseProcessListOutput(""), .failure(.parseFailed))
        XCTAssertEqual(ProcessListReader.parseProcessListOutput("\n\n"), .failure(.parseFailed))
        XCTAssertEqual(
            ProcessListReader.parseProcessListOutput("malformed\nrows only"),
            .failure(.parseFailed)
        )
    }

    /// A repeated pid means the snapshot is inconsistent; it is refused rather
    /// than letting one row silently overwrite the other.
    func testDuplicatePIDRowsFailTheWholeRead() {
        let output = "\(liveRow)\n\(liveRow)"

        XCTAssertEqual(ProcessListReader.parseProcessListOutput(output), .failure(.parseFailed))
        XCTAssertEqual(
            ProcessListReader.parseStartTimes("42 Sat Jul 26 11:20:17 2026\n42 Sat Jul 26 11:20:18 2026"),
            .failure(.parseFailed)
        )
    }

    func testCancelledCommandIsReportedAsCancellationNotAsAnInventoryFault() {
        let cancelled = ShellCommandResult(
            command: ProcessListReader.processListCommand,
            stdout: "",
            stderr: "Command cancelled.",
            exitCode: ShellCommandRunner.cancelledExitCode
        )
        let failed = ShellCommandResult(
            command: ProcessListReader.processListCommand,
            stdout: "",
            stderr: "ps denied",
            exitCode: 1
        )

        XCTAssertEqual(ProcessListReader.cancellation(of: cancelled), .cancelled)
        XCTAssertNil(ProcessListReader.cancellation(of: failed))
    }

    func testStartTimeValidationRejectsPartialMalformedOutput() {
        let output = """
        42 Sat Jul 26 11:20:17 2026
        43 Sat Jul 26
        """

        XCTAssertEqual(
            ProcessListReader.parseStartTimes(output),
            .failure(.parseFailed)
        )
    }

    func testPaddedPSStartTimesRetainEveryMatchingProcessIdentity() throws {
        let first = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "42 1 501 0.0 100 Mon Sep 28 12:00:01 2026 00:10 GlobalProtect"[...]
        ))
        let second = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "43 1 0 0.0 100 Mon Sep 28 12:00:02 2026 00:10 PanGPS"[...]
        ))
        let times = try ProcessListReader.parseStartTimes(
            "   42 Mon Sep 28 12:00:01 2026    \n\t43 Mon Sep 28 12:00:02 2026\t  \n"
        ).get()
        XCTAssertEqual(times[42], first.startTime)
        XCTAssertEqual(times[43], second.startTime)
        XCTAssertEqual(ProcessListReader.validatedProcesses([first, second], using: times), [first, second])
    }

    func testLiveProcessInventoryIncludesItsOwnStableProcess() async throws {
        let inventory = try await ProcessListReader.currentProcessList(fetchExtendedStats: false).get()
        XCTAssertTrue(inventory.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }

    func testFailedIdentityValidationCommandIsInventoryFailure() {
        let result = ShellCommandResult(
            command: ProcessListReader.identityValidationCommand,
            stdout: "",
            stderr: "ps denied",
            exitCode: 1
        )

        XCTAssertEqual(
            ProcessListReader.validatedStartTimes(from: result),
            .failure(.commandFailed("ps denied"))
        )
    }

    func testIdentityValidationOmitsProcessThatExitedBetweenSnapshots() throws {
        let result = ShellCommandResult(
            command: ProcessListReader.identityValidationCommand,
            stdout: "42 Sat Jul 26 11:20:17 2026",
            stderr: "",
            exitCode: 0
        )

        let startTimes = try ProcessListReader.validatedStartTimes(from: result).get()
        let first = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "42 1 501 0 100 Sat Jul 26 11:20:17 2026 00:01 First"[...]
        ))
        let exited = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "43 1 501 0 100 Sat Jul 26 11:20:18 2026 00:01 Exited"[...]
        ))

        XCTAssertEqual(
            ProcessListReader.validatedProcesses([first, exited], using: startTimes),
            [first]
        )
    }

    func testDiskIOIsReadFromTheKernelForTheCurrentProcess() throws {
        let usage = try XCTUnwrap(ProcessListReader.diskIOBytes(for: ProcessInfo.processInfo.processIdentifier))

        XCTAssertGreaterThanOrEqual(usage.read, 0)
        XCTAssertGreaterThanOrEqual(usage.written, 0)
        XCTAssertNil(ProcessListReader.diskIOBytes(for: 1), "root-owned launchd must report unavailable, not zero")
    }

    // MARK: - AppProcess derived fields

    func testNameIsPrecomputedAndFollowsCommandEdits() {
        var process = AppProcess(
            pid: 1_000,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            elapsedTime: "00:01",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
        XCTAssertEqual(process.name, "Example")

        process.command = "/Applications/Ex"
        XCTAssertEqual(process.name, "Ex")

        process.command = "   "
        XCTAssertEqual(process.name, "")
    }

    /// A process that writes a title over argv[0] can put a '/' in free
    /// text. Only an absolute path is split on '/'; anything else is named by
    /// its leading token, so the row is not named after a fragment of the title.
    func testRewrittenArgvTitleIsNamedByItsLeadingTokenNotAPathFragment() throws {
        XCTAssertEqual(AppProcess.name(from: "sshd-session: user@ttys001/x"), "sshd-session")
        XCTAssertEqual(AppProcess.name(from: "sshd-session: me@ttys001"), "sshd-session: me@ttys001")
        XCTAssertEqual(
            AppProcess.name(from: "ssh: /Users/example/.ssh/cm-root@192.0.2.1:22 [mux]"),
            "ssh"
        )
        // Without a '/', the title cannot be misread as a path and keeps its
        // previous name, so existing rules on it still match.
        XCTAssertEqual(AppProcess.name(from: "postgres: walwriter   "), "postgres: walwriter")
        XCTAssertEqual(AppProcess.name(from: "celery worker"), "celery worker")

        // Absolute paths and bare names keep their previous names, so rule and
        // preset matching on those is unchanged.
        XCTAssertEqual(AppProcess.name(from: "/Applications/Example App.app/Contents/MacOS/Example App"), "Example App")
        XCTAssertEqual(AppProcess.name(from: "  /usr/sbin/example  "), "example")
        XCTAssertEqual(AppProcess.name(from: "Example"), "Example")
        XCTAssertEqual(AppProcess.name(from: "<defunct>"), "<defunct>")
        XCTAssertEqual(AppProcess.name(from: "/"), "/")
        XCTAssertEqual(AppProcess.name(from: "./build/tool"), "tool")
        XCTAssertEqual(AppProcess.name(from: ": title"), ": title")

        let row = try XCTUnwrap(ProcessListReader.parseProcessLine(
            "321 1 501 0.0 1024 Sat Jul 26 11:20:17 2026 00:05 sshd-session: user@ttys001/x"[...]
        ))
        XCTAssertEqual(row.command, "sshd-session: user@ttys001/x")
        XCTAssertEqual(row.name, "sshd-session")
    }

    func testDisplayCommandOnlyAbbreviatesTheHomeDirectoryItself() {
        let home = NSHomeDirectory()
        func process(path: String) -> AppProcess {
            AppProcess(
                pid: 1_000,
                parentPID: 1,
                cpu: 0,
                memoryMB: 0,
                command: path,
                executablePath: path,
                elapsedTime: "00:01",
                netInKB: nil,
                netOutKB: nil,
                diskReadBytes: nil,
                diskWriteBytes: nil
            )
        }

        XCTAssertEqual(process(path: home).displayCommand, "~")
        XCTAssertEqual(process(path: home + "/bin/tool").displayCommand, "~/bin/tool")
        XCTAssertEqual(process(path: home + "data/tool").displayCommand, home + "data/tool")
        XCTAssertEqual(process(path: "/tmp" + home).displayCommand, "/tmp" + home)
    }
}
