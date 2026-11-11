import AppKit
import ApplicationServices
import SwiftUI

/// Remembers the application that was frontmost most recently, other than
/// TaskScope, so suppressing an automatic window hands activation back to the
/// app the user is in now rather than whichever app was frontmost at launch.
@MainActor
final class PreviousApplicationTracker {
    private let ownProcessID: pid_t
    private var observer: NSObjectProtocol?
    private(set) var application: NSRunningApplication?

    init(ownProcessID: pid_t, initial: NSRunningApplication?) {
        self.ownProcessID = ownProcessID
        record(initial)
    }

    func record(_ candidate: NSRunningApplication?) {
        guard let candidate, candidate.processIdentifier != ownProcessID else { return }
        application = candidate
    }

    func startObserving(_ center: NotificationCenter) {
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    /// Does nothing unless TaskScope holds activation: handing it away from a
    /// background TaskScope would pull an unrelated app in front of the user.
    func restore(isActive: Bool, deactivate: () -> Void, activate: (NSRunningApplication) -> Void) {
        guard isActive else { return }
        deactivate()
        if let application, !application.isTerminated, application.processIdentifier != ownProcessID {
            activate(application)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var launchContext: TaskScopeLaunchContext
    @Published private(set) var windowPresentationAllowed: Bool
    /// Work that must happen before the process exits (restoring Activity
    /// Monitor state, flushing debounced settings writes).
    var willTerminate: (() -> Void)?
    /// Shows the main window. Installed once the runtime is bootstrapped.
    var showMainWindow: (() -> Void)?
    private let launchSession: TaskScopeLaunchSession
    private let terminationHandler: TaskScopeTerminationHandler
    private let runtime: Runtime

    /// AppKit effects are injected so delegate lifecycle callbacks can be tested
    /// without registering system handlers or presenting application windows.
    @MainActor
    struct Runtime {
        var launchSignal: () -> TaskScopeLaunchSignal
        var isActive: () -> Bool
        var setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
        var registerURLHandler: (@escaping () -> Void) -> Void
        var configureAccessibility: () -> Void
        var registerHotkey: () -> Void
        var hideAutomaticWindows: () -> Void
        var restorePreviousApplication: () -> Void
        var presentMainWindow: () -> Void
        var waitForInteractiveLaunch: () async -> Void
        /// Stops the shell commands still running when TaskScope quits, so a
        /// launchctl or an administrator prompt does not outlive the app.
        var stopRunningCommands: () -> Void = {}

        static var system: Runtime {
            let previous = PreviousApplicationTracker(
                ownProcessID: ProcessInfo.processInfo.processIdentifier,
                initial: NSWorkspace.shared.frontmostApplication
            )
            previous.startObserving(NSWorkspace.shared.notificationCenter)
            return Runtime(
                launchSignal: {
                    let event = NSAppleEventManager.shared().currentAppleEvent
                    let loginDescriptor = event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
                    return TaskScopeLaunchSignal(
                        arguments: ProcessInfo.processInfo.arguments,
                        launchedAsLoginItem: loginDescriptor?.booleanValue ?? false,
                        receivedOpenURL: event?.eventClass == AEEventClass(kInternetEventClass)
                            && event?.eventID == AEEventID(kAEGetURL)
                    )
                },
                isActive: { NSApp.isActive },
                setActivationPolicy: { NSApp.setActivationPolicy($0) },
                registerURLHandler: { callback in URLSchemeHandler.shared.register { _ in callback() } },
                configureAccessibility: { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2) },
                registerHotkey: { HotkeyManager.shared.register() },
                hideAutomaticWindows: {
                    NSApp.windows.filter { automaticWindowTitles.contains($0.title) }.forEach { $0.orderOut(nil) }
                },
                restorePreviousApplication: {
                    previous.restore(isActive: NSApp.isActive, deactivate: { NSApp.deactivate() },
                                     activate: { $0.activate() })
                },
                presentMainWindow: {
                    DispatchQueue.main.async {
                        NSApp.windows.first { $0.title == "TaskScope" || $0.title == "TaskScope Processes" }?
                            .makeKeyAndOrderFront(nil)
                    }
                },
                waitForInteractiveLaunch: { try? await Task.sleep(nanoseconds: 500_000_000) },
                stopRunningCommands: { ShellCommandRunner.liveExecutions.shutDown() }
            )
        }
    }
    private var hasInteractiveSignal = false
    private(set) var launchPhase = TaskScopeLaunchPhase.starting
    private var interactiveLaunchTask: Task<Void, Never>?
    private var automaticWindowSuppressionTask: Task<Void, Never>?
    private var pendingShortcutParameterRefresh: (@MainActor () -> Void)?

    override convenience init() {
        self.init(launchSession: .shared, commandBus: .shared,
                  terminationHandler: .system { NSApp.terminate(nil) }, runtime: .system)
    }

    init(launchSession: TaskScopeLaunchSession, commandBus: AppCommandBus,
         terminationHandler: TaskScopeTerminationHandler, runtime: Runtime) {
        self.launchSession = launchSession
        self.terminationHandler = terminationHandler
        self.runtime = runtime
        launchContext = .pending
        windowPresentationAllowed = false
        super.init()
        if launchSession.allowsRuntime {
            commandBus.onIntentExecution = { [weak self] in
                self?.prepareForIncomingAutomationCommand(source: .intent)
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard launchSession.continueLaunching() else { return }
        terminationHandler.start()
        resolveLaunchContext(finalizeInteractiveLaunch: false)
        runtime.registerURLHandler { [weak self] in
            self?.prepareForIncomingAutomationCommand(source: .url)
        }
        if launchContext.suppressesAutomaticWindowPresentation {
            runtime.setActivationPolicy(.accessory)
        } else {
            runtime.setActivationPolicy(.regular)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchSession.continueLaunching() else { return }
        resolveLaunchContext(finalizeInteractiveLaunch: true)
        // Bound every Accessibility request this process makes (GlobalProtect
        // disconnect, Activity Monitor handoff). The default is about six
        // seconds per call, which an unresponsive app multiplies per element.
        runtime.configureAccessibility()

        if launchSession.allowsRuntime {
            runtime.registerHotkey()
        }
        if launchContext.suppressesAutomaticWindowPresentation {
            finalizeBackgroundLaunch()
            launchPhase = .running
            publishPendingShortcutParametersIfReady()
        } else {
            scheduleInteractiveLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminate?()
        // Bounded to about a second: TERM, then KILL, to each command's group.
        runtime.stopRunningCommands()
        launchSession.cleanUp()
        terminationHandler.stop()
        interactiveLaunchTask?.cancel()
        automaticWindowSuppressionTask?.cancel()
        pendingShortcutParameterRefresh = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// Opening the running app again (Finder, Dock, Spotlight, Launchpad) is
    /// an explicit request for its window, including after a quiet login-item,
    /// automation, or URL launch whose windows were suppressed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchSession.allowsRuntime else { return false }
        hasInteractiveSignal = true
        if let showMainWindow {
            showMainWindow()
            return false
        }
        permitWindowPresentation()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if launchContext == .interactive || launchContext == .pending {
            hasInteractiveSignal = true
        }
        guard launchSession.allowsRuntime,
              launchPhase == .running,
              launchContext == .interactive,
              !windowPresentationAllowed else {
            return
        }
        promoteInteractiveLaunch()
    }

    private func prepareForIncomingAutomationCommand(source: TaskScopeAutomationSource) {
        guard launchSession.allowsRuntime,
              !windowPresentationAllowed else { return }
        let resolved = TaskScopeLaunchContext.receivingAutomation(
            current: launchContext,
            phase: launchPhase,
            source: source,
            hasInteractiveSignal: hasInteractiveSignal
        )
        guard resolved == .urlAutomation, resolved != launchContext else { return }

        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = nil
        launchContext = resolved
        finalizeBackgroundLaunch()
        launchPhase = .running
        publishPendingShortcutParametersIfReady()
    }

    /// linkd can answer our own parameter refresh by querying entities in this
    /// process. Defer that refresh until its intent signal cannot turn an
    /// undecided interactive launch into a background launch. Coalesce edits
    /// during launch; the callback reads the latest catalog when it executes.
    func requestShortcutParameterRefresh(
        update: @escaping @MainActor () -> Void = { TaskScopeShortcuts.updateAppShortcutParameters() }
    ) {
        guard launchSession.allowsRuntime else { return }
        pendingShortcutParameterRefresh = update
        publishPendingShortcutParametersIfReady()
    }

    private func publishPendingShortcutParametersIfReady() {
        guard launchPhase == .running,
              windowPresentationAllowed || hasInteractiveSignal || launchContext.suppressesAutomaticWindowPresentation,
              let update = pendingShortcutParameterRefresh else { return }
        pendingShortcutParameterRefresh = nil
        TaskScopeShortcuts.refreshParameters(for: launchContext, update: update)
    }

    private func scheduleInteractiveLaunch() {
        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = Task { @MainActor [weak self] in
            // Launch Services delivers a cold-open URL after did-finish. Keep
            // restored/default windows suppressed until that launch event has
            // had a chance to reach the handler registered during will-finish.
            await self?.runtime.waitForInteractiveLaunch()
            guard let self, !Task.isCancelled, self.launchPhase == .starting else {
                return
            }

            self.launchPhase = .running
            self.interactiveLaunchTask = nil
            switch TaskScopeLaunchPresentation.resolve(context: self.launchContext, isActive: self.runtime.isActive()) {
            case .background:
                self.finalizeBackgroundLaunch()
            case .presentNow:
                self.promoteInteractiveLaunch()
            case .presentOnNextActivation:
                self.finalizeInactiveInteractiveLaunch()
            }
            self.publishPendingShortcutParametersIfReady()
        }
    }

    private func resolveLaunchContext(finalizeInteractiveLaunch: Bool) {
        launchContext = TaskScopeLaunchContext.resolve(
            current: launchContext,
            signal: runtime.launchSignal(),
            finalizeInteractiveLaunch: finalizeInteractiveLaunch
        )
    }

    @objc
    private func windowDidBecomeVisible(_ notification: Notification) {
        guard !windowPresentationAllowed,
              let window = notification.object as? NSWindow,
              Self.automaticWindowTitles.contains(window.title) else {
            return
        }
        window.orderOut(nil)
    }

    private func hideAutomaticWindows() {
        runtime.hideAutomaticWindows()
    }

    private static let automaticWindowTitles: Set<String> = [
        "TaskScope", "TaskScope Processes", "Onboarding", "About TaskScope"
    ]

    private func finalizeBackgroundLaunch() {
        runtime.setActivationPolicy(.accessory)
        suppressAutomaticWindowPresentation()
        startAutomaticWindowSuppression()
    }

    /// An interactive launch that is not active when the launch grace period
    /// ends keeps its interactive intent: the app stays a regular (Dock) app
    /// and its windows are presented on the next activation
    /// (`applicationDidBecomeActive` -> `promoteInteractiveLaunch`). Demoting
    /// to an accessory here hid a Dock-launched app whose activation was
    /// merely slow.
    private func finalizeInactiveInteractiveLaunch() {
        // will-finish ran while the context was still pending and made the app
        // an accessory; an interactive launch keeps its Dock presence.
        runtime.setActivationPolicy(.regular)
        hideAutomaticWindows()
        startAutomaticWindowSuppression()
    }

    private func startAutomaticWindowSuppression() {
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = Task { @MainActor [weak self] in
            // SwiftUI/AppKit restoration can order a default window after the
            // launch callback. Sweep briefly until an explicit presentation
            // request wins, so quiet launch contexts stay visually quiet.
            for _ in 0..<50 {
                guard let self,
                      !Task.isCancelled,
                      !self.windowPresentationAllowed else {
                    return
                }
                self.hideAutomaticWindows()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.automaticWindowSuppressionTask = nil
        }
    }

    private func promoteInteractiveLaunch() {
        hasInteractiveSignal = true
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = nil
        launchContext = .interactive
        windowPresentationAllowed = true
        runtime.setActivationPolicy(.regular)
        runtime.presentMainWindow()
        publishPendingShortcutParametersIfReady()
    }

    func suppressAutomaticWindowPresentation() {
        guard launchContext.suppressesAutomaticWindowPresentation,
              !windowPresentationAllowed else {
            return
        }
        hideAutomaticWindows()
        runtime.restorePreviousApplication()
    }

    func permitWindowPresentation() {
        guard launchSession.allowsRuntime else { return }
        hasInteractiveSignal = true
        interactiveLaunchTask?.cancel()
        interactiveLaunchTask = nil
        automaticWindowSuppressionTask?.cancel()
        automaticWindowSuppressionTask = nil
        launchPhase = .running
        windowPresentationAllowed = true
        runtime.setActivationPolicy(.regular)
        publishPendingShortcutParametersIfReady()
    }
}

@main
struct TaskScopeApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager: ProcessManager
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings: SettingsStore
    @StateObject private var watchedApps: WatchedAppsStore
    @StateObject private var savedSelections: SavedSelectionsStore
    @StateObject private var autoStopRules: AutoStopRulesStore
    @StateObject private var processHistory: ProcessHistory

    private let launchSession: TaskScopeLaunchSession
    @State private var showOnboarding: Bool
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false
    @State private var notificationEnablement = NotificationEnablementCoordinator()
    /// One coordinator for the app's lifetime. Constructing it per view init
    /// created a new Accessibility runtime on every body evaluation, whose
    /// pending restoration then ran against a deallocated runtime.
    @State private var activityMonitor: ActivityMonitorCoordinator

    init() {
        let launchSession = TaskScopeLaunchSession.shared
        self.launchSession = launchSession
        let systemInventory = SystemProcessInventory()
        let sharedInventory = CoalescingProcessInventory(upstream: systemInventory)
        let stores = TaskScopeLaunchStores(session: launchSession, inventory: sharedInventory)
        let settings = stores.settings
        let processHistory = ProcessHistory(inventory: sharedInventory)
        let processManager = ProcessManager(
            processInventory: sharedInventory,
            verificationInventory: systemInventory,
            processHistory: processHistory
        )
        let watchedApps = stores.watchedApps
        let autoStopRules = stores.autoStopRules
        let coordinator = AppCommandCoordinator(
            processManager: processManager,
            presets: { watchedApps.presets },
            allowsCommands: {
                launchSession.allowsRuntime
            }
        )

        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.isKeepOffIntentWritableProvider = { !settings.isReadOnlyAfterCorruption }
        processManager.globalProtectServiceObservationProvider = {
            await GlobalProtectServiceObservation.read()
        }
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
        launchSession.installCommandHandler(on: .shared) { command in
            await coordinator.perform(command)
        }

        _processManager = StateObject(wrappedValue: processManager)
        _settings = StateObject(wrappedValue: settings)
        _savedSelections = StateObject(wrappedValue: stores.savedSelections)
        _showOnboarding = State(initialValue: stores.showOnboarding)
        _watchedApps = StateObject(wrappedValue: watchedApps)
        _autoStopRules = StateObject(wrappedValue: autoStopRules)
        _processHistory = StateObject(wrappedValue: processHistory)
        _activityMonitor = State(initialValue: ActivityMonitorCoordinator())
    }

    var body: some Scene {
        WindowGroup("TaskScope", id: "processes") {
            Group {
                if appDelegate.windowPresentationAllowed {
                    TaskScopePopoverView(
                        processManager: processManager,
                        loginItemManager: loginItemManager,
                        settings: settings,
                        watchedApps: watchedApps,
                        savedSelections: savedSelections,
                        autoStopRules: autoStopRules,
                        history: processHistory,
                        presentationStyle: .expandedWindow,
                        openFullWindow: { showTaskScopeWindow() },
                        activityMonitor: activityMonitor
                    )
                    .frame(minWidth: 760, minHeight: 560)
                    .environmentObject(settings)
                    .environmentObject(watchedApps)
                    .task {
                        await bootstrapRuntimeIfNeeded()
                        if appDelegate.windowPresentationAllowed {
                            openOnboardingIfNeeded()
                        }
                    }
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .onAppear {
                            appDelegate.suppressAutomaticWindowPresentation()
                        }
                }
            }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About TaskScope") {
                    showAboutWindow()
                }
            }
        }

        MenuBarExtra {
            TaskScopePopoverView(
                processManager: processManager,
                loginItemManager: loginItemManager,
                settings: settings,
                watchedApps: watchedApps,
                savedSelections: savedSelections,
                autoStopRules: autoStopRules,
                history: processHistory,
                presentationStyle: .menuBarCompact,
                openFullWindow: {
                    showTaskScopeWindow()
                },
                activityMonitor: activityMonitor,
                menuBarConfirmation: AppModalMenuBarConfirmation()
            )
            .frame(width: 480, height: 600)
            .environmentObject(settings)
            .environmentObject(watchedApps)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                settings: settings,
                watchedApps: watchedApps,
                autoStopRules: autoStopRules,
                processManager: processManager
            )
        }

        WindowGroup("About TaskScope", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Onboarding", id: "onboarding") {
            OnboardingView(onComplete: {
                completeOnboarding()
            })
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        Group {
            // MenuBarExtra may size its native status item from rendered image
            // content, including a hidden badge. Keep this image and identity
            // constant; the popover already displays the live preset status.
            Label("TaskScope", systemImage: "waveform.path.ecg")
                .labelStyle(.iconOnly)
        }
        .task {
            await bootstrapRuntimeIfNeeded()
            if appDelegate.windowPresentationAllowed {
                openOnboardingIfNeeded()
            }
        }
        // Onboarding is gated on window presentation being allowed, not on the
        // launch context, so a background launch that is later activated by the
        // user is still offered onboarding on that first interactive activation.
        .onChange(of: appDelegate.windowPresentationAllowed) { _, allowed in
            if allowed {
                openOnboardingIfNeeded()
            }
        }
        .onChange(of: settings.refreshIntervalSeconds) { _, _ in
            configurePolling()
            processHistory.updateConsumerCadence(settings.refreshIntervalSeconds)
        }
        .onChange(of: settings.keepGlobalProtectOff) { _, _ in
            configurePolling()
        }
        .onChange(of: settings.autoRefreshProcessList) { _, _ in
            configurePolling()
        }
        .onChange(of: settings.sortKeyRaw) { _, _ in
            processManager.sortKey = settings.sortKey
        }
        .onChange(of: settings.processListLimit) { _, _ in
            processManager.applyCurrentDisplayLimit()
        }
        .onChange(of: settings.enableNotifications) { _, newValue in
            guard launchSession.allowsRuntime else { return }
            let token = notificationEnablement.beginConfiguration(
                enabled: newValue,
                setDeliveryEnabled: { processManager.enableNotifications = $0 }
            )
            configurePolling()
            guard newValue else { return }

            Task {
                await NotificationService.shared.requestAuthorization()
                notificationEnablement.completeEnabledConfiguration(
                    token: token,
                    currentRunningNames: { eligibleNotificationNames() },
                    primeBaseline: {
                        NotificationService.shared.prime(initialRunningNames: $0)
                    },
                    setDeliveryEnabled: { processManager.enableNotifications = $0 }
                )
            }
        }
        .onChange(of: watchedApps.presets) { _, _ in
            guard launchSession.allowsRuntime else { return }
            appDelegate.requestShortcutParameterRefresh()
            // The refresh re-baselines on its own when the watched-name set changed,
            // so a newly watched app that was already running is not announced as
            // having just started.
            Task { await processManager.refreshWatchedStatus(showMessage: false) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            guard launchSession.allowsRuntime else { return }
            Task {
                await TaskScopeExternalStateRefresh.perform(
                    refreshLoginItem: { loginItemManager.refresh() },
                    refreshNotificationAuthorization: {
                        await NotificationService.shared.refreshAuthorizationStatus()
                    }
                )
            }
        }
    }

    private func bootstrapRuntimeIfNeeded() async {
        guard !didBootstrapRuntime,
              launchSession.allowsRuntime,
              appDelegate.launchContext.performsRuntimeBootstrap else { return }
        didBootstrapRuntime = true

        loginItemManager.refresh()
        processManager.watchedAppsProvider = { watchedApps.presets }
        processManager.processListLimitProvider = { settings.processListLimit }
        processManager.sortKey = settings.sortKey
        processManager.enableNotifications = settings.enableNotifications
        HotkeyManager.shared.onShow = {
            showTaskScopeWindow()
        }
        appDelegate.showMainWindow = {
            showTaskScopeWindow()
        }
        appDelegate.willTerminate = {
            activityMonitor.restoreActivityMonitorState()
            settings.flushPendingWrites()
        }
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
            await NotificationService.shared.requestAuthorization()
            let running = eligibleNotificationNames()
            NotificationService.shared.prime(initialRunningNames: running)
        }

        appDelegate.requestShortcutParameterRefresh()
    }

    private func configurePolling() {
        guard launchSession.allowsRuntime else { return }
        processManager.setPolling(
            interval: settings.refreshIntervalSeconds,
            includeProcessList: settings.autoRefreshProcessList,
            backgroundActivity: settings.enableNotifications || settings.keepGlobalProtectOff
        )
    }

    private func eligibleNotificationNames() -> Set<String> {
        let enabledPresetIDs = Set(watchedApps.presets.filter(\.notificationsEnabled).map(\.id))
        return ProcessManager.notificationNames(for: processManager.snapshots.filter {
            enabledPresetIDs.contains($0.preset.id)
        })
    }

    private func openOnboardingIfNeeded() {
        guard showOnboarding, !didRequestOnboarding else { return }
        didRequestOnboarding = true
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func completeOnboarding() {
        launchSession.userDefaults.set(true, forKey: "TaskScope.onboarded.v1")
        showOnboarding = false
    }

    private func showTaskScopeWindow() {
        appDelegate.permitWindowPresentation()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)

        if let window = NSApp.windows.first(where: isTaskScopeMainWindow) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "processes")
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAboutWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isTaskScopeMainWindow(_ window: NSWindow) -> Bool {
        window.title == "TaskScope" || window.title == "TaskScope Processes"
    }
}
