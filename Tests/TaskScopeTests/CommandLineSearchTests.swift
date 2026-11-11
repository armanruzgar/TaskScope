import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L09-4: search also matches the current user's command lines, read in
/// process, only for a search, once per inventory, never for other users.
final class CommandLineSearchTests: XCTestCase {
    private let start = "Wed Oct 7 17:04:47 2026"
    private let startSeconds = 1_791_392_687

    private func row(_ pid: Int32, name: String, uid: uid_t = getuid(), cpu: Double = 0) -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 1, uid: uid, cpu: cpu, memoryMB: 1,
            command: "/usr/bin/\(name)", executablePath: "/usr/bin/\(name)", elapsedTime: "00:01", startTime: start,
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    private func query(_ search: String, filter: ProcessFilterMode = .all) -> ProcessListQuery {
        ProcessListQuery(searchText: search, filterMode: filter, watchedScopes: [],
                         cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1_024)
    }

    private func index(_ lines: [Int32: String]) -> CommandLineSearchIndex {
        CommandLineSearchIndex(folded: lines.mapValues { CommandLineSearchIndex.fold(Array($0.utf8)) })
    }

    func testMatchingIgnoresCaseSpansArgumentsAndNeedsText() {
        let lines = index([42: "/usr/bin/tail -f /var/log/A.log", 43: "python3 manage.py runserver 8080"])
        XCTAssertTrue(lines.contains(.init("a.LOG"), in: 42))
        XCTAssertTrue(lines.contains(.init("tail -F"), in: 42), "a search can span arguments")
        XCTAssertFalse(lines.contains(.init("a.log"), in: 43))
        XCTAssertTrue(lines.contains(.init("8080"), in: 43))
        XCTAssertFalse(lines.contains(.init(""), in: 43))
        XCTAssertFalse(lines.contains(.init("8080"), in: 44), "a PID without a command line never matches")
        XCTAssertFalse(lines.contains(.init("runserver 8080 and more"), in: 43))
        XCTAssertEqual(CommandLineSearchIndex.fold(Array("ÀBc-Z".utf8)), Array("Àbc-z".utf8), "only A-Z is folded")
    }

    /// Only the current user's rows are read, and only those still running
    /// with the row's start time after the read are kept.
    func testIndexReadsOnlyOwnRowsAndKeepsOnlyUnchangedIdentities() {
        let rows = [
            row(40, name: "tail"), row(41, name: "launchd", uid: 0), row(42, name: "python3"),
            row(43, name: "node"), row(44, name: "zombie"), row(45, name: "gone")
        ]
        let reads = PIDRecorder()
        let built = CommandLineSearchIndex.read(
            for: rows,
            currentUID: getuid(),
            arguments: { pid, _ in reads.record(pid); return CommandLineSearchIndex.fold(Array("Command \(pid)".utf8)) },
            table: {
                .entries([
                    40: KernelProcessEntry(pid: 40, parentPID: 1, uid: getuid(), startSeconds: self.startSeconds),
                    42: KernelProcessEntry(pid: 42, parentPID: 1, uid: getuid(), startSeconds: self.startSeconds),
                    43: KernelProcessEntry(pid: 43, parentPID: 1, uid: getuid(), startSeconds: self.startSeconds + 9),
                    44: KernelProcessEntry(pid: 44, parentPID: 1, uid: getuid(), startSeconds: self.startSeconds, isZombie: true)
                ])
            }
        )
        XCTAssertEqual(reads.pids, [40, 42, 43, 44, 45], "never another user's process")
        XCTAssertEqual(built.count, 2)
        XCTAssertTrue(built.contains(.init("command 40"), in: 40))
        XCTAssertTrue(built.contains(.init("command 42"), in: 42))
        XCTAssertFalse(built.contains(.init("command 43"), in: 43), "the PID changed hands after the read")
        XCTAssertFalse(built.contains(.init("command 44"), in: 44), "an exited process")
        XCTAssertFalse(built.contains(.init("command 45"), in: 45), "no longer running")

        let failedTable = CommandLineSearchIndex.read(
            for: rows, currentUID: getuid(), arguments: { _, _ in Array("x".utf8) }, table: { .failed(errno: ENOMEM) }
        )
        XCTAssertEqual(failedTable.count, 0, "nothing is trusted without the check after the read")
    }

    func testListAddsCommandLineMatchesOnlyForASearchAndReadsOncePerInventory() {
        let tailA = row(50, name: "tail", cpu: 2)
        let tailB = row(51, name: "tail", cpu: 1)
        let other = row(52, name: "python3", cpu: 3)
        let reads = PIDRecorder()
        var projection = ProcessListProjection(inventory: [tailA, tailB, other]) { inventory in
            reads.record(Int32(inventory.count))
            return self.index([50: "tail -f alpha.log", 51: "tail -f beta.log", 52: "python3 serve.py --log alpha.log"])
        }
        XCTAssertEqual(projection.displayList(for: query(""), order: ProcessSortOrder(key: .cpu), limit: 10).processes.count, 3)
        XCTAssertEqual(reads.pids, [], "no search, no read")

        let alpha = projection.displayList(for: query("ALPHA.log"), order: ProcessSortOrder(key: .cpu), limit: 10)
        XCTAssertEqual(alpha.processes.map(\.pid), [52, 50])
        XCTAssertEqual(alpha.commandLineMatches, [52, 50])
        XCTAssertEqual(alpha.matchCount, 2)

        let byName = projection.displayList(for: query("tail"), order: ProcessSortOrder(key: .cpu), limit: 10)
        XCTAssertEqual(byName.processes.map(\.pid), [50, 51])
        XCTAssertEqual(byName.commandLineMatches, [], "a name match is not a command-line match")

        let limited = projection.displayList(for: query("alpha"), order: ProcessSortOrder(key: .cpu), limit: 1)
        XCTAssertEqual(limited.processes.map(\.pid), [52])
        XCTAssertEqual(limited.commandLineMatches, [52], "only displayed rows are reported")
        XCTAssertEqual(limited.matchCount, 2)

        let hot = projection.displayList(for: query("alpha", filter: .highlighted), order: ProcessSortOrder(key: .cpu), limit: 10)
        XCTAssertEqual(hot.processes, [], "the filter still applies to command-line matches")
        XCTAssertEqual(reads.pids, [3], "one read for the whole inventory")
        XCTAssertEqual(projection.treeRoots(for: query("beta"), order: ProcessSortOrder(key: .cpu), limit: 10).map(\.id), [51])
    }

    func testWholeTableReadListsThisProcessAndRefusesARepeatedPID() throws {
        guard case .entries(let table) = KernelProcessTable.allEntries() else {
            return XCTFail("the process table must be readable")
        }
        XCTAssertEqual(table[getpid()]?.parentPID, getppid())
        XCTAssertNotNil(table[1], "other users' processes are listed too")
        XCTAssertNil(table[0], "the kernel task is not a process the list can show")
        guard case .found(let single) = KernelProcessTable.entry(for: getpid()) else { return XCTFail("no entry") }
        XCTAssertEqual(table[getpid()]?.startTimeText, single.startTimeText)

        let entry = KernelProcessEntry(pid: 42, parentPID: 1, uid: 0, startSeconds: startSeconds)
        XCTAssertEqual(KernelProcessTable.table(from: [entry, entry]), .failed(errno: EINVAL))
        XCTAssertEqual(KernelProcessTable.table(from: [entry]), .entries([42: entry]))
    }

    /// Two children with distinct arguments: a real inventory and the real
    /// index tell them apart. The only signals go to those children.
    func testRealSearchFindsAChildByItsArguments() async throws {
        let alpha = try SearchChild(marker: "taskscope-alpha-marker")
        let beta = try SearchChild(marker: "taskscope-beta-marker")
        defer { alpha.stop(); beta.stop() }
        guard case .success(let inventory) = await ProcessListReader.currentProcessList(fetchExtendedStats: false) else {
            return XCTFail("the inventory must load")
        }
        var projection = ProcessListProjection(inventory: inventory)
        let found = projection.displayList(for: query("ALPHA-MARKER"), order: ProcessSortOrder(key: .pid), limit: SettingsStore.allProcessesLimit)
        XCTAssertTrue(found.processes.contains { $0.pid == alpha.pid })
        XCTAssertFalse(found.processes.contains { $0.pid == beta.pid })
        XCTAssertTrue(found.commandLineMatches.contains(alpha.pid))
    }
}

/// The row shows and announces a command-line match without showing the
/// command line.
@MainActor
final class CommandLineSearchRowTests: XCTestCase {
    func testRowMarksACommandLineMatch() throws {
        let process = Batch10.process(60, name: "Worker")
        func row(_ matched: Bool) -> ProcessRow {
            ProcessRow(process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
                       isHighlightedCPU: false, isHighlightedMEM: false, matchedByCommandLine: matched,
                       stopAction: {}, toggleSelection: {})
        }
        let marked = try row(true).inspect()
        XCTAssertNoThrow(try marked.find(ViewType.Image.self) { try $0.actualImage().name() == "text.magnifyingglass" })
        XCTAssertTrue(try marked.find(ViewType.VStack.self).accessibilityValue().string()
            .contains("matches the search in its command line"))
        let plain = try row(false).inspect()
        XCTAssertThrowsError(try plain.find(ViewType.Image.self) { try $0.actualImage().name() == "text.magnifyingglass" })
        XCTAssertFalse(try plain.find(ViewType.VStack.self).accessibilityValue().string().contains("command line"))
    }
}

private final class PIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    var pids: [Int32] { lock.withLock { recorded } }
    func record(_ pid: Int32) { lock.withLock { recorded.append(pid) } }
}

/// A `cat` child that waits on a pipe this test holds open, with a marker in
/// a later argument (not argv[0], which `ps comm` shows), started and reaped by
/// the test.
private final class SearchChild {
    let pid: pid_t
    private let writeEnd: Int32
    private var reaped = false

    init(marker: String) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], 0)
        posix_spawn_file_actions_addclose(&actions, fds[1])
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("cat"), strdup("-"), strdup(marker), nil]
        defer { argv.forEach { free($0) } }
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/cat", &actions, nil, &argv, nil)
        close(fds[0])
        guard status == 0 else {
            close(fds[1])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
        pid = spawned
        writeEnd = fds[1]
    }

    func stop() {
        guard !reaped else { return }
        reaped = true
        _ = Darwin.kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        close(writeEnd)
    }

    deinit { stop() }
}
