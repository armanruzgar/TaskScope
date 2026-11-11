import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The process list reader's composition, process records and details.
final class Batch05ReaderFixTests: XCTestCase {
    private let start = "Wed Oct 7 17:04:47 2026"
    private var list: String {
        "42 1 \(getuid()) 1 1024 \(start) 00:01 <defunct>\n43 1 0 2 2048 \(start) 00:02 Other"
    }
    /// The process table: `start` is 1_791_392_687 in UTC.
    private func table(live: [Int32], zombies: [Int32] = []) -> KernelProcessTable.TableRead {
        KernelProcessTable.table(
            from: live.map { KernelProcessEntry(pid: $0, parentPID: 1, uid: 0, startSeconds: 1_791_392_687) }
                + zombies.map { KernelProcessEntry(pid: $0, parentPID: 1, uid: 0, startSeconds: 1_791_392_687, isZombie: true) }
        )
    }

    private func read(
        _ results: [ShellCommandResult],
        table: KernelProcessTable.TableRead? = nil,
        extended: Bool = false,
        cancelDuringRowReads: Bool = false
    ) async -> Result<[AppProcess], ProcessInventoryError> {
        let processTable = table ?? self.table(live: [42, 43])
        // Each read runs in a task of its own, so a cancellation stays in it.
        // The class is named rather than `Self`: a dynamic `Self` captured by
        // the task is a pattern Xcode 26's region-based isolation checker
        // rejects as an error in the strict CI step.
        return await Task {
            await Batch05ReaderFixTests.read(results, processTable, extended, cancelDuringRowReads)
        }.value
    }

    private static func read(
        _ results: [ShellCommandResult],
        _ processTable: KernelProcessTable.TableRead,
        _ extended: Bool,
        _ cancelDuringRowReads: Bool
    ) async -> Result<[AppProcess], ProcessInventoryError> {
        let runner = Batch05ScriptedRunner(results)
        return await ProcessListReader.currentProcessList(
            fetchExtendedStats: extended,
            run: { await runner.run($0) },
            executablePath: { _ in nil },
            startUptime: { _ in
                if cancelDuringRowReads { withUnsafeCurrentTask { $0?.cancel() } }
                return 123
            },
            processTable: { processTable },
            ownerName: { $0 == 0 ? "root" : "alex" },
            diskIO: { $0 == 42 ? (4096, 8192) : nil },
            currentPID: 42
        )
    }

    func testInventoryFailuresAndCancellationAtBothSnapshots() async {
        let unreadable = "The process table could not be read (\(String(cString: strerror(EPERM))))."
        let inconsistent = "The process table could not be read (\(String(cString: strerror(EINVAL))))."
        let repeated = KernelProcessTable.table(from: [
            KernelProcessEntry(pid: 42, parentPID: 1, uid: 0, startSeconds: 1_791_392_687),
            KernelProcessEntry(pid: 42, parentPID: 1, uid: 0, startSeconds: 1_791_392_688)
        ])
        let cases: [([ShellCommandResult], KernelProcessTable.TableRead?, Bool, ProcessInventoryError)] = [
            ([shellResult("", code: 9, error: "denied")], nil, false, .commandFailed("denied")),
            ([shellResult("", code: 7)], nil, false, .commandFailed("ps exited with status 7.")),
            ([shellResult("", code: ShellCommandRunner.cancelledExitCode)], nil, false, .cancelled),
            ([shellResult(list)], .failed(errno: EPERM), false, .commandFailed(unreadable)),
            ([shellResult(list)], nil, true, .cancelled),
            // Well formed, but without TaskScope's own PID: never "nothing running".
            ([shellResult(list)], table(live: [43]), false, .parseFailed),
            // A PID listed twice is an inconsistent table.
            ([shellResult(list)], repeated, false, .commandFailed(inconsistent))
        ]
        for (results, table, cancel, expected) in cases {
            let result = await read(results, table: table, cancelDuringRowReads: cancel)
            XCTAssertEqual(result, .failure(expected))
        }
    }

    /// L07-14: a basic read runs `ps` once; the second `ps` is gone.
    func testABasicReadRunsOnePSAndNoOtherCommand() async throws {
        let runner = Batch05ScriptedRunner([shellResult(list)])
        let table = table(live: [42, 43])
        _ = try await ProcessListReader.currentProcessList(
            fetchExtendedStats: false,
            run: { await runner.run($0) },
            executablePath: { _ in nil },
            startUptime: { _ in nil },
            processTable: { table },
            diskIO: { _ in nil },
            currentPID: 42
        ).get()
        let commands = await runner.commands
        XCTAssertEqual(commands, [ProcessListReader.processListCommand])
    }

    func testChurnDropsOnlyTheMissingRowAndAttachesValidatedKernelState() async throws {
        let rows = try await read([shellResult(list)], table: table(live: [42])).get()

        XCTAssertEqual(rows.map(\.pid), [42])
        XCTAssertEqual(rows[0].ownerName, "alex", "the read names each row's owner")
        XCTAssertEqual(rows[0].monotonicStart, .uptimeNanoseconds(123))
        XCTAssertEqual(rows[0].isZombie, false)
        XCTAssertFalse(rows[0].hasExited, "A live process can call itself <defunct>; argv is not exit evidence")
    }

    func testExtendedMergePutsEachValueInItsFieldAndLeavesMissingOnesEmpty() async throws {
        let rows = try await read(
            [shellResult(list), shellResult(",bytes_in,bytes_out,\nname.42,2048,3072,")],
            extended: true
        ).get()

        XCTAssertEqual(rows.map(\.pid), [42, 43])
        XCTAssertEqual(rows[0].netInKB, 2)
        XCTAssertEqual(rows[0].netOutKB, 3)
        XCTAssertEqual(rows[0].diskReadBytes, 4096)
        XCTAssertEqual(rows[0].diskWriteBytes, 8192)
        XCTAssertNil(rows[1].netInKB)
        XCTAssertNil(rows[1].netOutKB)
        XCTAssertNil(rows[1].diskReadBytes)
        XCTAssertNil(rows[1].diskWriteBytes)
        XCTAssertEqual(rows[1].ownerName, "root")
        XCTAssertFalse(rows[1].hasExited)
        XCTAssertEqual(rows[1].monotonicStart, .notRead)

        // The kernel's process state decides, whatever the row is called: the
        // live row named <defunct> stays, and the exited one is not listed.
        let withZombie = try await read([shellResult(list)], table: table(live: [42], zombies: [43])).get()
        XCTAssertEqual(withZombie.map(\.pid), [42])
        XCTAssertFalse(withZombie[0].hasExited)
    }

    func testNetworkParserHandlesDottedAndCommaNamesAndMalformedRows() {
        let stats = ProcessListReader.parseNetworkStats("""
        ,bytes_in,bytes_out,
        com.apple.WebKit.Networking.42,1024,2048,
        a,name.43,3072,4096,
        missing.44,10,
        bad.45,no,20,
        badpid.x,1,2,
        """)

        XCTAssertEqual(stats?.count, 2)
        XCTAssertEqual(stats?[42]?.0, 1)
        XCTAssertEqual(stats?[42]?.1, 2)
        XCTAssertEqual(stats?[43]?.0, 3)
        XCTAssertEqual(stats?[43]?.1, 4)
        XCTAssertNil(ProcessListReader.parseNetworkStats(""))
        XCTAssertNil(ProcessListReader.parseNetworkStats("name.42,,20,"))
    }

    /// Without a recorded kernel state the old text rule still applies.
    func testRowsWithoutKernelStateKeepTheTextFallback() {
        var row = batch05Process(42)
        row.command = "<defunct>"
        XCTAssertTrue(row.hasExited)
        row.isZombie = false
        XCTAssertFalse(row.hasExited)
        row.command = "Example"
        row.isZombie = true
        XCTAssertTrue(row.hasExited)
    }

    /// Another user's process: the kernel refuses its arguments, so `ps`
    /// prints them, and its start time must still be the row's.
    func testDetailCommandLinePreservesSpacesAndRejectsAnotherProcess() async {
        let process = batch05Process(42)
        let arguments = "python  worker.py --name 'two words'"
        for (pid, stamp, expected) in [
            (42, start, CommandLineReadResult.loaded(arguments)),
            (42, "Wed Oct 7 17:04:48 2026", .identityChanged),
            (43, start, .unavailable("The command line could not be parsed."))
        ] {
            let runner = Batch05ScriptedRunner([
                shellResult("42 1 me \(start) /usr/bin/python"),
                shellResult("\(pid) \(stamp) \(arguments)")
            ])
            let commandLines = SystemProcessCommandLineReader(
                processEntry: { .found(KernelProcessEntry(pid: $0, parentPID: 1, uid: 0, startSeconds: 1_791_392_687)) },
                kernelArguments: { _ in .refused(errno: EINVAL) },
                executablePath: { _ in nil },
                run: { await runner.run($0) }
            )
            var kernel = ProcessDetailKernelReads()
            kernel.entry = { .found(KernelProcessEntry(pid: $0, parentPID: 1, uid: 0, startSeconds: 1_791_392_687)) }
            kernel.executablePath = { _ in nil }
            kernel.threadCount = { _ in .unavailable("not scripted") }
            kernel.openFiles = { _ in .unavailable("not scripted") }
            kernel.codeSignature = { _ in .unavailable("not scripted") }
            let reader = SystemProcessDetailReader(commandLineReader: commandLines, kernelReads: kernel)

            let detail = await reader.readDetail(for: process, run: { await runner.run($0) })

            XCTAssertEqual(detail?.command, "/usr/bin/python")
            XCTAssertEqual(detail?.commandLine, expected)
        }
    }

    @MainActor
    func testDetailSheetShowsTheCommandLineOrSaysWhyItIsUnavailable() throws {
        let process = batch05Process(42)
        var detail = ProcessDetail(pid: 42, parentPID: 1, user: "me", startTime: start, command: "/usr/bin/python")
        detail.commandLine = .loaded("python worker.py --port 8080")

        let shown = ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {})
        XCTAssertNoThrow(try shown.inspect().find(text: "Command Line"))
        XCTAssertNoThrow(try shown.inspect().find(text: "python worker.py --port 8080"))
        XCTAssertThrowsError(try shown.inspect().find(text: "Arguments"))

        detail.commandLine = .identityChanged
        let unavailable = ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {})
        XCTAssertNoThrow(try unavailable.inspect().find(text: "Unavailable"))
        XCTAssertNoThrow(try unavailable.inspect().find(text: "This PID now belongs to a different process."))
    }

    func testIdentityStandardizesThePathAndFollowsUpdatesWithoutChangingTheRawPath() {
        var process = batch05Process(42)
        process.executablePath = "/Applications/Example.app/../Example.app/Contents/MacOS/Example"

        XCTAssertEqual(process.identity.executablePath, "/Applications/Example.app/Contents/MacOS/Example")
        XCTAssertEqual(process.executablePath, "/Applications/Example.app/../Example.app/Contents/MacOS/Example")
        process.executablePath = "/usr/bin/other"
        XCTAssertEqual(process.identity.executablePath, "/usr/bin/other")
        process.executablePath = nil
        XCTAssertNil(process.identity.executablePath)
    }

    /// Identities are built for the whole inventory on the main actor at every
    /// list publish and engine tick, so reading one must not consult the file
    /// system. The path is standardized once, when it is set; standardizing
    /// drops a leading /private only while the shorter path exists.
    func testReadingAnIdentityDoesNotConsultTheFileSystem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let privatePath = "/private" + directory.appendingPathComponent("tool").path
        XCTAssertTrue(privatePath.hasPrefix("/private/var/"), privatePath)
        var process = batch05Process(42)
        process.executablePath = privatePath
        let identity = process.identity

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("tool").path, contents: Data()))
        XCTAssertNotEqual(
            URL(fileURLWithPath: privatePath).standardizedFileURL.path, privatePath,
            "Standardizing now gives another answer"
        )

        XCTAssertEqual(process.identity, identity)
    }

    /// With the comparison at `<`, every awake pass with an unchanged sleep
    /// total appended an observation, and the one that proved a sleep happened
    /// after an older process started was evicted.
    func testEqualSleepTotalsExtendTheObservationWithoutEvictingTheWake() throws {
        func ns(_ value: UInt64) -> UInt64 { value * 1_000_000_000 }
        var history = ProcessAgeHistory(limit: 2)
        history.record(UptimeSample(uptime: ns(100), asleep: 0))
        history.record(UptimeSample(uptime: ns(200), asleep: ns(3600)))
        for value in stride(from: UInt64(300), through: 1000, by: 100) {
            history.record(UptimeSample(uptime: ns(value), asleep: ns(3600)))
        }

        let age = try XCTUnwrap(history.minimumAge(sinceUptime: ns(50), at: UptimeSample(uptime: ns(1000), asleep: ns(3600))))

        XCTAssertEqual(age, 4550)
    }
}

private func shellResult(_ output: String, code: Int32 = 0, error: String = "") -> ShellCommandResult {
    ShellCommandResult(command: "fixture", stdout: output, stderr: error, exitCode: code)
}

/// Answers each command with the next scripted result.
private actor Batch05ScriptedRunner {
    private var results: [ShellCommandResult]
    private(set) var commands: [ExternalCommand] = []

    init(_ results: [ShellCommandResult]) {
        self.results = results
    }

    func run(_ command: ExternalCommand) -> ShellCommandResult {
        commands.append(command)
        guard !results.isEmpty else { return shellResult("", code: 99, error: "Unexpected command: \(command)") }
        return results.removeFirst()
    }
}
