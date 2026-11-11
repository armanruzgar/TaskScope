import Combine
import Foundation

/// Connects the stores to ProcessManager and runs the app's background work:
/// polling, the Auto Stop engine, launch-time Keep Off enforcement and the
/// reactions to settings changes. TaskScopeApp builds it once; AppDelegate
/// starts it as soon as the launch context is resolved, so none of this depends
/// on SwiftUI creating the menu-bar label or a window.
@MainActor
final class TaskScopeRuntime {
    /// The runtime TaskScopeApp built. SwiftUI creates the AppDelegate before
    /// TaskScopeApp.init runs, so the delegate looks the runtime up here.
    static weak var current: TaskScopeRuntime?

    /// System effects, injected so the composition can be tested with fakes.
    struct Effects {
        var requestNotificationAuthorization: () async -> Void = {}
        var primeNotificationBaseline: (Set<String>) -> Void = { _ in }
    }

    let processManager: ProcessManager
    let settings: SettingsStore
    let watchedApps: WatchedAppsStore
    let autoStopRules: AutoStopRulesStore
    private let session: TaskScopeLaunchSession
    private let history: ProcessHistory
    private let effects: Effects
    private let notificationEnablement = NotificationEnablementCoordinator()
    private var subscriptions: Set<AnyCancellable> = []
    /// Asks AppDelegate for the App Shortcuts parameter refresh; the delegate
    /// defers it until the launch can no longer be reclassified.
    private var requestShortcutParameterRefresh: @MainActor () -> Void = {}
    private(set) var didStart = false

    init(
        session: TaskScopeLaunchSession,
        stores: TaskScopeLaunchStores,
        processManager: ProcessManager,
        history: ProcessHistory,
        bus: AppCommandBus,
        effects: Effects = Effects()
    ) {
        self.session = session
        self.processManager = processManager
        self.history = history
        self.effects = effects
        settings = stores.settings
        watchedApps = stores.watchedApps
        autoStopRules = stores.autoStopRules

        let settings = stores.settings
        let watchedApps = stores.watchedApps
        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.isKeepOffIntentWritableProvider = { !settings.isReadOnlyAfterCorruption }
        processManager.keptOffPresetsProvider = {
            settings.keepGlobalProtectOff
                ? watchedApps.presets.filter { $0.id == WatchedAppPreset.globalProtectID }
                : []
        }
        processManager.isPresetKeptOffProvider = { preset in
            preset.id == WatchedAppPreset.globalProtectID && settings.keepGlobalProtectOff
        }
        processManager.setPresetKeptOffHandler = { preset, keptOff in
            guard preset.id == WatchedAppPreset.globalProtectID else { return }
            settings.keepGlobalProtectOff = keptOff
        }
        let coordinator = AppCommandCoordinator(
            processManager: processManager,
            presets: { watchedApps.presets },
            allowsCommands: { session.allowsRuntime }
        )
        session.installCommandHandler(on: bus) { command in
            await coordinator.perform(command)
        }
    }

    /// Starts the background work once. Startup verification and a duplicate
    /// launch never start it.
    func start(
        context: TaskScopeLaunchContext,
        requestShortcutParameterRefresh: @escaping @MainActor () -> Void
    ) async {
        guard !didStart, session.allowsRuntime, context.performsRuntimeBootstrap else { return }
        didStart = true
        self.requestShortcutParameterRefresh = requestShortcutParameterRefresh

        processManager.processListLimitProvider = { [settings] in settings.processListLimit }
        processManager.sortKey = settings.sortKey
        processManager.enableNotifications = settings.enableNotifications
        observeSettings()
        configurePolling()
        autoStopRules.start(
            cadence: 10,
            perform: AutoStopActionHandlerFactory.make(
                processManager: processManager,
                rules: autoStopRules
            )
        )
        await processManager.refreshWatchedStatus(showMessage: false)
        await processManager.enforceKeptOffPresets(force: true)

        if settings.enableNotifications {
            await effects.requestNotificationAuthorization()
            effects.primeNotificationBaseline(eligibleNotificationNames())
        }

        requestShortcutParameterRefresh()
    }

    /// Stops starting new work and saves pending settings. Quitting calls this
    /// first, before any in-flight action is given its bounded time to finish.
    func stop() {
        subscriptions.removeAll()
        processManager.stopPolling()
        autoStopRules.stop()
        settings.flushPendingWrites()
    }

    private func configurePolling() {
        processManager.setPolling(
            interval: settings.refreshIntervalSeconds,
            includeProcessList: settings.autoRefreshProcessList,
            backgroundActivity: settings.enableNotifications || settings.keepGlobalProtectOff
        )
    }

    /// The same reactions the menu-bar label's `onChange` handlers had. A
    /// `@Published` publisher fires before the property is stored, so each
    /// reaction runs on the next main-queue turn, after the store has the new
    /// (normalized) value.
    private func observeSettings() {
        react(to: settings.$refreshIntervalSeconds) { runtime in
            runtime.configurePolling()
            runtime.history.updateConsumerCadence(runtime.settings.refreshIntervalSeconds)
        }
        react(to: settings.$autoRefreshProcessList) { runtime in
            runtime.configurePolling()
        }
        react(to: settings.$keepGlobalProtectOff) { runtime in
            runtime.configurePolling()
        }
        react(to: settings.$sortKeyRaw) { runtime in
            runtime.processManager.sortKey = runtime.settings.sortKey
        }
        react(to: settings.$processListLimit) { runtime in
            runtime.processManager.applyCurrentDisplayLimit()
        }
        react(to: settings.$enableNotifications) { runtime in
            runtime.notificationSettingChanged(runtime.settings.enableNotifications)
        }
        react(to: watchedApps.$presets) { runtime in
            runtime.requestShortcutParameterRefresh()
            // The refresh re-baselines on its own when the watched-name set changed,
            // so a newly watched app that was already running is not announced as
            // having just started.
            Task { await runtime.processManager.refreshWatchedStatus(showMessage: false) }
        }
    }

    private func react<Value: Equatable>(
        to publisher: Published<Value>.Publisher,
        _ reaction: @escaping @MainActor (TaskScopeRuntime) -> Void
    ) {
        publisher
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    reaction(self)
                }
            }
            .store(in: &subscriptions)
    }

    private func notificationSettingChanged(_ enabled: Bool) {
        let token = notificationEnablement.beginConfiguration(
            enabled: enabled,
            setDeliveryEnabled: { [processManager] in processManager.enableNotifications = $0 }
        )
        configurePolling()
        guard enabled else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.effects.requestNotificationAuthorization()
            self.notificationEnablement.completeEnabledConfiguration(
                token: token,
                currentRunningNames: { self.eligibleNotificationNames() },
                primeBaseline: { self.effects.primeNotificationBaseline($0) },
                setDeliveryEnabled: { self.processManager.enableNotifications = $0 }
            )
        }
    }

    private func eligibleNotificationNames() -> Set<String> {
        let enabledPresetIDs = Set(watchedApps.presets.filter(\.notificationsEnabled).map(\.id))
        return ProcessManager.notificationNames(for: processManager.snapshots.filter {
            enabledPresetIDs.contains($0.preset.id)
        })
    }
}
