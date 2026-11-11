import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the composition root and runtime
// (TaskScopeRuntime), the command coordinator's Open and Stop routing, and the
// Stop Watched App intent. Lifecycle, inventory and signaler are fakes: nothing
// is signalled and no launchctl, Accessibility or notification call is made.

// MARK: - Composition root and runtime (T02-6, A01-3)

@MainActor
final class Batch02RuntimeTests: XCTestCase {
    /// T02-6: Keep Off and Open record the intent where the app reads it back.
    func testKeepOffAndOpenPersistTheIntentThroughTheAppWiring() async {
        let rig = Batch02RuntimeRig(
            inventory: ScriptedInventory([.success([])], repeatsLast: true)
        )
        defer { rig.tearDown() }
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff)
        XCTAssertEqual(rig.manager.dependencies.keptOffPresets().map(\.id), [])

        _ = await rig.manager.keepOff(.globalProtect)

        XCTAssertTrue(rig.stores.settings.keepGlobalProtectOff, "Keep Off must be recorded as on: \(rig.lifecycle.calls)")
        XCTAssertTrue(SettingsStore(userDefaults: rig.defaults).keepGlobalProtectOff, "and saved")
        XCTAssertEqual(rig.manager.dependencies.keptOffPresets().map(\.id), [WatchedAppPreset.globalProtectID])
        XCTAssertEqual(rig.manager.dependencies.isPresetKeptOff(.globalProtect), true)

        _ = await rig.manager.openApp(.globalProtect)

        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff, "Open must clear Keep Off: \(rig.lifecycle.calls)")
        XCTAssertEqual(rig.manager.dependencies.keptOffPresets().map(\.id), [])
    }

    /// T02-6: with unreadable settings the Keep Off intent cannot be written, so
    /// Keep Off is refused before any lifecycle step.
    func testReadOnlySettingsRefuseKeepOffBeforeAnyLifecycleStep() async {
        let defaults = batch02Defaults()
        defaults.set(Data(#"{"refreshIntervalSeconds":"invalid"}"#.utf8), forKey: "TaskScope.settings.v1")
        let rig = Batch02RuntimeRig(defaults: defaults)
        defer { rig.tearDown() }
        XCTAssertTrue(rig.stores.settings.isReadOnlyAfterCorruption)

        let result = await rig.manager.keepOff(.globalProtect)

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(rig.lifecycle.calls, [], "No disconnect or service change over unreadable settings")
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff)
    }

    /// T02-6, A01-3: starting the runtime starts polling at the saved interval,
    /// the Auto Stop engine, and exactly one forced Keep Off enforcement, which
    /// never asks for administrator rights.
    func testStartRunsPollingTheRulesEngineAndOneForcedEnforcement() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        rig.stores.settings.refreshIntervalSeconds = 15
        rig.stores.settings.keepGlobalProtectOff = true
        XCTAssertFalse(rig.stores.autoStopRules.isEngineRunning)

        await rig.start(.loginItem)
        await waitUntil { !rig.polling.intervals.isEmpty }

        XCTAssertTrue(rig.runtime.didStart)
        XCTAssertTrue(rig.stores.autoStopRules.isEngineRunning, "The Auto Stop engine must run")
        XCTAssertEqual(rig.polling.intervals, [15], "Polling must start at the saved interval")
        XCTAssertEqual(rig.lifecycle.calls.filter { $0.hasPrefix("daemon.disable") }, ["daemon.disable:false"],
                       "One forced enforcement, without an administrator prompt: \(rig.lifecycle.calls)")
        XCTAssertEqual(rig.effects.events, ["refresh shortcuts"], "Asks for the deferred Shortcuts refresh once")

        await rig.start(.loginItem)
        XCTAssertEqual(rig.polling.intervals, [15], "Starting twice does nothing")
        XCTAssertEqual(rig.lifecycle.calls.filter { $0.hasPrefix("daemon.disable") }.count, 1)
    }

    /// A01-3: settings changes reach ProcessManager without any SwiftUI view.
    func testSettingsChangesReachProcessManager() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        // Background Keep Off enforcement needs the poll even with no view open.
        rig.stores.settings.keepGlobalProtectOff = true
        await rig.start(.interactive)
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.intervals, [10])
        XCTAssertEqual(rig.manager.sortKey, .cpu)

        rig.stores.settings.refreshIntervalSeconds = 20
        rig.stores.settings.sortKeyRaw = ProcessSortKey.memory.rawValue
        await waitUntil { rig.polling.intervals.count == 2 && rig.manager.sortKey == .memory }

        XCTAssertEqual(rig.polling.intervals, [10, 20])
        XCTAssertEqual(rig.manager.sortKey, .memory)
        XCTAssertEqual(rig.manager.sortOrder.direction, .descending)

        // L09-21: the direction follows the setting too.
        rig.stores.settings.setSortOrder(ProcessSortOrder(key: .memory, direction: .ascending))
        await waitUntil { rig.manager.sortOrder.direction == .ascending }
        XCTAssertEqual(rig.manager.sortOrder, ProcessSortOrder(key: .memory, direction: .ascending))

        rig.stores.settings.enableNotifications = true
        await waitUntil { rig.manager.enableNotifications }
        XCTAssertTrue(rig.manager.enableNotifications)
        XCTAssertEqual(rig.effects.events.suffix(2), ["request authorization", "prime baseline"])

        rig.stores.settings.enableNotifications = false
        await waitUntil { !rig.manager.enableNotifications }
        XCTAssertFalse(rig.manager.enableNotifications)
    }

    /// L11-21: the menu-bar icon shows watched status, so while its setting is
    /// on the poll runs with no view open; with it off nothing else needs it.
    func testMenuBarStatusKeepsBackgroundReadsWhileItIsShown() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        XCTAssertTrue(rig.stores.settings.showsMenuBarStatus, "on by default")
        XCTAssertFalse(rig.stores.settings.enableNotifications || rig.stores.settings.keepGlobalProtectOff)
        XCTAssertEqual(rig.runtime.backgroundPolling, .menuBarIcon)
        await rig.start(.interactive)
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.intervals, [30], "The icon alone reads every 30 seconds with no view open")

        rig.stores.settings.showsMenuBarStatus = false
        await waitUntil { rig.polling.cancellations > 0 }
        XCTAssertEqual(rig.polling.cancellations, 1, "Nothing else needs a background read")
        XCTAssertEqual(rig.polling.intervals, [30])
        XCTAssertEqual(rig.runtime.backgroundPolling, .off)

        rig.stores.settings.showsMenuBarStatus = true
        await waitUntil { rig.polling.intervals.count == 2 }
        XCTAssertEqual(rig.polling.intervals, [30, 30])
    }

    /// L11-21: notifications and Keep Off need every read, so they keep the
    /// interval; the icon's slower cadence applies only while it reads alone.
    func testNotificationsAndKeepOffKeepTheIntervalForBackgroundReads() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        rig.stores.settings.refreshIntervalSeconds = 15
        await rig.start(.interactive)
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.intervals, [30])

        rig.stores.settings.enableNotifications = true
        await waitUntil { rig.polling.intervals.count == 2 }
        XCTAssertEqual(rig.polling.intervals, [30, 15], "notifications diff every read")
        XCTAssertEqual(rig.runtime.backgroundPolling, .interval)

        rig.stores.settings.enableNotifications = false
        await waitUntil { rig.polling.intervals.count == 3 }
        XCTAssertEqual(rig.polling.intervals.last, 30)

        rig.stores.settings.setKeptOff(true, for: WatchedAppPreset.globalProtectID)
        await waitUntil { rig.polling.intervals.count == 4 }
        XCTAssertEqual(rig.polling.intervals.last, 15, "Keep Off enforcement runs on every tick")
        XCTAssertEqual(rig.runtime.backgroundPolling, .interval)

        // A refresh interval longer than 30 seconds stays the icon's cadence too.
        rig.stores.settings.setKeptOff(false, for: WatchedAppPreset.globalProtectID)
        rig.stores.settings.refreshIntervalSeconds = 45
        await waitUntil { rig.polling.intervals.last == 45 }
        XCTAssertEqual(rig.runtime.backgroundPolling, .menuBarIcon)
    }

    /// L11-17 review: Keep Off left for a preset that is gone has nothing to
    /// enforce, and nothing in the app can turn it off, so it must not keep
    /// background reads at the interval.
    func testKeepOffForAPresetThatIsGoneDoesNotKeepTheInterval() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        rig.stores.settings.refreshIntervalSeconds = 15
        await rig.start(.interactive)
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.intervals, [30])

        rig.stores.settings.setKeptOff(true, for: UUID())
        await waitUntil { rig.polling.intervals.count == 2 }
        XCTAssertEqual(rig.polling.intervals, [30, 30], "nothing to enforce")
        XCTAssertEqual(rig.runtime.backgroundPolling, .menuBarIcon)
    }

    /// The cadence follows the presets too: restoring the built-in preset (a
    /// restore, not an import) brings its Keep GlobalProtect Off back into
    /// force, as the recovery notice says, and enforcement needs every read.
    func testAKeptOffPresetThatComesBackRestoresTheInterval() async throws {
        let defaults = batch02Defaults()
        defaults.set(try JSONEncoder().encode([WatchedAppPreset]()), forKey: WatchedAppsStore.defaultPersistenceKey)
        let rig = Batch02RuntimeRig(defaults: defaults)
        defer { rig.tearDown() }
        rig.stores.settings.keepGlobalProtectOff = true
        rig.stores.settings.refreshIntervalSeconds = 15
        await rig.start(.interactive)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(rig.polling.intervals, [], "Keep Off for a preset that is gone needs no background read")
        XCTAssertEqual(rig.runtime.backgroundPolling, .off)

        XCTAssertTrue(rig.stores.watchedApps.restoreBuiltInPreset())
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.intervals, [15])
        XCTAssertEqual(rig.runtime.backgroundPolling, .interval)
    }

    /// L11-21: with no preset there is nothing for the icon to show.
    func testMenuBarStatusNeedsNoBackgroundReadsWithoutPresets() async throws {
        let defaults = batch02Defaults()
        defaults.set(try JSONEncoder().encode([WatchedAppPreset]()), forKey: WatchedAppsStore.defaultPersistenceKey)
        let rig = Batch02RuntimeRig(defaults: defaults)
        defer { rig.tearDown() }
        XCTAssertTrue(rig.stores.watchedApps.presets.isEmpty, "precondition: an empty stored preset list")
        await rig.start(.interactive)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(rig.polling.intervals, [], "No preset, no background read")
    }

    /// L11-17 review: an identity can stay kept off after its preset is gone
    /// (lost in a preset recovery reset, or deleted by an older build). A
    /// preset an import creates must not come back kept off and be stopped at
    /// the next poll, whichever import brings it.
    func testImportedPresetsNeverArriveKeptOff() async throws {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        let viaPresets = WatchedAppPreset(
            displayName: "Restored", mainProcessName: "Restored", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/Restored.app"
        )
        let viaBackup = WatchedAppPreset(
            displayName: "Backed Up", mainProcessName: "BackedUp", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/BackedUp.app"
        )
        for preset in [viaPresets, viaBackup] {
            rig.stores.settings.setKeptOff(true, for: preset.id)
            XCTAssertFalse(rig.stores.watchedApps.presets.contains { $0.id == preset.id }, "precondition: the preset is gone")
        }

        // Settings > Watched Apps > Import…
        let presetData = try JSONEncoder().encode([viaPresets])
        let presetActions = PresetSettingsActions()
        presetActions.fileSize = { _ in presetData.count }
        presetActions.readFile = { _ in presetData }
        presetActions.loadImport(from: URL(fileURLWithPath: "/nonexistent/presets.json"), into: rig.stores.watchedApps)
        presetActions.commitImport(into: rig.stores.watchedApps)
        XCTAssertTrue(rig.stores.watchedApps.presets.contains { $0.id == viaPresets.id })
        XCTAssertFalse(rig.stores.settings.isKeptOff(viaPresets.id), "the restored preset arrives not kept off")

        // Settings > General > Import Configuration…
        let backup = try ConfigurationArchive.encode(
            presets: try JSONSerialization.jsonObject(with: JSONEncoder().encode([viaBackup]))
        )
        let backupActions = ConfigurationBackupActions()
        backupActions.fileSize = { _ in backup.count }
        backupActions.readFile = { _ in backup }
        let stores = ConfigurationBackupActions.Stores(
            watchedApps: rig.stores.watchedApps, autoStopRules: rig.stores.autoStopRules,
            savedSelections: nil, settings: rig.stores.settings, hotkey: HotkeyManager(
                defaults: rig.defaults, defaultsKey: "batch02.hotkey", backend: RecordingHotkeyBackend()
            )
        )
        backupActions.loadImport(from: URL(fileURLWithPath: "/nonexistent/backup.json"), into: stores)
        backupActions.commitImport(into: stores)
        XCTAssertTrue(rig.stores.watchedApps.presets.contains { $0.id == viaBackup.id })
        XCTAssertFalse(rig.stores.settings.isKeptOff(viaBackup.id))
        XCTAssertEqual(rig.manager.dependencies.keptOffPresets(), [], "background enforcement has nothing to stop")
    }

    /// The same holds for the built-in preset and its legacy Keep GlobalProtect
    /// Off flag, should an import ever bring it back.
    func testAnImportedBuiltInPresetArrivesWithKeepGlobalProtectOffOff() async throws {
        let defaults = batch02Defaults()
        defaults.set(try JSONEncoder().encode([WatchedAppPreset]()), forKey: WatchedAppsStore.defaultPersistenceKey)
        let rig = Batch02RuntimeRig(defaults: defaults)
        defer { rig.tearDown() }
        rig.stores.settings.keepGlobalProtectOff = true
        XCTAssertTrue(rig.stores.watchedApps.presets.isEmpty, "precondition: the built-in preset is gone")

        let result = rig.stores.watchedApps.importPresets([.globalProtect])
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff)
        XCTAssertFalse(rig.stores.settings.isKeptOff(WatchedAppPreset.globalProtectID))
        rig.stores.settings.flushPendingWrites()
        XCTAssertFalse(SettingsStore(userDefaults: rig.defaults).keepGlobalProtectOff, "the saved legacy flag is off too")

        // A preset the import does not create keeps its Keep Off.
        rig.stores.settings.keepGlobalProtectOff = true
        XCTAssertEqual(rig.stores.watchedApps.importPresets([.globalProtect]).importedCount, 0)
        XCTAssertTrue(rig.stores.settings.keepGlobalProtectOff, "an existing preset is left as it is")
    }

    /// T02-6: stopping the runtime (what quitting does) saves a pending search.
    func testStopSavesPendingSettingsWritesAndStopsPolling() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        rig.stores.settings.keepGlobalProtectOff = true
        await rig.start(.interactive)
        await waitUntil { !rig.polling.intervals.isEmpty }
        XCTAssertEqual(rig.polling.cancellations, 0)
        rig.stores.settings.searchText = "batch02 search"
        XCTAssertNotEqual(SettingsStore(userDefaults: rig.defaults).searchText, "batch02 search",
                          "The search is saved after a quiet period")

        rig.runtime.stop()

        XCTAssertEqual(SettingsStore(userDefaults: rig.defaults).searchText, "batch02 search")
        XCTAssertFalse(rig.stores.autoStopRules.isEngineRunning)
        await waitUntil { rig.polling.cancellations > 0 }
        XCTAssertEqual(rig.polling.cancellations, 1, "No poll tick may start new work while quitting")
    }

    /// The runtime installs the command handler: commands are answered, and
    /// startup verification never starts the runtime.
    func testCommandsAreAnsweredAndStartupVerificationNeverStarts() async {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        let refresh = await batch02Submit(.refresh, to: rig.bus)
        XCTAssertEqual(refresh?.status, .completed, refresh?.message ?? "no answer")

        let verification = Batch02RuntimeRig(context: .startupVerification)
        defer { verification.tearDown() }
        await verification.start(.startupVerification)
        XCTAssertFalse(verification.runtime.didStart)
        XCTAssertFalse(verification.stores.autoStopRules.isEngineRunning)
        XCTAssertEqual(verification.polling.intervals, [])
        let rejected = await batch02Submit(.refresh, to: verification.bus)
        XCTAssertEqual(rejected, AppCommandCoordinator.startupVerificationRejection)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Records the polling intervals ProcessManager schedules; never fires a tick.
final class Batch02PollingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var cancelled = 0

    var intervals: [TimeInterval] { lock.withLock { recorded } }
    var cancellations: Int { lock.withLock { cancelled } }

    @MainActor
    func controller() -> ProcessPollingController {
        ProcessPollingController(sleep: { [self] interval in
            lock.withLock { recorded.append(interval) }
            do {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                return true
            } catch {
                lock.withLock { cancelled += 1 }
                return false
            }
        })
    }
}

@MainActor
struct Batch02RuntimeRig {
    let defaults: InMemoryUserDefaults
    let session: TaskScopeLaunchSession
    let stores: TaskScopeLaunchStores
    let lifecycle: FakeLifecycle
    let polling: Batch02PollingRecorder
    let manager: ProcessManager
    let bus: AppCommandBus
    let runtime: TaskScopeRuntime
    let effects: Batch02EffectsRecorder

    init(
        context: TaskScopeLaunchContext = .interactive,
        defaults: InMemoryUserDefaults = batch02Defaults(),
        inventory: any ProcessInventoryProviding = ScriptedInventory(processes: [])
    ) {
        self.defaults = defaults
        session = makeBatch02Session(context, standardDefaults: { defaults })
        stores = TaskScopeLaunchStores(session: session, inventory: inventory)
        lifecycle = FakeLifecycle.allSucceeding()
        polling = Batch02PollingRecorder()
        manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: FakeSignaler(),
            lifecycle: lifecycle,
            settleAfterProcessChange: {},
            currentPID: 99_999,
            pollingController: polling.controller(),
            // As TaskScopeApp wires it, with no live service reading.
            keepOffActivity: stores.keepOffActivity,
            dependencies: .app(settings: stores.settings, watchedApps: stores.watchedApps, globalProtectServiceObservation: { nil })
        )
        bus = AppCommandBus()
        let effects = Batch02EffectsRecorder()
        self.effects = effects
        runtime = TaskScopeRuntime(
            session: session,
            stores: stores,
            processManager: manager,
            history: ProcessHistory(inventory: inventory),
            bus: bus,
            effects: .init(
                requestNotificationAuthorization: { effects.events.append("request authorization") },
                primeNotificationBaseline: { _ in effects.events.append("prime baseline") }
            )
        )
    }

    func start(_ context: TaskScopeLaunchContext) async {
        let effects = effects
        await runtime.start(context: context) { effects.events.append("refresh shortcuts") }
    }

    func tearDown() {
        runtime.stop()
        session.cleanUp()
    }
}

@MainActor
final class Batch02EffectsRecorder {
    var events: [String] = []
}
