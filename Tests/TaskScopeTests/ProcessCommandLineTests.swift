import AppKit
import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L09-4: the command line is read per PID, only while the PID still has the
/// row's identity, and is shown or copied only on request.
final class ProcessCommandLineTests: XCTestCase {
    /// `Wed Oct 7 17:04:47 2026` UTC.
    private let startSeconds = 1_791_392_687
    private let start = "Wed Oct 7 17:04:47 2026"
    private let path = "/usr/bin/python3"

    private func identity(pid: Int32 = 42, startTime: String? = nil, path: String? = "/usr/bin/python3") -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime ?? start, command: "python3", executablePath: path)
    }

    private func entry(pid: Int32 = 42, seconds: Int? = nil, zombie: Bool = false) -> KernelProcessTable.Lookup {
        .found(KernelProcessEntry(pid: pid, parentPID: 1, uid: getuid(), startSeconds: seconds ?? startSeconds, isZombie: zombie))
    }

    private func reader(
        _ kernel: ScriptedKernel,
        run: @escaping @Sendable (ExternalCommand) async -> ShellCommandResult = { _ in
            ShellCommandResult(command: "", stdout: "", stderr: "unexpected ps", exitCode: 99)
        }
    ) -> SystemProcessCommandLineReader {
        SystemProcessCommandLineReader(
            processEntry: { kernel.nextEntry(for: $0) },
            kernelArguments: { kernel.arguments(for: $0) },
            executablePath: { kernel.path(for: $0) },
            run: run
        )
    }

    // MARK: Start-time text

    /// The kernel start time must render exactly as the inventory's `ps lstart`
    /// text, which is DateFormatter's en_US_POSIX/UTC/"EEE MMM d HH:mm:ss yyyy".
    func testStartTimeTextMatchesThePOSIXDateFormatterEverywhere() {
        XCTAssertEqual(ProcessStartTime.psText(epochSeconds: startSeconds), start)
        XCTAssertEqual(ProcessStartTime.psText(epochSeconds: 1_793_523_903), "Sun Nov 1 09:05:03 2026", "an unpadded single-digit day")
        XCTAssertEqual(ProcessStartTime.psText(epochSeconds: 0), "Thu Jan 1 00:00:00 1970")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var seconds = 0
        var mismatches: [Int] = []
        // Every 20 days and 3,607 seconds across 1970-2100 hits every weekday,
        // month, day of month and clock position.
        while seconds < 4_102_444_800 {
            if ProcessStartTime.psText(epochSeconds: seconds)
                != formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) {
                mismatches.append(seconds)
            }
            seconds += 20 * 86_400 + 3_607
        }
        XCTAssertEqual(mismatches, [])
    }

    func testKernelEntryOfThisProcessCarriesItsIdentityEvidence() throws {
        guard case .found(let me) = KernelProcessTable.entry(for: getpid()) else {
            return XCTFail("the kernel must list the test process")
        }
        XCTAssertEqual(me.pid, getpid())
        XCTAssertEqual(me.parentPID, getppid())
        XCTAssertEqual(me.uid, geteuid())
        XCTAssertFalse(me.isZombie)
        XCTAssertGreaterThan(me.startSeconds, 0)
        XCTAssertEqual(KernelProcessTable.entry(for: 0), .notFound)
        XCTAssertEqual(KernelProcessTable.entry(for: -1), .notFound)
    }

    // MARK: Argument parsing

    private func procargs(argc: Int32, path: String, padding: Int, strings: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(path.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for string in strings { bytes += Array(string.utf8) + [0] }
        return bytes
    }

    func testArgumentsStopAtArgcAndNeverReadTheEnvironment() {
        let bytes = procargs(
            argc: 3, path: "/usr/bin/python3", padding: 5,
            strings: ["python3", "worker.py", "--name=two  words", "SECRET_TOKEN=abc", "HOME=/Users/me"]
        )
        XCTAssertEqual(KernelProcessArguments.parse(bytes), ["python3", "worker.py", "--name=two  words"])
    }

    func testArgumentsSurviveTruncationOddCountsAndInvalidText() {
        XCTAssertEqual(KernelProcessArguments.parse([]), [])
        XCTAssertEqual(KernelProcessArguments.parse([1, 0]), [], "shorter than argc itself")
        XCTAssertEqual(KernelProcessArguments.parse(procargs(argc: 0, path: "/bin/x", padding: 0, strings: ["x"])), [])
        XCTAssertEqual(KernelProcessArguments.parse(procargs(argc: -2, path: "/bin/x", padding: 0, strings: ["x"])), [])
        XCTAssertEqual(
            KernelProcessArguments.parse(procargs(argc: 9, path: "/bin/x", padding: 2, strings: ["x", "y"])),
            ["x", "y"], "a count larger than the strings present stops at the end of the data"
        )
        var truncated = procargs(argc: 2, path: "/bin/x", padding: 0, strings: ["x"])
        truncated += Array("unterminated".utf8)
        XCTAssertEqual(KernelProcessArguments.parse(truncated), ["x", "unterminated"])
        let invalid = procargs(argc: 1, path: "/bin/x", padding: 0, strings: []) + [0x61, 0xFF, 0x62, 0]
        XCTAssertEqual(KernelProcessArguments.parse(invalid), ["a\u{FFFD}b"])
    }

    // MARK: Identity checks around the read

    func testOwnProcessIsReadInProcessAndJoinedLikePS() async {
        let kernel = ScriptedKernel(entries: [entry()], arguments: .arguments(["python3", "worker.py", "", "--port", "8080"]), path: path)
        let result = await reader(kernel).commandLine(for: identity())
        XCTAssertEqual(result, .loaded("python3 worker.py  --port 8080"))
        XCTAssertEqual(result.commandLine, "python3 worker.py  --port 8080")
        XCTAssertNil(result.message)
        XCTAssertEqual(kernel.entryReads, 2, "the identity is checked before and after the read")
    }

    func testChangedIdentityIsRefusedBeforeAnyArgumentIsRead() async {
        let laterStart = ScriptedKernel(entries: [entry(seconds: startSeconds + 1)], arguments: .arguments(["other"]), path: path)
        let laterResult = await reader(laterStart).commandLine(for: identity())
        XCTAssertEqual(laterResult, .identityChanged)
        XCTAssertEqual(laterResult.message, "This PID now belongs to a different process.")
        XCTAssertEqual(laterStart.argumentReads, 0)

        let otherExecutable = ScriptedKernel(entries: [entry()], arguments: .arguments(["other"]), path: "/usr/bin/ruby")
        let otherResult = await reader(otherExecutable).commandLine(for: identity())
        XCTAssertEqual(otherResult, .identityChanged)
        XCTAssertEqual(otherExecutable.argumentReads, 0)

        let gone = ScriptedKernel(entries: [.notFound], arguments: .arguments(["other"]), path: nil)
        let goneResult = await reader(gone).commandLine(for: identity())
        XCTAssertEqual(goneResult, .gone)
        XCTAssertEqual(goneResult.message, "This process is no longer running.")
        let zombie = ScriptedKernel(entries: [entry(zombie: true)], arguments: .arguments(["other"]), path: nil)
        let zombieResult = await reader(zombie).commandLine(for: identity())
        XCTAssertEqual(zombieResult, .gone)
        XCTAssertEqual(gone.argumentReads + zombie.argumentReads, 0)
    }

    /// The process the arguments came from must still hold the PID after the
    /// read; otherwise they may belong to whatever took the PID over.
    func testArgumentsReadWhileThePIDChangedHandsAreDiscarded() async {
        let reused = ScriptedKernel(entries: [entry(), entry(seconds: startSeconds + 60)], arguments: .arguments(["new", "occupant"]), path: path)
        let reusedResult = await reader(reused).commandLine(for: identity())
        XCTAssertEqual(reusedResult, .identityChanged)
        XCTAssertNil(reusedResult.commandLine)

        let exited = ScriptedKernel(entries: [entry(), .notFound], arguments: .arguments(["python3"]), path: path)
        let exitedResult = await reader(exited).commandLine(for: identity())
        XCTAssertEqual(exitedResult, .gone)

        let execed = ScriptedKernel(entries: [entry()], arguments: .arguments(["ruby", "x.rb"]), paths: [path, "/usr/bin/ruby"])
        let execedResult = await reader(execed).commandLine(for: identity())
        XCTAssertEqual(execedResult, .identityChanged, "a program run in place keeps the PID and start time, not the path")
    }

    func testUnknownPathOrStartTimeAndUnreadableTablesAreHandled() async {
        let noPath = ScriptedKernel(entries: [entry()], arguments: .arguments(["python3"]), path: nil)
        let unreadablePath = await reader(noPath).commandLine(for: identity())
        XCTAssertEqual(unreadablePath, .loaded("python3"), "the start time alone still identifies the process")
        let identityWithoutPath = await reader(ScriptedKernel(entries: [entry()], arguments: .arguments(["python3"]), path: "/elsewhere"))
            .commandLine(for: identity(path: nil))
        XCTAssertEqual(identityWithoutPath, .loaded("python3"))

        let noStart = ScriptedKernel(entries: [entry()], arguments: .arguments(["python3"]), path: path)
        let noStartResult = await reader(noStart).commandLine(for: identity(startTime: ""))
        XCTAssertEqual(noStartResult.commandLine, nil)
        XCTAssertEqual(noStart.entryReads + noStart.argumentReads, 0, "nothing is read without an identity to check")
        XCTAssertEqual(
            noStartResult.message,
            "The process's start time is unknown, so TaskScope cannot check that the PID still belongs to it."
        )

        let failedTable = ScriptedKernel(entries: [.failed(errno: ENOMEM)], arguments: .arguments(["python3"]), path: path)
        let failedResult = await reader(failedTable).commandLine(for: identity())
        XCTAssertEqual(failedResult, .unavailable("The process table could not be read (\(String(cString: strerror(ENOMEM))))."))

        let empty = ScriptedKernel(entries: [entry()], arguments: .arguments([]), path: path)
        let emptyResult = await reader(empty).commandLine(for: identity())
        XCTAssertEqual(emptyResult, .unavailable("macOS reported no arguments for this process."))
    }

    // MARK: Other users' processes

    func testRefusedProcessesFallBackToPSWithItsStartTimeChecked() async {
        let recorder = CommandRecorder()
        let printed = "42 \(start) /usr/sbin/daemon  --flag   value"
        let kernel = ScriptedKernel(entries: [entry()], arguments: .refused(errno: EINVAL), path: path)
        let result = await reader(kernel, run: { await recorder.answer($0, stdout: printed) }).commandLine(for: identity())
        XCTAssertEqual(result, .loaded("/usr/sbin/daemon  --flag   value"))
        let commands = await recorder.commands
        XCTAssertEqual(commands, [ExternalCommand("/bin/ps", ["-ww", "-o", "pid=,lstart=,args=", "-p", "42"])])
        XCTAssertEqual(kernel.entryReads, 2)

        // ps pads a single-digit day; the comparison collapses it like the inventory.
        let padded = "42 Sun Nov  1 09:05:03 2026 /usr/sbin/daemon"
        let paddedKernel = ScriptedKernel(entries: [entry(seconds: 1_793_523_903)], arguments: .refused(errno: EINVAL), path: path)
        let paddedResult = await reader(paddedKernel, run: { await recorder.answer($0, stdout: padded) })
            .commandLine(for: identity(startTime: "Sun Nov 1 09:05:03 2026"))
        XCTAssertEqual(paddedResult, .loaded("/usr/sbin/daemon"))
    }

    func testPSFallbackFailuresAreReportedNotGuessed() async {
        func read(_ result: ShellCommandResult, entries: [KernelProcessTable.Lookup]? = nil) async -> CommandLineReadResult {
            let kernel = ScriptedKernel(entries: entries ?? [entry()], arguments: .refused(errno: EINVAL), path: path)
            return await reader(kernel, run: { _ in result }).commandLine(for: identity())
        }
        let otherStart = await read(ShellCommandResult(command: "", stdout: "42 Wed Oct 7 17:04:48 2026 /usr/sbin/daemon", stderr: "", exitCode: 0))
        XCTAssertEqual(otherStart, .identityChanged)
        let otherPID = await read(ShellCommandResult(command: "", stdout: "43 \(start) /usr/sbin/daemon", stderr: "", exitCode: 0))
        XCTAssertEqual(otherPID, .unavailable("The command line could not be parsed."))
        let missing = await read(ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 1))
        XCTAssertEqual(missing, .gone)
        let failed = await read(ShellCommandResult(command: "", stdout: "", stderr: "ps: broken\n", exitCode: 2))
        XCTAssertEqual(failed, .unavailable("ps: broken\n"))
        XCTAssertEqual(failed.message, "ps: broken.")
        let killed = await read(ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: 9, terminatedBySignal: SIGKILL))
        XCTAssertEqual(killed, .unavailable("ps terminated by SIGKILL."))
        let cancelled = await read(ShellCommandResult(command: "", stdout: "", stderr: "", exitCode: ShellCommandRunner.cancelledExitCode))
        XCTAssertEqual(cancelled, .unavailable("The read was cancelled."))
        let blank = await read(ShellCommandResult(command: "", stdout: "42 \(start)", stderr: "", exitCode: 0))
        XCTAssertEqual(blank, .unavailable("ps printed no command line for this process."))
        let reusedDuringPS = await read(
            ShellCommandResult(command: "", stdout: "42 \(start) /usr/sbin/daemon", stderr: "", exitCode: 0),
            entries: [entry(), entry(seconds: startSeconds + 5)]
        )
        XCTAssertEqual(reusedDuringPS, .identityChanged)
    }

    // MARK: Real processes

    /// A child this test starts, with an argv[0] holding runs of spaces: the
    /// real in-process read returns its exact arguments, and refuses a wrong
    /// start time and the PID once the child is gone. The only signal goes to
    /// that child.
    func testRealReadOfAChildThisTestStarted() async throws {
        let child = try SpawnedChild(arguments: ["taskscope-cmdline-probe  two  spaces", "30"])
        defer { child.stop() }
        guard case .found(let kernelEntry) = KernelProcessTable.entry(for: child.pid) else {
            return XCTFail("the child must be in the process table")
        }
        let live = ProcessIdentity(
            pid: child.pid, startTime: kernelEntry.startTimeText, command: "sleep",
            executablePath: ProcessListReader.executablePath(for: child.pid)
        )
        XCTAssertEqual(live.executablePath, "/bin/sleep")
        let reader = SystemProcessCommandLineReader()

        let result = await reader.commandLine(for: live)
        XCTAssertEqual(result, .loaded("taskscope-cmdline-probe  two  spaces 30"))

        var stale = live
        stale.startTime = ProcessStartTime.psText(epochSeconds: kernelEntry.startSeconds - 3_600)
        let staleResult = await reader.commandLine(for: stale)
        XCTAssertEqual(staleResult, .identityChanged)

        child.stop()
        let goneResult = await reader.commandLine(for: live)
        XCTAssertEqual(goneResult, .gone)
    }

    /// launchd belongs to root, so the kernel refuses this user its arguments
    /// and the setuid `ps` supplies them. Reading them changes nothing.
    func testRealReadOfAnotherUsersProcessUsesPS() async throws {
        guard case .found(let launchd) = KernelProcessTable.entry(for: 1), launchd.uid != geteuid() else {
            throw XCTSkip("launchd is not another user's process here")
        }
        XCTAssertEqual(KernelProcessArguments.read(pid: 1), .refused(errno: EINVAL))
        let identity = ProcessIdentity(
            pid: 1, startTime: launchd.startTimeText, command: "launchd",
            executablePath: ProcessListReader.executablePath(for: 1)
        )
        let result = await SystemProcessCommandLineReader().commandLine(for: identity)
        XCTAssertTrue(result.commandLine?.hasSuffix("launchd") == true, "\(result)")
    }
}

/// Scripted kernel answers: entries are returned in order and the last one
/// repeats; paths likewise.
private final class ScriptedKernel: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [KernelProcessTable.Lookup]
    private var paths: [String?]
    private let argumentsResult: KernelProcessArguments.Read
    private var entryCount = 0
    private var argumentCount = 0

    init(entries: [KernelProcessTable.Lookup], arguments: KernelProcessArguments.Read, path: String?) {
        self.entries = entries
        self.paths = [path]
        self.argumentsResult = arguments
    }

    init(entries: [KernelProcessTable.Lookup], arguments: KernelProcessArguments.Read, paths: [String?]) {
        self.entries = entries
        self.paths = paths
        self.argumentsResult = arguments
    }

    var entryReads: Int { lock.withLock { entryCount } }
    var argumentReads: Int { lock.withLock { argumentCount } }

    func nextEntry(for pid: Int32) -> KernelProcessTable.Lookup {
        lock.withLock {
            entryCount += 1
            return entries.count > 1 ? entries.removeFirst() : entries[0]
        }
    }

    func arguments(for pid: Int32) -> KernelProcessArguments.Read {
        lock.withLock {
            argumentCount += 1
            return argumentsResult
        }
    }

    func path(for pid: Int32) -> String? {
        lock.withLock { paths.count > 1 ? paths.removeFirst() : paths[0] }
    }
}

private actor CommandRecorder {
    private(set) var commands: [ExternalCommand] = []

    func answer(_ command: ExternalCommand, stdout: String) -> ShellCommandResult {
        commands.append(command)
        return ShellCommandResult(command: command, stdout: stdout, stderr: "", exitCode: 0)
    }
}

/// A `/bin/sleep` child with a chosen argv, started and reaped by the test.
private final class SpawnedChild {
    let pid: pid_t
    private var reaped = false

    init(arguments: [String]) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/sleep", nil, nil, &argv, nil)
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        pid = spawned
    }

    func stop() {
        guard !reaped else { return }
        reaped = true
        _ = Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    }

    deinit { stop() }
}
