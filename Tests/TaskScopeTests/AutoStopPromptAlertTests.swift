import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Drives the real `.alert(_:isPresented:presenting:)` modifier in
/// `TaskScopePopoverView` through ViewInspector.
///
/// ViewInspector's `ViewType.Button.tap()` only invokes the button's action closure; it does
/// not perform SwiftUI's automatic `isPresented = false` write-back. That write-back is driven
/// explicitly here with `InspectableView<ViewType.Alert>.dismiss()`, which for the iOS 15-style
/// alert sets `binding.wrappedValue = false` and therefore runs the app's own binding setter.
/// Both the button action and the binding setter are the production closures.
@MainActor
final class AutoStopPromptAlertTests: XCTestCase {
    /// Sub-claim (a): one prompt queued, user taps "Stop Now".
    func testStopNowOnTheOnlyPromptActuallyStopsThatProcess() async throws {
        let target = process(pid: 41, name: "Example")
        let fixture = await makeFixture(processes: [target])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41], "setup: one prompt queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example (PID 41) has run for 3m, beyond the 1-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Stop Now").tap()
        try alert.dismiss()
        await store.waitForPromptActions()

        XCTAssertEqual(
            stopped.pids,
            [41],
            "Tapping Stop Now must send a stop request for the process the alert displayed"
        )
        XCTAssertEqual(
            store.events.first?.outcome,
            .stopped,
            "The logged outcome for a Stop Now tap must be .stopped, not .dismissed"
        )
    }

    /// Sub-claim (b): two prompts queued, user taps "Stop Now" on prompt #1.
    func testStopNowNeverStopsAProcessTheAlertDidNotDisplay() async throws {
        let shown = process(pid: 41, name: "Example")
        let unshown = process(pid: 42, name: "Other")
        let fixture = await makeFixture(processes: [shown, unshown])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42], "setup: two prompts queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example (PID 41) has run for 3m, beyond the 1-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Stop Now").tap()
        try alert.dismiss()
        await store.waitForPromptActions()

        XCTAssertFalse(
            stopped.pids.contains(42),
            "Stop Now on the pid 41 prompt must never stop pid 42, which the alert never displayed"
        )
        XCTAssertEqual(stopped.pids, [41], "Stop Now must stop the displayed process, pid 41")
    }

    /// Sub-claim (c): two prompts queued, user taps "Dismiss".
    func testDismissConsumesOnlyThePromptTheAlertDisplayed() async throws {
        let shown = process(pid: 41, name: "Example")
        let queued = process(pid: 42, name: "Other")
        let fixture = await makeFixture(processes: [shown, queued])
        defer { fixture.stores.cleanup() }

        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt))
        store.add(AutoStopRule(processName: "Other", runtimeMinutes: 1, action: .prompt))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42], "setup: two prompts queued")

        let view = makePopover(fixture: fixture)
        let alert = try view.inspect().find(ViewType.Alert.self)
        XCTAssertNoThrow(
            try alert.find(text: "Example (PID 41) has run for 3m, beyond the 1-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."),
            "setup: the alert must be displaying the prompt for pid 41"
        )

        try alert.find(button: "Dismiss").tap()
        try alert.dismiss()
        await store.waitForPromptActions()

        XCTAssertEqual(
            store.pendingPrompts.map(\.process.pid),
            [42],
            "One Dismiss tap must consume only the displayed prompt; pid 42 must still be queued"
        )
        XCTAssertTrue(stopped.pids.isEmpty)
        XCTAssertEqual(store.events.map(\.outcome), [.dismissed])
        XCTAssertEqual(
            store.events.count,
            1,
            "One Dismiss tap must log exactly one event, not silently dismiss the unseen prompt too"
        )
    }

    func testPrunedHeadReplacesAlertIdentityWithoutRetargetingOldActions() async throws {
        let shown = process(pid: 41, name: "Example")
        let queued = process(pid: 42, name: "Example")
        let fixture = await makeFixture(processes: [shown, queued])
        defer { fixture.stores.cleanup() }
        let store = fixture.stores.autoStopRules
        let stopped = StopRecorder()
        store.start(cadence: 60) { _, process in stopped.record(process.pid) }
        store.stop()
        XCTAssertTrue(store.add(AutoStopRule(processName: "Example", runtimeMinutes: 1, action: .prompt)))
        await store.evaluateNow()
        XCTAssertEqual(store.pendingPrompts.map(\.process.pid), [41, 42])
        let view = makePopover(fixture: fixture)
        let firstPresenter = try view.inspect().find(AutoStopPromptAlert.self)
        let firstID = try firstPresenter.id()
        let firstAlert = try firstPresenter.find(ViewType.Alert.self)
        XCTAssertNoThrow(try firstAlert.find(text: "Example (PID 41) has run for 3m, beyond the 1-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."))

        await fixture.inventory.setProcesses([queued])
        await store.evaluateNow()
        XCTAssertEqual(store.currentPrompt?.process.pid, 42)
        let nextPresenter = try view.inspect().find(AutoStopPromptAlert.self)
        XCTAssertNotEqual(try nextPresenter.id(), firstID, "The next prompt must get a new SwiftUI presenter identity")
        XCTAssertEqual(try firstPresenter.actualView().prompt?.process.pid, 41)
        try firstAlert.find(button: "Stop Now").tap()
        try firstAlert.dismiss()
        await store.waitForPromptActions()
        XCTAssertTrue(stopped.pids.isEmpty, "The retired alert cannot authorize its replacement")
        XCTAssertEqual(store.currentPrompt?.process.pid, 42)

        let nextAlert = try nextPresenter.find(ViewType.Alert.self)
        XCTAssertNoThrow(try nextAlert.find(text: "Example (PID 42) has run for 3m, beyond the 1-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."))
        try nextAlert.find(button: "Stop Now").tap()
        try nextAlert.dismiss()
        await store.waitForPromptActions()
        XCTAssertEqual(stopped.pids, [42])
    }

    // MARK: - Helpers

    /// Lets the `Task { await autoStopRules.stopCurrentPrompt() }` enqueued by the button
    /// action run on the MainActor, mirroring SwiftUI's deferred execution of that Task.

    private func process(pid: Int32, name: String) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: getuid(),
            cpu: 1,
            memoryMB: 128,
            command: "/Applications/\(name).app/Contents/MacOS/\(name)",
            elapsedTime: "03:00",
            startTime: "start-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    private func makeFixture(processes: [AppProcess]) async -> PromptFixture {
        let inventory = PromptInventory(processes: processes)
        let signaler = PromptSignaler()
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: signaler,
            lifecycle: PromptLifecycle(),
            settleAfterProcessChange: {}
        )
        manager.enableNotifications = false

        let stores = makeStores(inventory: inventory)
        await manager.loadProcessList(showMessage: false)

        return PromptFixture(manager: manager, signaler: signaler, stores: stores, inventory: inventory)
    }

    private func makePopover(fixture: PromptFixture) -> TaskScopePopoverView {
        TaskScopePopoverView(
            processManager: fixture.manager,
            loginItemManager: LoginItemManager(service: PromptLoginItemService()),
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            savedSelections: fixture.stores.savedSelections,
            autoStopRules: fixture.stores.autoStopRules,
            history: fixture.stores.history,
            presentationStyle: .menuBarCompact,
            openFullWindow: nil,
            confirmationState: ProcessConfirmationState(),
            activityMonitor: PromptActivityMonitor()
        )
    }

    private func makeStores(inventory: PromptInventory) -> PromptStores {
        let suiteName = "TaskScope.AutoStopPromptAlertTests.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PromptStores(
            suiteName: suiteName,
            defaults: defaults,
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "selections"),
            autoStopRules: AutoStopRulesStore(
                userDefaults: defaults,
                key: "rules",
                eventsKey: "events",
                inventory: inventory
            ),
            history: ProcessHistory(inventory: inventory)
        )
    }
}

@MainActor
private final class StopRecorder {
    private(set) var pids: [Int32] = []

    func record(_ pid: Int32) -> ProcessActionResult {
        pids.append(pid)
        return .stopped
    }
}

private actor PromptInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    init(processes: [AppProcess]) { self.processes = processes }

    func setProcesses(_ processes: [AppProcess]) { self.processes = processes }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class PromptSignaler: ProcessSignaling {
    private(set) var sent: [Int32] = []

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        sent.append(pid)
        return true
    }

    func isAlive(_ pid: Int32) -> Bool { false }
}

private struct PromptLifecycle: ProcessLifecycleServicing {
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func isProcessNamedRunning(_ name: String) async -> Bool { false }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForProcessNamed(_ name: String, timeoutSeconds: TimeInterval) async -> Bool { true }
    func openAppBundle(at path: String) async -> AppBundleOpenResult { .opened }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { await unloadUserLaunchAgents(for: preset) }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { await waitForProcessNamed(preset.mainProcessName, timeoutSeconds: timeoutSeconds) }
}

private struct PromptLoginItemService: LoginItemServicing {
    var state: LoginItemState = .notRegistered
    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}

@MainActor
private struct PromptActivityMonitor: ActivityMonitorCoordinating {
    func openAndSelect(pid: Int32) async -> ActivityMonitorHandoffOutcome {
        .missingProcess
    }
}

@MainActor
private struct PromptFixture {
    var manager: ProcessManager
    var signaler: PromptSignaler
    var stores: PromptStores
    var inventory: PromptInventory
}

@MainActor
private struct PromptStores {
    var suiteName: String
    var defaults: UserDefaults
    var settings: SettingsStore
    var watchedApps: WatchedAppsStore
    var savedSelections: SavedSelectionsStore
    var autoStopRules: AutoStopRulesStore
    var history: ProcessHistory

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
