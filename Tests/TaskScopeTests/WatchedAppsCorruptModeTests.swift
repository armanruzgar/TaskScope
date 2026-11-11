import XCTest
@testable import TaskScope

/// P10 — in corrupt mode `WatchedAppsStore` sets `allowsPersistence = false` but every
/// mutating API still succeeds and still mutates `@Published presets`. Callers
/// (`SettingsView.savePresetEditor()`, `SettingsView.importPresets(from:)`) only inspect the
/// return value, so recovery work is accepted, reported as saved, and silently dropped.
@MainActor
final class P10CorruptModeSilentDiscardTests: XCTestCase {
    private let suiteName = "TaskScope.P10CorruptModeSilentDiscardTests.\(UUID().uuidString)"
    private let key = "watched-presets-p10-tests"
    private let corruptBytes = Data([0xFE, 0xED])
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

    /// SettingsView.savePresetEditor() does `let saved = watchedApps.add(preset)` and, on
    /// `true`, clears the validation error and dismisses the sheet. In corrupt mode the write
    /// cannot happen, so `add` must not claim success.
    func testAddInCorruptModeReportsFailureToItsCaller() {
        let store = makeCorruptStore()

        let saved = store.add(validPreset(name: "Example"))

        XCTAssertFalse(
            saved,
            """
            add(_:) returned true while allowsPersistence == false, so \
            SettingsView.savePresetEditor() clears presetValidationError and dismisses the editor \
            for a preset that was never written to \(key).
            """
        )
    }

    /// The durability half of the same defect: a mutation must never be accepted
    /// into memory only to vanish at quit. Corrupt mode now refuses the write, so
    /// nothing is silently lost and the unreadable payload is left intact.
    func testCorruptModeRefusesTheMutationRatherThanLosingItAtQuit() {
        let store = makeCorruptStore()

        XCTAssertFalse(store.add(validPreset(name: "Example")))
        XCTAssertTrue(store.presets.isEmpty, "a refused add must not enter the in-memory list")
        XCTAssertNotNil(store.validationError, "the refusal must be visible to the caller")

        let relaunched = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertTrue(relaunched.isReadOnlyAfterCorruption)
        XCTAssertEqual(
            defaults.data(forKey: key),
            corruptBytes,
            "the unreadable payload must still be at its primary key after a refused mutation"
        )
    }

    /// SettingsView.importPresets(from:) shows an error only when rejectedCount > 0.
    func testImportInCorruptModeReportsEveryCandidateAsRejected() {
        let store = makeCorruptStore()

        let result = store.importPresets([validPreset(name: "Alpha"), validPreset(name: "Beta")])

        XCTAssertEqual(
            result.rejectedCount,
            2,
            """
            importPresets reported importedCount=\(result.importedCount) rejectedCount=\(result.rejectedCount) \
            in corrupt mode, so SettingsView sets importError = nil and the user believes a restore succeeded.
            """
        )
    }

    /// The corruption banner tells the user to export a backup before resetting, and
    /// SettingsView.exportPresets() encodes exactly `watchedApps.presets`.
    func testExportIsRefusedInCorruptModeInsteadOfWritingAnEmptyBackup() {
        let store = makeCorruptStore()

        // `SettingsView.exportPresets()` now checks this flag before encoding, so it
        // reports an error instead of writing `[]` as a valid-looking backup while
        // the real payload survives only under `<key>.corruptBackup`.
        XCTAssertTrue(
            store.isReadOnlyAfterCorruption,
            "export must be able to tell that the in-memory list is a fallback, not the user's presets"
        )
        XCTAssertFalse(store.canExportPresets)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "\(key).corruptBackup"))
    }

    /// After an explicit reset the store must be fully usable again, and anything
    /// added from that point must persist.
    func testResetAfterCorruptionRestoresWorkingPersistence() {
        let store = makeCorruptStore()

        store.resetAfterCorruption()

        XCTAssertFalse(store.isReadOnlyAfterCorruption)
        XCTAssertTrue(store.add(validPreset(name: "Example")), "adds must work again after a reset")

        let relaunched = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(
            relaunched.presets.contains { $0.displayName == "Example" },
            "a preset added after the reset must survive the next launch"
        )
    }

    private func makeCorruptStore() -> WatchedAppsStore {
        defaults.set(corruptBytes, forKey: key)
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertTrue(store.presets.isEmpty, "precondition: store is in corrupt mode")
        XCTAssertNotNil(store.persistenceIssue, "precondition: store is in corrupt mode")
        return store
    }

    private func validPreset(name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: "\(name)Process",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app"
        )
    }
}
