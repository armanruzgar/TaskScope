import XCTest
@testable import TaskScope

/// (Audit item P9.) `WatchedAppPreset.globalProtect` gets a fresh `UUID()` in every process
/// (`static let` is memoized per process, not persisted), and `WatchedAppsStore.init`
/// assigns `presets = [.globalProtect]` *inside* `init`, which does not fire the
/// `didSet { persistIfAllowed() }` observer. Nothing ever pins that identifier, so a
/// Shortcut bound to the built-in watched app cannot resolve after a relaunch.
@MainActor
final class DefaultPresetIdentityTests: XCTestCase {
    private let suiteName = "TaskScope.DefaultPresetIdentityTests.\(UUID().uuidString)"
    private let key = "watched-presets-p9-tests"
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!

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

    /// Seeding the default preset must write it through, otherwise the identifier the app
    /// publishes to Shortcuts only exists in memory for the lifetime of this process.
    func testSeedingTheDefaultPresetPinsItsIdentifierInStorage() throws {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        XCTAssertEqual(store.presets.map(\.displayName), ["GlobalProtect"])

        let payload = try XCTUnwrap(
            defaults.data(forKey: key),
            """
            No payload was written to \(key) after the store seeded [.globalProtect]. \
            The assignment happens inside init, so didSet/persistIfAllowed never runs, and \
            WatchedAppPreset.globalProtect.id (a fresh UUID per process) is never frozen.
            """
        )
        let persisted = try JSONDecoder().decode([WatchedAppPreset].self, from: payload)
        XCTAssertEqual(persisted.map(\.id), store.presets.map(\.id))
    }

    /// Same hole seen through the App Intents surface Shortcuts actually queries: the id
    /// handed out by `WatchedPresetCatalog` must be backed by bytes on disk, or the binding
    /// a user creates today is dangling tomorrow.
    func testIdentifierPublishedToShortcutsIsBackedByStoredBytes() throws {
        let catalog = WatchedPresetCatalog(key: key, objectForKey: defaults.objectReader)
        let boundID = try XCTUnwrap(catalog.entities().first?.id)

        // A normal launch: the menu-bar app constructs its store against the same suite.
        _ = WatchedAppsStore(userDefaults: defaults, key: key)

        let stored = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([WatchedAppPreset].self, from: $0) } ?? []
        XCTAssertTrue(
            stored.contains { $0.id == boundID },
            """
            The identifier Shortcuts stores (\(boundID)) is absent from persisted storage \
            (stored ids: \(stored.map(\.id))). WatchedPresetEntityQuery.entities(for:) filters \
            by exactly this id, so after the next launch mints a new one the Shortcut resolves to [].
            """
        )
    }

    /// The identifier must be a compile-time constant, not minted per process.
    ///
    /// This was originally proved by running the suite twice and comparing, because
    /// a `static let` with a `UUID()` default produces a different value in every
    /// process. Pinning it to a literal makes that stability checkable in one run —
    /// and any future edit to the literal fails here rather than silently breaking
    /// every Shortcut already bound to the built-in preset.
    func testGlobalProtectIdentifierIsAFixedConstantNotMintedPerProcess() {
        XCTAssertEqual(
            WatchedAppPreset.globalProtect.id,
            WatchedAppPreset.globalProtectID
        )
        XCTAssertEqual(
            WatchedAppPreset.globalProtectID.uuidString,
            "1B0E5C1E-6B0A-4F2E-9E7B-2C3A5D8F41A7",
            """
            Changing this literal orphans every Shortcut bound to the built-in \
            GlobalProtect watched app, because WatchedPresetEntityQuery.entities(for:) \
            resolves purely by id.
            """
        )
    }
}
