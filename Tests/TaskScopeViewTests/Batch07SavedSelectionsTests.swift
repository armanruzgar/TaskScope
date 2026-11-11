import Foundation
import ViewInspector
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

// MARK: - Saved selections

@MainActor
final class Batch07SavedSelectionsTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    private let key = "batch07-selections"
    private let nodePath = "/Batch07/bin/node"

    override func setUp() {
        super.setUp()
        suiteName = "TaskScope.Batch07SavedSelectionsTests.\(UUID().uuidString)"
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // L08-1: each saved and each running path is standardized once.
    func testRecallStandardizesEverySavedAndRunningPathOnlyOnce() {
        let paths = (0..<20).map { "/Batch07/bin/tool\($0)" }
        let saved = paths.enumerated().flatMap { index, path in
            [0, 1].map { copy in
                SavedSelectionsStore.SavedProcess(
                    pid: Int32(100 + index * 2 + copy), command: "tool", executableName: "tool",
                    executablePath: path, startTime: "saved"
                )
            }
        }
        let selection = SavedSelectionsStore.SavedSelection(name: "Many", pids: saved.map(\.pid), processes: saved)
        let running = (0..<100).map { index in
            batch07Process(pid: Int32(1_000 + index), command: "tool", executablePath: paths[index % 20], startTime: "r\(index)")
        }

        var standardizations = 0
        let result = SavedSelectionsStore.resolve(selection, in: running) { path in
            standardizations += 1
            return path
        }
        XCTAssertEqual(standardizations, saved.count + running.count)
        XCTAssertEqual(result.ambiguous.count, saved.count, "five copies run for every two saved ones")
        XCTAssertEqual(result, makeStore().resolve(selection, in: running))
    }

    // L08-1: a legacy entry that claims a process first still excludes it.
    func testALegacyEntryThatClaimsAProcessFirstStillExcludesItFromAPathGroup() {
        let legacy = SavedSelectionsStore.SavedProcess(pid: 1, command: "/Batch07/bin/tool --one", executableName: "tool")
        let pathEntry = SavedSelectionsStore.SavedProcess(
            pid: 2, command: "tool", executableName: "tool", executablePath: "/Batch07/bin/tool", startTime: "gone"
        )
        let selection = SavedSelectionsStore.SavedSelection(name: "Mixed", pids: [1, 2], processes: [legacy, pathEntry])
        let first = batch07Process(pid: 10, command: "/Batch07/bin/tool --one", executablePath: "/Batch07/bin/tool", startTime: "a")
        let second = batch07Process(pid: 11, command: "/Batch07/bin/tool --two", executablePath: "/Batch07/bin/tool", startTime: "b")

        let result = makeStore().resolve(selection, in: [first, second])
        XCTAssertEqual(result.matched.map(\.pid), [10, 11])
        XCTAssertEqual(result.legacyNameMatches, [first.identity])
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    // A11-4: the saved process itself is recognized among more copies.
    func testRecallSelectsTheSavedProcessWhenMoreCopiesOfItsExecutableRun() throws {
        let store = makeStore()
        let running = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        XCTAssertTrue(store.save(name: "One worker", processes: [running[1]]))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [[String: Any]])
        let storedProcesses = try XCTUnwrap(stored.first?["processes"] as? [[String: Any]])
        XCTAssertEqual(storedProcesses.first?["startTime"] as? String, "start-11")

        let selection = try XCTUnwrap(store.selections.first)
        let result = store.resolve(selection, in: running)
        XCTAssertEqual(result.matched.map(\.pid), [11])
        XCTAssertTrue(result.ambiguous.isEmpty)
        XCTAssertTrue(result.unmatched.isEmpty)

        // A process that reused the PID later is not taken for the saved one.
        let recycled = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "later-\($0)") }
        let recycledResult = store.resolve(selection, in: recycled)
        XCTAssertTrue(recycledResult.matched.isEmpty)
        XCTAssertEqual(recycledResult.ambiguous.count, 1)

        // With the original gone and two other copies running, nothing is chosen.
        let others = [20, 21].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        XCTAssertEqual(store.resolve(selection, in: others).ambiguous.count, 1)
    }

    // A11-4: entries saved before start times were kept fall back to the PID.
    func testEntriesSavedWithoutAStartTimeAreRecognizedByTheirPID() throws {
        let json = #"[{"id":"00000000-0000-0000-0000-00000000B007","name":"Legacy","pids":[11],"processes":[{"pid":11,"command":"node","executablePath":"/Batch07/bin/node","executableName":"node"}]}]"#
        defaults.set(Data(json.utf8), forKey: key)
        let store = makeStore()
        let selection = try XCTUnwrap(store.selections.first)
        let entry = try XCTUnwrap(selection.processes.first)
        XCTAssertNil(entry.startTime)
        XCTAssertEqual(entry.id, "/Batch07/bin/node|node|11")

        let running = [10, 11, 12].map { batch07Process(pid: Int32($0), command: "node", executablePath: nodePath, startTime: "start-\($0)") }
        let result = store.resolve(selection, in: running)
        XCTAssertEqual(result.matched.map(\.pid), [11])
        XCTAssertTrue(result.ambiguous.isEmpty)
    }

    // A11-5: repeated ids load once, read-only, with the payload backed up.
    func testRepeatedSelectionIDsLoadOnceAndReadOnly() throws {
        let id = UUID()
        let process = SavedSelectionsStore.SavedProcess(pid: 1, command: "node", executableName: "node", executablePath: nodePath)
        let payload = try JSONEncoder().encode([
            SavedSelectionsStore.SavedSelection(id: id, name: "First", pids: [1], processes: [process]),
            SavedSelectionsStore.SavedSelection(id: id, name: "Second", pids: [1], processes: [process])
        ])
        defaults.set(payload, forKey: key)

        let store = makeStore()
        XCTAssertEqual(store.selections.map(\.name), ["First"])
        XCTAssertTrue(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.recoveryMessage?.contains("duplicate") == true, store.recoveryMessage ?? "")
        XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), payload)
        let first = try XCTUnwrap(store.selections.first)
        XCTAssertFalse(store.rename(first, to: "Renamed"))
        XCTAssertFalse(store.remove(first))
        XCTAssertEqual(defaults.data(forKey: key), payload)

        store.resetAfterCorruption()
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.selections.map(\.name), ["First"])
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
    }

    // A11-7: names typed now are checked; stored names are left alone.
    func testSelectionNamesRefuseLineBreaksControlBidiCharactersAndLongText() throws {
        let store = makeStore()
        let process = batch07Process(pid: 42, command: "node", executablePath: nodePath)
        let refused = [
            "Line\nbreak", "Line\rbreak", "Line\u{2028}break", "Nul\u{0}name", "Tab\tname",
            "Delete\u{7F}name", "C1\u{85}name", "Override\u{202E}name", "Isolate\u{2066}name",
            String(repeating: "n", count: SavedSelectionsStore.maximumNameLength + 1)
        ]
        for name in refused {
            XCTAssertFalse(store.save(name: name, processes: [process]), name.debugDescription)
            XCTAssertNotNil(store.validationError)
        }
        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertTrue(store.save(name: String(repeating: "n", count: SavedSelectionsStore.maximumNameLength), processes: [process]))
        XCTAssertTrue(store.save(name: "Family 👨‍👩‍👧", processes: [process]), store.validationError ?? "")
        XCTAssertTrue(store.save(name: "  Trimmed\n", processes: [process]))
        XCTAssertEqual(store.selections.last?.name, "Trimmed")

        let selection = try XCTUnwrap(store.selections.first { $0.name.hasPrefix("Family") })
        XCTAssertFalse(store.rename(selection, to: "Re\nnamed"))
        XCTAssertFalse(store.rename(selection, to: "Re\u{202D}named"))
        XCTAssertTrue(store.rename(selection, to: "Renamed"))

        // A stored name is not revalidated at load; it stays usable and renameable.
        let stored = SavedSelectionsStore.SavedSelection(name: "Old\nname", pids: [42], processes: [.init(process: process)])
        defaults.set(try JSONEncoder().encode([stored]), forKey: key)
        let reloaded = makeStore()
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertEqual(reloaded.selections.map(\.name), ["Old\nname"])
        XCTAssertTrue(reloaded.rename(try XCTUnwrap(reloaded.selections.first), to: "New name"))
    }

    // A11-7: a long stored name cannot push the recall sheet's buttons away.
    func testRecallSheetTitleIsLimitedToTwoLines() throws {
        let name = String(repeating: "Long name ", count: 300)
        let sheet = SavedSelectionRecallSheet(
            selection: .init(name: name, pids: [], processes: []),
            result: .init(matched: [], unmatched: [], ambiguous: [], legacyUnsupported: false),
            onApply: {},
            onCancel: {}
        )
        XCTAssertEqual(try sheet.inspect().find(text: "Recall “\(name)”").lineLimit(), 2)
    }

    private func makeStore() -> SavedSelectionsStore {
        SavedSelectionsStore(userDefaults: defaults, key: key)
    }
}
