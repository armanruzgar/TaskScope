import AppKit
import ApplicationServices
import SwiftUI

/// The part of a running application that restoring activation reads, so the
/// tracker can be tested without a real NSRunningApplication (whose identity
/// depends on whether AppKit has started in the test process).
protocol PreviousApplication: Sendable {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
}

extension NSRunningApplication: PreviousApplication {}

/// Remembers the application that was frontmost most recently, other than
/// TaskScope, so suppressing an automatic window hands activation back to the
/// app the user is in now rather than whichever app was frontmost at launch.
@MainActor
final class PreviousApplicationTracker {
    private let ownProcessID: pid_t
    private var observer: NSObjectProtocol?
    private(set) var application: (any PreviousApplication)?

    init(ownProcessID: pid_t, initial: (any PreviousApplication)?) {
        self.ownProcessID = ownProcessID
        record(initial)
    }

    func record(_ candidate: (any PreviousApplication)?) {
        guard let candidate, candidate.processIdentifier != ownProcessID else { return }
        application = candidate
    }

    func startObserving(_ center: NotificationCenter) {
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? any PreviousApplication
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    /// Does nothing unless TaskScope holds activation: handing it away from a
    /// background TaskScope would pull an unrelated app in front of the user.
    func restore(isActive: Bool, deactivate: () -> Void, activate: (any PreviousApplication) -> Void) {
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
    /// Monitor state).
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
        /// Starts polling, the Auto Stop engine and launch-time Keep Off
        /// enforcement (TaskScopeRuntime) once the launch context is resolved.
        /// The closure asks this delegate for the App Shortcuts parameter
        /// refresh, which it defers until the launch context is settled.
        var startAppRuntime: @MainActor (
            TaskScopeLaunchContext, _ requestShortcutParameterRefresh: @escaping @MainActor () -> Void
        ) async -> Void = { _, _ in }
        /// Stops polling and the Auto Stop engine and saves pending settings.
        var stopAppRuntime: () -> Void = {}
        var isMutationActive: () -> Bool = { false }
        /// Stops the shell commands still running when TaskScope quits, so a
        /// launchctl or an administrator prompt does not outlive the app.
        var stopRunningCommands: () -> Void = {}
        var replyToTermination: (Bool) -> Void = { _ in }
        /// One step of the bounded wait for an in-flight action at quit.
        var waitForTerminationTick: @MainActor () async -> Void = { await Task.yield() }
        var terminationWaitTicks = 50
        /// How long a startup-verification instance may run.
        var waitForVerificationExpiry: @MainActor () async -> Void = {}
        var terminateApplication: () -> Void = {}
        /// Whether a TaskScope window other than the one closing is still open.
        var hasOtherOpenWindow: (NSWindow) -> Bool = { _ in false }

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
                                     activate: { ($0 as? NSRunningApplication)?.activate() })
                },
                presentMainWindow: {
                    DispatchQueue.main.async {
                        NSApp.windows.first { $0.title == TaskScopeScene.main.title }?
                            .makeKeyAndOrderFront(nil)
                    }
                },
                waitForInteractiveLaunch: { try? await Task.sleep(nanoseconds: 500_000_000) },
                startAppRuntime: { context, requestRefresh in
                    await TaskScopeRuntime.current?.start(
                        context: context, requestShortcutParameterRefresh: requestRefresh
                    )
                },
                stopAppRuntime: { TaskScopeRuntime.current?.stop() },
                isMutationActive: { TaskScopeRuntime.current?.processManager.isMutationActive ?? false },
                stopRunningCommands: { ShellCommandRunner.liveExecutions.shutDown() },
                replyToTermination: { NSApp.reply(toApplicationShouldTerminate: $0) },
                waitForTerminationTick: { try? await Task.sleep(nanoseconds: 100_000_000) },
                terminationWaitTicks: 50,
                waitForVerificationExpiry: { try? await Task.sleep(nanoseconds: 60_000_000_000) },
                terminateApplication: { NSApp.terminate(nil) },
                hasOtherOpenWindow: { closing in
                    NSApp.windows.contains {
                        $0 !== closing && ($0.isVisible || $0.isMiniaturized) && isTaskScopeWindow($0)
                    }
                }
            )
        }
    }
    private var hasInteractiveSignal = false
    private(set) var launchPhase = TaskScopeLaunchPhase.starting
    private var interactiveLaunchTask: Task<Void, Never>?
    private var automaticWindowSuppressionTask: Task<Void, Never>?
    private var runtimeStartTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var verificationExpiryTask: Task<Void, Never>?
    private var pendingShortcutParameterRefresh: (@MainActor () -> Void)?
    /// Set by a quiet launch (login item, automation, URL or intent): closing its
    /// last window returns TaskScope to the menu bar.
    private var returnsToMenuBarWhenWindowsClose = false

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
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
            // The runtime starts here, not from a SwiftUI view modifier, so
            // polling, Auto Stop rules and Keep Off enforcement do not depend on
            // the menu-bar label or a window being created.
            let context = launchContext
            runtimeStartTask = Task { @MainActor [weak self] in
                await self?.runtime.startAppRuntime(context) { [weak self] in
                    self?.requestShortcutParameterRefresh()
                }
            }
        }
        if launchContext == .startupVerification {
            scheduleVerificationExpiry()
        }
        if launchContext.suppressesAutomaticWindowPresentation {
            finalizeBackgroundLaunch()
            launchPhase = .running
            publishPendingShortcutParametersIfReady()
        } else {
            scheduleInteractiveLaunch()
        }
    }

    /// Quitting while a lifecycle action runs (Cmd-Q, Dock Quit, the footer
    /// button, SIGTERM, logout) stops polling and Auto Stop rules, gives the
    /// action a bounded time to finish, then stops any command still running
    /// (an unanswered administrator prompt, a stuck launchctl) with its process
    /// group, so nothing outlives TaskScope without its timeout. With no action
    /// in flight TaskScope quits at once (will-terminate stops any read still
    /// running), and a stuck action delays quit or logout by a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask != nil { return .terminateLater }
        guard runtime.isMutationActive() else { return .terminateNow }
        runtime.stopAppRuntime()
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var ticks = 0
            while self.runtime.isMutationActive(), ticks < self.runtime.terminationWaitTicks {
                await self.runtime.waitForTerminationTick()
                ticks += 1
            }
            self.runtime.stopRunningCommands()
            self.runtime.replyToTermination(true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stopAppRuntime()
        willTerminate?()
        // Bounded to about a second: TERM, then KILL, to each command's group.
        runtime.stopRunningCommands()
        launchSession.cleanUp()
        terminationHandler.stop()
        interactiveLaunchTask?.cancel()
        automaticWindowSuppressionTask?.cancel()
        runtimeStartTask?.cancel()
        verificationExpiryTask?.cancel()
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

    /// A startup-verification instance quits by itself after a bounded time
    /// (well above the packaging script's readiness check), so one left running
    /// cannot keep every later launch handing off to it.
    private func scheduleVerificationExpiry() {
        verificationExpiryTask?.cancel()
        verificationExpiryTask = Task { @MainActor [weak self] in
            await self?.runtime.waitForVerificationExpiry()
            guard let self, !Task.isCancelled else { return }
            self.runtime.terminateApplication()
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

    /// After a quiet launch, closing the last TaskScope window returns the app
    /// to the menu bar (no Dock icon or Cmd-Tab entry), as it started. Opening a
    /// window again makes it a regular app until that window closes.
    @objc
    private func windowWillClose(_ notification: Notification) {
        guard returnsToMenuBarWhenWindowsClose,
              windowPresentationAllowed,
              let window = notification.object as? NSWindow,
              Self.isTaskScopeWindow(window),
              !runtime.hasOtherOpenWindow(window) else {
            return
        }
        windowPresentationAllowed = false
        runtime.setActivationPolicy(.accessory)
        runtime.restorePreviousApplication()
    }

    private func hideAutomaticWindows() {
        runtime.hideAutomaticWindows()
    }

    static let automaticWindowTitles = Set(TaskScopeScene.allCases.map(\.title))

    /// The main, About and Onboarding windows. The menu-bar panel and the
    /// Settings window are not among them.
    static func isTaskScopeWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && automaticWindowTitles.contains(window.title)
    }

    private func finalizeBackgroundLaunch() {
        if launchSession.allowsRuntime {
            returnsToMenuBarWhenWindowsClose = true
        }
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

/// The status item's label. MenuBarExtra hosts it in an NSStatusBarButton that
/// does not take the Label's title for accessibility, so without an explicit
/// label VoiceOver announces the symbol's name ("Ecg Waveform Path").
struct TaskScopeStatusItemLabel: View {
    var body: some View {
        // MenuBarExtra may size its native status item from rendered image
        // content, including a hidden badge. Keep this image and identity
        // constant; the popover already displays the live preset status.
        Label("TaskScope", systemImage: "waveform.path.ecg")
            .labelStyle(.iconOnly)
            .accessibilityLabel("TaskScope")
    }
}

@main
struct TaskScopeApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.taskScopeCommands) private var focusedCommands
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var processManager: ProcessManager
    @StateObject private var loginItemManager = LoginItemManager()
    @StateObject private var settings: SettingsStore
    @StateObject private var watchedApps: WatchedAppsStore
    @StateObject private var savedSelections: SavedSelectionsStore
    @StateObject private var autoStopRules: AutoStopRulesStore
    @StateObject private var processHistory: ProcessHistory

    private let launchSession: TaskScopeLaunchSession
    private let appRuntime: TaskScopeRuntime
    @State private var showOnboarding: Bool
    @State private var didBootstrapRuntime = false
    @State private var didRequestOnboarding = false
    @State private var promptCoordinator: AutoStopPromptCoordinator?
    @State private var actionFeedback: ProcessActionFeedback?
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
        let processHistory = ProcessHistory(inventory: sharedInventory)
        let processManager = ProcessManager(
            processInventory: sharedInventory,
            verificationInventory: systemInventory,
            processHistory: processHistory
        )
        processManager.globalProtectServiceObservationProvider = {
            await GlobalProtectServiceObservation.read()
        }
        let appRuntime = TaskScopeRuntime(
            session: launchSession,
            stores: stores,
            processManager: processManager,
            history: processHistory,
            bus: .shared,
            effects: .init(
                requestNotificationAuthorization: {
                    await NotificationService.shared.requestAuthorization()
                },
                primeNotificationBaseline: {
                    NotificationService.shared.prime($0)
                }
            )
        )
        TaskScopeRuntime.current = appRuntime
        self.appRuntime = appRuntime

        _processManager = StateObject(wrappedValue: processManager)
        _settings = StateObject(wrappedValue: stores.settings)
        _savedSelections = StateObject(wrappedValue: stores.savedSelections)
        _showOnboarding = State(initialValue: stores.showOnboarding)
        _watchedApps = StateObject(wrappedValue: stores.watchedApps)
        _autoStopRules = StateObject(wrappedValue: stores.autoStopRules)
        _processHistory = StateObject(wrappedValue: processHistory)
        _activityMonitor = State(initialValue: ActivityMonitorCoordinator())
    }

    var body: some Scene {
        WindowGroup(TaskScopeScene.main.title, id: TaskScopeScene.main.id) {
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
            // Replaces File > New, which opened duplicate main windows.
            CommandGroup(replacing: .newItem) {
                Button("Refresh") { focusedCommands?.refresh() }
                    .keyboardShortcut("r")
                    .disabled(focusedCommands == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { focusedCommands?.find() }
                    .keyboardShortcut("f")
                    .disabled(focusedCommands == nil)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Tree View", isOn: Binding(
                    get: { focusedCommands?.isTreeMode ?? false },
                    set: { focusedCommands?.setTreeMode($0) }
                ))
                .disabled(focusedCommands == nil)
                Divider()
                Button("Processes") { focusedCommands?.showSection(.processes) }
                    .disabled(focusedCommands == nil)
                Button("Presets") { focusedCommands?.showSection(.presets) }
                    .disabled(focusedCommands == nil)
            }
            CommandMenu("Process") {
                Button("Show Detail") { focusedCommands?.showDetail() }
                    .keyboardShortcut("i")
                    .disabled(focusedCommands?.hasKeyboardProcess != true)
                Divider()
                Button("Stop…") { focusedCommands?.stop(.normal) }
                    .disabled(focusedCommands?.canStop != true)
                Button("Force Stop…") { focusedCommands?.stop(.force) }
                    .disabled(focusedCommands?.canStop != true)
            }
            // The default "TaskScope Help" item opened a help book this bundle
            // does not have; the welcome window is the app's help.
            CommandGroup(replacing: .help) {
                Button("Welcome to TaskScope") {
                    showOnboardingWindow()
                }
                .keyboardShortcut("?", modifiers: .command)
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

        // Single-instance scenes: a second About command or a second request
        // for onboarding fronts the open window instead of stacking another.
        Window(TaskScopeScene.about.title, id: TaskScopeScene.about.id) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        Window(TaskScopeScene.onboarding.title, id: TaskScopeScene.onboarding.id) {
            OnboardingView(
                hotkeyShortcut: HotkeyManager.shared.hotkeyEnabled ? HotkeyManager.shared.displayString : nil,
                onComplete: {
                    completeOnboarding()
                }
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        TaskScopeStatusItemLabel()
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

    /// Installs the window, hotkey and quit hooks that need this scene's
    /// `openWindow`, and starts the runtime if AppDelegate has not yet.
    private func bootstrapRuntimeIfNeeded() async {
        guard !didBootstrapRuntime,
              launchSession.allowsRuntime,
              appDelegate.launchContext.performsRuntimeBootstrap else { return }
        didBootstrapRuntime = true

        loginItemManager.refresh()
        HotkeyManager.shared.onShow = {
            showTaskScopeWindow()
        }
        appDelegate.showMainWindow = {
            showTaskScopeWindow()
        }
        let terminationCleanup = TaskScopeTerminationCleanup(activityMonitor: activityMonitor)
        appDelegate.willTerminate = {
            terminationCleanup.perform()
        }
        promptCoordinator = AutoStopPromptCoordinator(rules: autoStopRules, confirmation: AppModalMenuBarConfirmation())
        actionFeedback = ProcessActionFeedback(manager: processManager)
        await appRuntime.start(
            context: appDelegate.launchContext,
            requestShortcutParameterRefresh: { appDelegate.requestShortcutParameterRefresh() }
        )
    }

    private func openOnboardingIfNeeded() {
        guard showOnboarding, !didRequestOnboarding else { return }
        didRequestOnboarding = true
        openWindow(id: TaskScopeScene.onboarding.id)
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
            openWindow(id: TaskScopeScene.main.id)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAboutWindow() {
        appDelegate.permitWindowPresentation()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: TaskScopeScene.about.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The intended way back to the introduction after Get Started.
    private func showOnboardingWindow() {
        appDelegate.permitWindowPresentation()
        openWindow(id: TaskScopeScene.onboarding.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isTaskScopeMainWindow(_ window: NSWindow) -> Bool {
        window.title == TaskScopeScene.main.title
    }
}
