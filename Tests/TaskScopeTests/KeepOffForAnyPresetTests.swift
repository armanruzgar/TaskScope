import Darwin
import ViewInspector
import XCTest
@testable import TaskScope

/// Keep Off for any preset (L11-11): the per-preset setting and its migration,
/// the switch on every card, and enforcement for custom presets that only
/// signals identity-checked processes, never asks for administrator approval
/// and never touches system launchd jobs.
@MainActor
final class KeepOffForAnyPresetTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults(suiteName: "TaskScope.KeepOffForAnyPresetTests.\(UUID().uuidString)")!
    }

    private let customID = UUID(uuidString: "0D2B6F0E-8C3A-4E55-9A51-3E3F6A6C7B10")!

    private func custom(agents: Bool = true) -> WatchedAppPreset {
        WatchedAppPreset(
            id: customID,
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: agents
                ? [UserLaunchAgentJob(label: "com.example.updater", plistPath: "/Users/Shared/com.example.updater.plist")]
                : []
        )
    }

    // MARK: - The setting

    func testOlderPayloadMigratesTheBuiltInFlagToThePerPresetSet() throws {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"schemaVersion":3,"keepGlobalProtectOff":true}"#.utf8), forKey: "settings")

        let settings = SettingsStore(userDefaults: defaults, key: "settings")

        XCTAssertFalse(settings.isReadOnlyAfterCorruption)
        XCTAssertEqual(settings.keptOffPresetIDs, [WatchedAppPreset.globalProtectID])
        XCTAssertTrue(settings.keepGlobalProtectOff)
        XCTAssertFalse(settings.isKeptOff(customID))
    }

    func testPerPresetSetRoundTripsAndOlderBuildsKeepTheirFlag() throws {
        let defaults = makeDefaults()
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        settings.setKeptOff(true, for: customID)
        settings.keepGlobalProtectOff = true

        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "settings"))) as? [String: Any])
        XCTAssertEqual(stored["keepGlobalProtectOff"] as? Bool, true, "Older builds still read the built-in preset's flag")
        XCTAssertEqual(
            Set((stored["keptOffPresetIDs"] as? [String]) ?? []),
            [customID.uuidString, WatchedAppPreset.globalProtectID.uuidString]
        )
        XCTAssertEqual(SettingsStore(userDefaults: defaults, key: "settings").keptOffPresetIDs, [customID, WatchedAppPreset.globalProtectID])

        // An older build turns the built-in preset's Keep Off off: it writes
        // only its flag and keeps the list it does not know.
        stored["keepGlobalProtectOff"] = false
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: "settings")
        let reloaded = SettingsStore(userDefaults: defaults, key: "settings")
        XCTAssertEqual(reloaded.keptOffPresetIDs, [customID])
        XCTAssertFalse(reloaded.keepGlobalProtectOff)

        reloaded.setKeptOff(false, for: customID)
        XCTAssertTrue(SettingsStore(userDefaults: defaults, key: "settings").keptOffPresetIDs.isEmpty)
    }

    func testAMalformedListIsUnreadableSettingsNotAnEmptyList() {
        let defaults = makeDefaults()
        let payload = Data(#"{"schemaVersion":3,"keepGlobalProtectOff":false,"keptOffPresetIDs":"everything"}"#.utf8)
        defaults.set(payload, forKey: "settings")

        let settings = SettingsStore(userDefaults: defaults, key: "settings")

        XCTAssertTrue(settings.isReadOnlyAfterCorruption, "An unknown Keep Off intent must not read as off")
        XCTAssertEqual(defaults.data(forKey: "settings"), payload)
    }

    func testAppDependenciesKeepEachPresetOffByItsOwnIntent() {
        let defaults = makeDefaults()
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let watchedApps = WatchedAppsStore(userDefaults: defaults, key: "presets")
        let preset = custom()
        XCTAssertTrue(watchedApps.add(preset))
        let dependencies = ProcessManager.Dependencies.app(
            settings: settings, watchedApps: watchedApps, globalProtectServiceObservation: { nil }
        )

        dependencies.setPresetKeptOff(preset, true)

        XCTAssertTrue(settings.isKeptOff(preset.id))
        XCTAssertFalse(settings.keepGlobalProtectOff)
        XCTAssertEqual(dependencies.keptOffPresets().map(\.id), [preset.id])
        XCTAssertTrue(dependencies.isPresetKeptOff(preset))
        XCTAssertFalse(dependencies.isPresetKeptOff(.globalProtect))
        dependencies.setPresetKeptOff(preset, false)
        XCTAssertTrue(dependencies.keptOffPresets().isEmpty)
    }

    // MARK: - Enforcement for a custom preset

    /// The production lifecycle service on a fake runtime: Keep Off disables
    /// the preset's user agent in the login session only, signals only the
    /// processes inside its bundle, and asks for nothing privileged.
    func testCustomKeepOffSignalsOnlyIdentityCheckedProcessesAndNeverTouchesSystemJobs() async {
        let preset = custom()
        let world = KeepOffWorld(rows: [
            row(pid: 501, path: "/Applications/Example.app/Contents/MacOS/Example"),
            row(pid: 502, path: "/Applications/Example.app/Contents/Library/Example Helper"),
            // Same names, outside the bundle: never signalled.
            row(pid: 503, path: "/Users/Shared/Example"),
            row(pid: 504, path: "/tmp/Example Helper")
        ])
        let service = SystemProcessLifecycleService(runtime: world.runtime, disconnect: {
            XCTFail("A custom preset never disconnects anything")
            return .failed("unexpected")
        })
        let manager = ProcessManager(
            processInventory: world.inventory, processSignaler: KeepOffNoSignaler(), lifecycle: service,
            settleAfterProcessChange: {}, dependencies: .inert
        )
        manager.enableNotifications = false
        var keptOff = false
        manager.dependencies.watchedPresets = { [preset] }
        manager.dependencies.isPresetKeptOff = { _ in keptOff }
        manager.dependencies.keptOffPresets = { keptOff ? [preset] : [] }
        manager.dependencies.setPresetKeptOff = { _, value in keptOff = value }

        let result = await manager.keepOff(preset)

        XCTAssertEqual(result.status, .completed, result.message)
        XCTAssertEqual(result.message, "Example is kept off. Its user launch agents are disabled.")
        XCTAssertTrue(keptOff)
        XCTAssertEqual(Set(world.signalledPIDs), [501, 502])
        XCTAssertEqual(manager.lifecycleReport?.title, "Example Keep Off")
        world.assertNothingPrivileged()
        XCTAssertTrue(world.commands.contains(.launchctl("disable", "gui/\(getuid())/com.example.updater")))

        // It came back: background enforcement stops it again, the same way.
        world.restore([
            row(pid: 601, path: "/Applications/Example.app/Contents/MacOS/Example"),
            row(pid: 503, path: "/Users/Shared/Example")
        ])
        world.clearSignals()
        await manager.enforceKeptOffPresets(force: false)

        XCTAssertEqual(world.signalledPIDs, [601])
        world.assertNothingPrivileged()
        XCTAssertEqual(manager.message, "Example is kept off. Its user launch agents are disabled.")
    }

    func testCustomPresetWithoutAgentsIsKeptOffByStoppingItOnly() async {
        let preset = custom(agents: false)
        let world = KeepOffWorld(rows: [row(pid: 501, path: "/Applications/Example.app/Contents/MacOS/Example")])
        let manager = ProcessManager(
            processInventory: world.inventory, processSignaler: KeepOffNoSignaler(),
            lifecycle: SystemProcessLifecycleService(runtime: world.runtime),
            settleAfterProcessChange: {}, dependencies: .inert
        )
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { [preset] }

        let result = await manager.keepOff(preset)

        XCTAssertEqual(result.status, .completed, result.message)
        XCTAssertEqual(result.message, "Example is kept off. TaskScope stops it whenever it finds it running.")
        XCTAssertEqual(world.signalledPIDs, [501])
        XCTAssertTrue(world.commands.isEmpty, "No launch agent, no launchctl: \(world.commands)")
    }

    func testKeepOffIsRefusedForAPresetThatChangedOrWasRemoved() async {
        let lifecycle = UILifecycle()
        let manager = ProcessManager(
            processInventory: UIInventory(processes: []), processSignaler: UIRecordingSignaler(),
            lifecycle: lifecycle, settleAfterProcessChange: {}, dependencies: .inert
        )
        var edited = custom()
        edited.appPath = "/Applications/Other.app"
        var writes = 0
        manager.dependencies.setPresetKeptOff = { _, _ in writes += 1 }

        for watched in [[WatchedAppPreset](), [edited]] {
            manager.dependencies.watchedPresets = { watched }
            let result = await manager.keepOff(custom())
            XCTAssertEqual(result.status, .rejected)
            XCTAssertEqual(result.message, "Example was changed or removed. Keep Off was not recorded and nothing was stopped.")
        }
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(lifecycle.events.isEmpty, "\(lifecycle.events)")
    }

    func testPresetFromANewerBuildCannotBeKeptOffOrAllowedToRun() async throws {
        let json = #"{"id":"\#(customID.uuidString)","displayName":"Example","mainProcessName":"Example","appPath":"/Applications/Example.app","futureRestriction":true}"#
        let newer = try JSONDecoder().decode(WatchedAppPreset.self, from: Data(json.utf8))
        XCTAssertTrue(newer.hasUnknownFields)
        let lifecycle = UILifecycle()
        let manager = ProcessManager(
            processInventory: UIInventory(processes: []), processSignaler: UIRecordingSignaler(),
            lifecycle: lifecycle, settleAfterProcessChange: {}, dependencies: .inert
        )
        manager.dependencies.watchedPresets = { [newer] }

        let keepOff = await manager.keepOff(newer)
        let allow = await manager.allowToRun(newer)

        XCTAssertEqual(keepOff, TaskScopeCommandResult(status: .rejected, message: WatchedAppsStore.newerBuildMessage))
        XCTAssertEqual(allow, TaskScopeCommandResult(status: .rejected, message: WatchedAppsStore.newerBuildMessage))
        XCTAssertTrue(lifecycle.events.isEmpty)
    }

    // MARK: - Allow to Run

    func testTurningACustomPresetsKeepOffOffAllowsItToRunWithoutOpeningIt() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let settings = fixture.stores.settings
        fixture.manager.dependencies.isPresetKeptOff = { settings.isKeptOff($0.id) }
        fixture.manager.dependencies.setPresetKeptOff = { settings.setKeptOff($1, for: $0.id) }
        let preset = custom(agents: false)
        XCTAssertTrue(fixture.stores.watchedApps.add(preset))
        settings.setKeptOff(true, for: preset.id)
        settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        let state = ProcessConfirmationState()
        let view = Batch10.popover(fixture, state: state)

        let card = try XCTUnwrap(view.inspect().findAll(PresetCard.self).first { try $0.actualView().snapshot.preset.id == preset.id })
        XCTAssertTrue(try card.actualView().isKeptOff)
        try card.actualView().onKeepOffChanged(false)
        await state.waitForActions()

        XCTAssertNil(state.pendingPresetAction, "Turning Keep Off off needs no confirmation")
        XCTAssertEqual(fixture.lifecycle.events, ["enable:Example"])
        XCTAssertFalse(settings.isKeptOff(preset.id))
        XCTAssertEqual(fixture.manager.message, "Example is allowed to run. Nothing was started.")
    }

    // MARK: - Guards

    func testAKeptOffOrPendingCustomPresetCannotBeDeleted() {
        let defaults = makeDefaults()
        let session = makeBatch02Session(.interactive, standardDefaults: { defaults })
        defer { session.cleanUp() }
        let stores = TaskScopeLaunchStores(session: session, inventory: Batch02FixedInventory(result: .success([])))
        let preset = custom()
        XCTAssertTrue(stores.watchedApps.add(preset))

        stores.settings.setKeptOff(true, for: preset.id)
        XCTAssertFalse(stores.watchedApps.remove(preset))
        XCTAssertEqual(
            stores.watchedApps.validationError,
            "Turn off Keep Example Off before deleting it. Its user launch agents are disabled by a persistent launchd override that deleting the preset would not clear."
        )
        stores.settings.setKeptOff(false, for: preset.id)
        stores.keepOffActivity.begin(preset.id)
        XCTAssertFalse(stores.watchedApps.remove(preset))
        stores.keepOffActivity.end(preset.id)
        XCTAssertTrue(stores.watchedApps.remove(preset))
    }

    func testAnExplicitCustomKeepOffIsPendingWhileItRuns() async {
        let lifecycle = PendingKeepOffLifecycle()
        let manager = ProcessManager(
            processInventory: UIInventory(processes: []), processSignaler: UIRecordingSignaler(),
            lifecycle: lifecycle, settleAfterProcessChange: {}, dependencies: .inert
        )
        let preset = custom()
        manager.dependencies.watchedPresets = { [preset] }
        lifecycle.onDisable = { [weak manager] in
            XCTAssertEqual(manager?.keepOffActivity.isPending(preset.id), true)
        }

        _ = await manager.keepOff(preset)

        XCTAssertTrue(lifecycle.disabled)
        XCTAssertFalse(manager.keepOffActivity.isPending(preset.id))
    }

    // MARK: - What the user sees

    func testEveryPresetCardOffersKeepOffAndOnlyGlobalProtectKeepsItsExtras() throws {
        let customCard = PresetCard(
            snapshot: .init(preset: custom(), runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: true, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in }
        )
        XCTAssertNoThrow(try customCard.inspect().find(text: "Keep Example Off"))
        XCTAssertNoThrow(try customCard.inspect().find(text: "Disables its launch agents and stops it whenever it is running. Turning this switch off allows it to run again."))
        XCTAssertNoThrow(try customCard.inspect().find(button: "Apply Keep Off…"))
        XCTAssertThrowsError(try customCard.inspect().find(GlobalProtectCompatibilityButton.self))
        XCTAssertThrowsError(try customCard.inspect().find(button: "Stop Services Anyway…"))

        let unknown = PresetCard(
            snapshot: .init(preset: custom(agents: false), runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: false, isKeepOffControlEnabled: false, onKeepOffChanged: { _ in }
        )
        XCTAssertNoThrow(try unknown.inspect().find(text: "Keep Example Off: Unknown"))

        let builtIn = PresetCard(
            snapshot: .init(preset: .globalProtect, runningNames: []), onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in }
        )
        XCTAssertNoThrow(try builtIn.inspect().find(text: "Keep GlobalProtect Off"))
        XCTAssertNoThrow(try builtIn.inspect().find(GlobalProtectCompatibilityButton.self))
    }

    func testConfirmationSaysEnforcementStopsMatchingProcessesWheneverTheyAppear() {
        let pending = ProcessConfirmationState.PendingPresetAction(preset: custom(), action: .keepOff)
        XCTAssertEqual(pending.title, "Keep Example Off?")
        XCTAssertEqual(pending.confirmTitle, "Keep Example Off")
        XCTAssertEqual(
            TaskScopePopoverView.presetConfirmationMessage(for: pending),
            "TaskScope will persistently disable the user launch agents (com.example.updater), so they do not start again, even at login. "
                + "It will then stop the currently running matches for: Example, Example Helper. "
                + "While Keep Off is on, background enforcement stops matching processes whenever they appear. "
                + "Turning Keep Off off, or Open, allows Example to run again. "
                + PresetStopScope.forceStopDisclosure
        )
        XCTAssertEqual(
            ProcessConfirmationState.PendingPresetAction(preset: .globalProtect, action: .keepOff).confirmTitle,
            "Keep GlobalProtect Off"
        )
    }

    /// The import preview and the dry run show what Keep Off would do, so a
    /// mistaken preset is visible before it is stopped on every poll.
    func testDryRunAndImportPreviewDescribeCustomKeepOff() {
        let operations = SettingsView.lifecycleDryRunOperations(for: custom())
        XCTAssertTrue(operations.contains(
            "Keep Off: persistently disable the user launch agents (com.example.updater) in this login session, then stop Example, Example Helper after the same identity checks. While Keep Off is on, background enforcement stops them again whenever they appear. It never requests administrator approval or changes system launch daemons; turning Keep Off off or Open allows the app to run again."
        ), "\(operations)")
        XCTAssertFalse(SettingsView.lifecycleDryRunOperations(for: .globalProtect).contains { $0.hasPrefix("Keep Off: ") })
    }

    // MARK: - Fixtures

    private func row(pid: Int32, path: String) -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1, command: path, executablePath: path,
            elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }
}

/// One fake system for the manager's reads and the lifecycle runtime: a
/// signalled process exits, launchctl answers like a job that is not loaded.
private final class KeepOffWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [AppProcess]
    private var signals: [Int32] = []
    private var recordedCommands: [ExternalCommand] = []

    init(rows: [AppProcess]) {
        self.rows = rows
    }

    var signalledPIDs: [Int32] { lock.withLock { signals } }
    var commands: [ExternalCommand] { lock.withLock { recordedCommands } }
    func clearSignals() { lock.withLock { signals.removeAll() } }
    func restore(_ newRows: [AppProcess]) { lock.withLock { rows = newRows } }

    func assertNothingPrivileged(file: StaticString = #filePath, line: UInt = #line) {
        let commands = commands
        XCTAssertFalse(commands.contains { $0.isAdministratorRequest }, "\(commands)", file: file, line: line)
        XCTAssertFalse(
            commands.contains { $0.arguments.contains { $0.contains("system/") || $0 == "system" } },
            "\(commands)", file: file, line: line
        )
        XCTAssertTrue(
            commands.allSatisfy { $0.arguments.contains { $0.contains("gui/\(getuid())") } },
            "\(commands)", file: file, line: line
        )
    }

    var inventory: any ProcessInventoryProviding { KeepOffWorldInventory(world: self) }

    func load() -> [AppProcess] { lock.withLock { rows } }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: getuid(),
            fileExists: { _ in true },
            launchAgentLabel: { _ in nil },
            runCommand: { [self] command, _ in
                lock.withLock { recordedCommands.append(command) }
                if command.isLaunchctl("disable") {
                    return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
                }
                return ShellCommandResult(
                    command: command, stdout: "",
                    stderr: "Could not find service \"com.example.updater\" in domain for user gui: \(getuid())", exitCode: 113
                )
            },
            loadProcessInventory: { [self] in .success(load()) },
            executablePathForPID: { [self] pid in load().first { $0.pid == pid }?.executablePath },
            sendSignal: { [self] signal, pid in
                lock.withLock {
                    if signal == SIGTERM { signals.append(pid) }
                    rows.removeAll { $0.pid == pid }
                }
                return true
            },
            isProcessAlive: { [self] pid in load().contains { $0.pid == pid } },
            sleep: { _ in },
            systemUptime: { 0 },
            isAppBundle: { _ in true }
        )
    }
}

private struct KeepOffWorldInventory: ProcessInventoryProviding {
    let world: KeepOffWorld
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(world.load())
    }
}

private struct KeepOffNoSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool {
        XCTFail("Preset Keep Off signals through the lifecycle runtime only")
        return false
    }
    func isAlive(_ pid: Int32) -> Bool { false }
}

private final class PendingKeepOffLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    var onDisable: (@MainActor () -> Void)?
    private(set) var disabled = false
    func appBundleExists(at path: String) -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .opened }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .noMatchingProcesses }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { true }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        await onDisable?()
        disabled = true
        return .notNeeded
    }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        XCTFail("A custom preset has no system daemon step")
        return .notNeeded
    }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
}
