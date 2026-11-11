import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import TaskScope

/// Shared fixtures for the batch 10 (main window and menu-bar UI) tests. Every
/// fixture uses fakes and a uniquely named UserDefaults suite.
@MainActor
enum Batch10 {
    static func process(
        _ pid: Int32,
        parent: Int32 = 1,
        name: String = "Example",
        cpu: Double = 1,
        memoryMB: Double = 128,
        startTime: String = "one"
    ) -> AppProcess {
        let path = "/Applications/\(name).app/Contents/MacOS/\(name)"
        return AppProcess(
            pid: pid, parentPID: parent, uid: getuid(), cpu: cpu, memoryMB: memoryMB,
            command: path, executablePath: path, elapsedTime: "03:00", startTime: startTime,
            netInKB: 123456789, netOutKB: 123456789, diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    static func stores(inventory: any ProcessInventoryProviding) -> UIStores {
        let suite = "TaskScope.Batch10.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UIStores(
            suiteName: suite,
            defaults: defaults,
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "selections"),
            autoStopRules: AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events", inventory: inventory),
            history: ProcessHistory(inventory: inventory)
        )
    }

    static func fixture(
        processes: [AppProcess],
        inventory: (any ProcessInventoryProviding)? = nil
    ) async -> UIFixture {
        let inventory = inventory ?? UIInventory(processes: processes)
        let signaler = UIRecordingSignaler()
        let lifecycle = UILifecycle()
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: signaler, lifecycle: lifecycle, settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        let stores = stores(inventory: inventory)
        manager.dependencies.watchedPresets = { stores.watchedApps.presets }
        await manager.loadProcessList(showMessage: false)
        return UIFixture(manager: manager, signaler: signaler, stores: stores, lifecycle: lifecycle)
    }

    static func popover(
        _ fixture: UIFixture,
        manager: ProcessManager? = nil,
        state: ProcessConfirmationState? = nil,
        listState: ProcessListInteractionState? = nil,
        reportState: ProcessReportPresentationState? = nil,
        confirmer: (any MenuBarConfirming)? = nil,
        style: TaskScopePresentationStyle = .expandedWindow,
        windowState: ControlActiveState? = nil,
        mainWindowVisible: @escaping @MainActor () -> Bool = { false }
    ) -> TaskScopePopoverView {
        TaskScopePopoverView(
            processManager: manager ?? fixture.manager,
            loginItemManager: LoginItemManager(service: UILoginItemService()),
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            savedSelections: fixture.stores.savedSelections,
            autoStopRules: fixture.stores.autoStopRules,
            history: fixture.stores.history,
            presentationStyle: confirmer == nil ? style : .menuBarCompact,
            confirmationState: state,
            listState: listState,
            reportState: reportState,
            reportWindowState: windowState,
            mainWindowVisible: mainWindowVisible,
            activityMonitor: UIActivityMonitor(),
            menuBarConfirmation: confirmer
        )
    }

    /// Waits for `condition` itself, bounded by a generous timeout, instead of a
    /// fixed number of yields that a slow machine can outrun.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// `waitUntil` for a condition that has to be read across an actor hop.
    @discardableResult
    static func waitUntilAsync(timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    /// The text a view actually draws, read back from a rendered PDF. Unlike
    /// ViewInspector's string(), this applies the locale formatting SwiftUI
    /// uses for interpolated numbers, so digit grouping is visible.
    static func renderedText<Content: View>(_ view: Content, locale: Locale = Locale(identifier: "en_US")) -> String {
        let renderer = ImageRenderer(content: view.environment(\.locale, locale).frame(width: 1_000))
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return PDFDocument(data: data as Data)?.string ?? ""
    }
}

/// Lets a test hold a fake call open until it releases it, and wait until the
/// call has started, without guessing with sleeps.
actor Batch10Gate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var holders: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        entered = true
        let waiters = enterWaiters
        enterWaiters = []
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { holders.append($0) }
    }

    func hasEntered() -> Bool { entered }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }

    func release() {
        released = true
        let held = holders
        holders = []
        held.forEach { $0.resume() }
    }
}

/// A lifecycle fake whose app launch is held by a gate, so a preset Open keeps
/// the manager's operation gate (a mutation) until the test releases it.
struct Batch10HeldOpenLifecycle: ProcessLifecycleServicing {
    let gate: Batch10Gate
    func appBundleExists(at path: String) -> Bool { true }
    func settleAfterProcessChange() async {}
    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome { .signalled }
    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool { true }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult { .notNeeded }
    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult { .notNeeded }
    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult { .notNeeded }
    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        await gate.pass()
        return .opened
    }
}

/// An inventory whose next read can be held open, so a read (not a mutation)
/// is in flight while the test inspects the UI.
actor Batch10HeldInventory: ProcessInventoryProviding {
    let gate = Batch10Gate()
    private var processes: [AppProcess]
    private var holdsNextLoad = false

    init(processes: [AppProcess]) { self.processes = processes }

    func holdNextLoad() { holdsNextLoad = true }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        if holdsNextLoad {
            holdsNextLoad = false
            await gate.pass()
        }
        return .success(processes)
    }
}

/// Records the PIDs an Auto Stop action handler was asked to stop.
final class Batch10StopRecorder {
    private(set) var pids: [Int32] = []

    func record(_ pid: Int32) -> ProcessActionResult {
        pids.append(pid)
        return .stopped
    }
}

/// A menu-bar confirmer that keeps each request open until the test answers.
@MainActor
final class Batch10HeldConfirmation: MenuBarConfirming {
    private(set) var requests: [MenuBarConfirmationRequest] = []
    private var response: CheckedContinuation<Bool, Never>?
    private var presented: [CheckedContinuation<Void, Never>] = []

    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool {
        requests.append(request)
        let waiters = presented
        presented = []
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { response = $0 }
    }

    /// Waits until `count` requests have been presented.
    func waitUntilPresented(count: Int = 1) async {
        while requests.count < count {
            await withCheckedContinuation { presented.append($0) }
        }
    }

    func answer(_ value: Bool) {
        response?.resume(returning: value)
        response = nil
    }
}
