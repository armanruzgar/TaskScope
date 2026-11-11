import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the composition root and runtime
// (TaskScopeRuntime), the command coordinator's Open and Stop routing, and the
// Stop Watched App intent. Lifecycle, inventory and signaler are fakes: nothing
// is signalled and no launchctl, Accessibility or notification call is made.

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
private struct Batch02RuntimeRig {
    let defaults: InMemoryUserDefaults
    let session: TaskScopeLaunchSession
    let stores: TaskScopeLaunchStores
    let lifecycle: Batch02RecordingLifecycle
    let polling: Batch02PollingRecorder
    let manager: ProcessManager
    let bus: AppCommandBus
    let runtime: TaskScopeRuntime
    let effects: Batch02EffectsRecorder

    init(
        context: TaskScopeLaunchContext = .interactive,
        defaults: InMemoryUserDefaults = batch02Defaults(),
        inventory: any ProcessInventoryProviding = Batch02FixedInventory(result: .success([]))
    ) {
        self.defaults = defaults
        session = makeBatch02Session(context, standardDefaults: { defaults })
        stores = TaskScopeLaunchStores(session: session, inventory: inventory)
        lifecycle = Batch02RecordingLifecycle()
        polling = Batch02PollingRecorder()
        manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: Batch02InertSignaler(),
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
private final class Batch02EffectsRecorder {
    var events: [String] = []
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Composition root and runtime (T02-6, A01-3)

@MainActor
final class Batch02RuntimeTests: XCTestCase {
    /// T02-6: Keep Off and Open record the intent where the app reads it back.
    func testKeepOffAndOpenPersistTheIntentThroughTheAppWiring() async {
        let rig = Batch02RuntimeRig(
            inventory: Batch02ScriptedInventory(results: [.success([])])
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

// MARK: - Coordinator routing (T05-2, T05-1)

@MainActor
final class Batch02CoordinatorTests: XCTestCase {
    private func examplePreset() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
    }

    private func exampleRow(pid: Int32) -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: 0, netOutKB: 0, diskReadBytes: 0, diskWriteBytes: 0
        )
    }

    private func manager(
        inventory: any ProcessInventoryProviding, lifecycle: Batch02RecordingLifecycle
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory, processSignaler: Batch02InertSignaler(),
            lifecycle: lifecycle, settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    /// T05-2: Open opens the app and never takes a stop path.
    func testOpenEntityCommandOpensTheAppAndNeverStopsIt() async {
        let lifecycle = Batch02RecordingLifecycle()
        let inventory = Batch02ScriptedInventory(results: [.success([]), .success([]), .success([exampleRow(pid: 42)])])
        let preset = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: inventory, lifecycle: lifecycle), presets: { [preset] }
        )

        let result = await coordinator.perform(.openPresetEntity(
            WatchedPresetCommandTarget(id: preset.id, displayName: preset.displayName)
        ))

        XCTAssertEqual(result.status, .completed, result.message)
        XCTAssertEqual(result.message, "Opened Example.")
        XCTAssertTrue(lifecycle.calls.contains("open"), "\(lifecycle.calls)")
        XCTAssertFalse(lifecycle.calls.contains { $0.hasPrefix("terminate") || $0 == "agents.unload" },
                       "Open must never stop anything: \(lifecycle.calls)")
    }

    /// T05-2: Open resolves the preset by its stable identifier only; a preset
    /// that merely has the same display name is not opened.
    func testOpenEntityCommandRejectsAReplacementPresetWithTheSameDisplayName() async {
        let lifecycle = Batch02RecordingLifecycle()
        let replacement = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: Batch02FixedInventory(result: .success([])), lifecycle: lifecycle),
            presets: { [replacement] }
        )

        let result = await coordinator.perform(.openPresetEntity(
            WatchedPresetCommandTarget(id: UUID(), displayName: "Example")
        ))

        XCTAssertEqual(result.status, .rejected)
        XCTAssertTrue(result.message.contains("Example"), result.message)
        XCTAssertEqual(lifecycle.calls, [], "No lifecycle work for an unknown preset")
    }

    /// T05-2 control: Stop stops and never opens.
    func testStopEntityCommandStopsTheAppAndNeverOpensIt() async {
        let lifecycle = Batch02RecordingLifecycle()
        let inventory = Batch02ScriptedInventory(results: [.success([exampleRow(pid: 42)]), .success([])])
        let preset = examplePreset()
        let coordinator = AppCommandCoordinator(
            processManager: manager(inventory: inventory, lifecycle: lifecycle), presets: { [preset] }
        )

        _ = await coordinator.perform(.stopPresetEntity(
            WatchedPresetCommandTarget(id: preset.id, displayName: preset.displayName)
        ))

        XCTAssertTrue(lifecycle.calls.contains("terminate:Example"), "\(lifecycle.calls)")
        XCTAssertFalse(lifecycle.calls.contains("open"), "\(lifecycle.calls)")
    }

    /// T05-1: Shortcuts Stop of the built-in GlobalProtect preset, through the
    /// app's own wiring, stays in user-process scope: no VPN disconnect, no Keep
    /// Off intent, no persistent agent disable, no system daemon, and only the
    /// interface agent is unloaded.
    func testShortcutsStopOfGlobalProtectStaysInUserProcessScope() async throws {
        let rig = Batch02RuntimeRig()
        defer { rig.tearDown() }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)

        _ = try await intent.executeStop(
            bus: rig.bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { _ in }

        XCTAssertFalse(rig.lifecycle.calls.contains("vpn.disconnect"), "\(rig.lifecycle.calls)")
        XCTAssertFalse(rig.lifecycle.calls.contains("agents.disable"))
        XCTAssertFalse(rig.lifecycle.calls.contains { $0.hasPrefix("daemon.disable") })
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff, "Shortcuts Stop must not record Keep Off")
        XCTAssertEqual(rig.lifecycle.unloadedAgentLabels.first, ["com.paloaltonetworks.gp.pangpa"])
        XCTAssertEqual(rig.lifecycle.unloadedDaemonJobCounts.first, 0)
    }

    /// T05-1: a failed Shortcuts Stop is recorded as Close in diagnostics.
    func testShortcutsStopFailureIsRecordedAsClose() async throws {
        let rig = Batch02RuntimeRig(
            inventory: Batch02FixedInventory(result: .failure(.commandFailed("ps unavailable")))
        )
        defer { rig.tearDown() }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)

        let result = try await intent.executeStop(
            bus: rig.bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { _ in }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(rig.manager.lifecycleDiagnostics.failures(for: WatchedAppPreset.globalProtectID).map(\.action),
                       [.close])
        XCTAssertEqual(rig.lifecycle.calls, [])
        XCTAssertFalse(rig.stores.settings.keepGlobalProtectOff)
    }
}

// MARK: - Stop Watched App intent (T05-4, L12-1)

@MainActor
final class Batch02StopIntentTests: XCTestCase {
    /// T05-4: perform() asks the system to confirm before anything is
    /// submitted, and a declined confirmation submits nothing.
    func testPerformAsksForConfirmationBeforeSubmittingAndDeclineStopsNothing() async throws {
        let savedBus = StopWatchedAppIntent.commandBus
        let savedConfirmation = StopWatchedAppIntent.requestStopConfirmation
        defer {
            StopWatchedAppIntent.commandBus = savedBus
            StopWatchedAppIntent.requestStopConfirmation = savedConfirmation
        }
        var events: [String] = []
        let bus = AppCommandBus()
        bus.install { command in
            events.append("submitted \(command)")
            return .init(status: .completed, message: "Stopped Example.")
        }
        StopWatchedAppIntent.commandBus = bus
        StopWatchedAppIntent.requestStopConfirmation = { intent, message in
            XCTAssertTrue(message.contains("force stopped"), message)
            events.append("confirm \(intent.app.displayName)")
        }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(id: UUID(), displayName: "Example")

        _ = try await intent.perform()

        XCTAssertEqual(events, ["confirm Example", "submitted \(TaskScopeCommand.stopPresetEntity(intent.app.commandTarget))"])

        StopWatchedAppIntent.requestStopConfirmation = { _, _ in throw CancellationError() }
        do {
            _ = try await intent.perform()
            XCTFail("A declined confirmation must throw")
        } catch is CancellationError {}
        XCTAssertEqual(events.count, 2, "A declined confirmation submits nothing")
    }

    /// T05-4: on macOS 14 a declined confirmation comes back as false.
    func testADeclinedMacOS14ConfirmationCancels() {
        XCTAssertNoThrow(try StopWatchedAppIntent.requireConfirmed(true))
        XCTAssertThrowsError(try StopWatchedAppIntent.requireConfirmed(false)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// L12-1: the Shortcuts confirmation discloses what the stop does, like the
    /// in-app Close confirmation: the agents it unloads and the force stop.
    func testTheConfirmationDisclosesAgentUnloadsAndTheForceStop() async throws {
        let custom = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(
                label: "com.example.batch02.agent",
                plistPath: "/Library/LaunchAgents/com.example.batch02.agent.plist"
            )]
        )
        let customMessage = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(preset: custom), preset: custom
        )
        XCTAssertTrue(customMessage.hasPrefix("Stop Example and its eligible watched processes?"), customMessage)
        XCTAssertTrue(customMessage.contains("com.example.batch02.agent"), customMessage)
        XCTAssertTrue(customMessage.contains(PresetStopScope.forceStopDisclosure), customMessage)
        XCTAssertTrue(customMessage.contains("3 seconds"), customMessage)

        let globalProtect = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(preset: .globalProtect), preset: .globalProtect
        )
        XCTAssertTrue(globalProtect.contains("com.paloaltonetworks.gp.pangpa"), globalProtect)
        XCTAssertFalse(globalProtect.contains("pangps"), "Shortcuts Stop never unloads the VPN service")

        let unknown = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(id: UUID(), displayName: "Gone"), preset: nil
        )
        XCTAssertTrue(unknown.contains(PresetStopScope.forceStopDisclosure), unknown)

        // The intent looks the preset up in the stored catalog.
        let bus = AppCommandBus()
        bus.install { _ in .init(status: .completed, message: "Stopped.") }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)
        var shown: String?
        _ = try await intent.executeStop(
            bus: bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { shown = $0 }
        XCTAssertEqual(shown, globalProtect)
    }
}
