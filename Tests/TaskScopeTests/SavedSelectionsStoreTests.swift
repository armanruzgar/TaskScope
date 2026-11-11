import XCTest
@testable import TaskScope

@MainActor
final class SavedSelectionsStoreTests: XCTestCase {
    private let suiteName = "TaskScope.SavedSelectionsStoreTests.\(UUID().uuidString)"
    private let key = "saved-selections-tests"
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Legacy payloads predate executable-path capture. They keep their
    /// documented command fallback, and every such match is flagged.
    func testLegacyEntryRecallsByExactExecutableCommandAndIsMarkedAsANameMatch() throws {
        seedLegacySelection(
            name: "Example tools",
            entries: [(pid: 10, command: "/Applications/Example.app/Contents/MacOS/Example")]
        )
        let store = makeStore()
        let restarted = process(pid: 99, command: "/Applications/Example.app/Contents/MacOS/Example")

        let result = try store.resolve(XCTUnwrap(store.selections.first), in: [restarted])

        XCTAssertEqual(result.matched, [restarted])
        XCTAssertEqual(result.legacyNameMatches, [restarted.identity])
        XCTAssertTrue(result.unmatched.isEmpty)
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    /// A new entry without a kernel path would silently take the spoofable
    /// name-match branch on recall, so saving it is refused with a message that
    /// names the process.
    func testSaveRefusesAnEntryWithoutAKernelExecutablePath() throws {
        let store = makeStore()
        let bound = process(
            pid: 10,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let unbound = process(pid: 11, command: "/tmp/Mystery")

        XCTAssertFalse(store.save(name: "Mixed", processes: [bound, unbound]))
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertTrue(store.validationError?.contains("Mystery (PID 11)") == true, store.validationError ?? "")

        XCTAssertTrue(store.save(name: "Bound only", processes: [bound]))
        XCTAssertEqual(try XCTUnwrap(store.selections.first).processes.map(\.executablePath), [bound.executablePath])
    }

    func testTrustedExecutablePathWinsOverSpoofableCommand() throws {
        let store = makeStore()
        let original = process(
            pid: 10,
            command: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let unrelated = process(
            pid: 20,
            command: "Example",
            executablePath: "/tmp/Example"
        )
        let restarted = process(
            pid: 99,
            command: "Example",
            executablePath: original.executablePath
        )
        XCTAssertTrue(store.save(name: "Example", processes: [original]))

        let result = try store.resolve(XCTUnwrap(store.selections.first), in: [unrelated, restarted])

        XCTAssertEqual(result.matched, [restarted])
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    func testTrustedExecutablePathNeverFallsBackToSpoofableCommand() throws {
        let store = makeStore()
        let original = process(
            pid: 10,
            command: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example"
        )
        let unrelated = process(
            pid: 20,
            command: "Example",
            executablePath: "/tmp/Example"
        )
        XCTAssertTrue(store.save(name: "Example", processes: [original]))

        let result = try store.resolve(XCTUnwrap(store.selections.first), in: [unrelated])

        XCTAssertTrue(result.matched.isEmpty)
        XCTAssertEqual(result.unmatched.count, 1)
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    func testRecallGroupsCopiesByPathAndOnlyMarksExcessRunningCopiesAmbiguous() throws {
        let store = makeStore()
        let path = "/test/bin/node"
        let originals = [10, 11].map { process(pid: Int32($0), command: "node", executablePath: path) }
        XCTAssertTrue(store.save(name: "Workers", processes: originals))
        let running = [20, 21, 22].map { process(pid: Int32($0), command: "node", executablePath: path) }
        let impostor = process(pid: 30, command: "node", executablePath: "/other/bin/node")

        for count in 0...3 {
            let candidates = Array(running.prefix(count))
            let result = try store.resolve(XCTUnwrap(store.selections.first), in: candidates + [impostor])
            XCTAssertEqual(result.matched, count <= 2 ? candidates : [])
            XCTAssertEqual(result.unmatched.count, max(0, 2 - count))
            XCTAssertEqual(result.ambiguous.count, count > 2 ? 2 : 0)
            XCTAssertTrue(result.legacyNameMatches.isEmpty)
        }
    }

    func testNameFallbackOnlyMatchesWhenUnique() throws {
        seedLegacySelection(name: "Example", entries: [(pid: 10, command: "Example")])
        let store = makeStore()
        let first = process(pid: 20, command: "/one/Example")
        let second = process(pid: 21, command: "/two/Example")

        let ambiguous = try store.resolve(XCTUnwrap(store.selections.first), in: [first, second])
        let unique = try store.resolve(XCTUnwrap(store.selections.first), in: [first])

        XCTAssertTrue(ambiguous.matched.isEmpty)
        XCTAssertEqual(ambiguous.ambiguous.count, 1)
        XCTAssertEqual(unique.matched, [first])
    }

    func testLegacyEntryWhoseOnlyCandidateWasClaimedIsUnmatchedNotAmbiguous() throws {
        seedLegacySelection(name: "Workers", entries: [
            (pid: 10, command: "/usr/local/bin/worker"),
            (pid: 11, command: "/usr/local/bin/worker")
        ])
        let store = makeStore()
        let running = process(pid: 20, command: "/usr/local/bin/worker")

        let result = try store.resolve(XCTUnwrap(store.selections.first), in: [running])

        XCTAssertEqual(result.matched, [running])
        XCTAssertEqual(result.unmatched.count, 1)
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    func testRenamingADeletedSelectionReportsWhy() throws {
        let store = makeStore()
        store.save(name: "Editors", processes: [process(pid: 1, command: "/bin/Editor", executablePath: "/bin/Editor")])
        let selection = try XCTUnwrap(store.selections.first)
        XCTAssertTrue(store.remove(selection))

        XCTAssertFalse(store.rename(selection, to: "Development"))
        XCTAssertEqual(store.validationError, "This saved selection no longer exists.")
    }

    func testDuplicateNamesAreRejectedAndRenamePersists() throws {
        let store = makeStore()
        store.save(name: "Editors", processes: [process(pid: 1, command: "/bin/Editor", executablePath: "/bin/Editor")])
        XCTAssertFalse(store.save(name: " editors ", processes: [process(pid: 2, command: "/bin/Other", executablePath: "/bin/Other")]))
        XCTAssertTrue(try store.rename(XCTUnwrap(store.selections.first), to: "Development"))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.selections.map(\.name), ["Development"])
    }

    func testLegacyPIDOnlySelectionIsPreservedAndMarkedUnsupported() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","pids":[42]}]
        """
        defaults.set(try XCTUnwrap(legacy.data(using: .utf8)), forKey: key)

        let store = makeStore()
        let result = try store.resolve(XCTUnwrap(store.selections.first), in: [process(pid: 42, command: "Replacement")])

        XCTAssertTrue(try XCTUnwrap(store.selections.first).isLegacyUnsupported)
        XCTAssertTrue(result.legacyUnsupported)
        XCTAssertTrue(result.matched.isEmpty)
    }

    func testCorruptSelectionsAreBackedUp() {
        let corrupt = Data([0xFF, 0x01])
        defaults.set(corrupt, forKey: key)

        let store = makeStore()

        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertNotNil(store.recoveryMessage)
        XCTAssertEqual(defaults.data(forKey: "\(key).corruptBackup"), corrupt)
    }

    private func makeStore() -> SavedSelectionsStore {
        SavedSelectionsStore(userDefaults: defaults, key: key)
    }

    /// Writes a pre-path-capture payload exactly as an older build stored it.
    private func seedLegacySelection(name: String, entries: [(pid: Int32, command: String)]) {
        let processes = entries.map { entry in
            #"{"pid":\#(entry.pid),"command":"\#(entry.command)","executableName":"\#(URL(fileURLWithPath: entry.command).lastPathComponent)"}"#
        }.joined(separator: ",")
        let pids = entries.map { String($0.pid) }.joined(separator: ",")
        let json = #"[{"id":"00000000-0000-0000-0000-000000000002","name":"\#(name)","pids":[\#(pids)],"processes":[\#(processes)],"isLegacyUnsupported":false}]"#
        defaults.set(Data(json.utf8), forKey: key)
    }

    private func process(
        pid: Int32,
        command: String,
        executablePath: String? = nil
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: command,
            executablePath: executablePath,
            elapsedTime: "00:10",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}
