import AppKit
import Darwin

struct TaskScopeLaunchSignal: Equatable, Sendable {
    var arguments: [String]
    var launchedAsLoginItem: Bool
    var receivedOpenURL: Bool
}

enum TaskScopeLaunchContext: Equatable {
    case pending
    case interactive
    case loginItem
    case automation
    case urlAutomation
    case startupVerification

    static func detect(_ signal: TaskScopeLaunchSignal) -> TaskScopeLaunchContext {
        if signal.arguments.contains("--verify-startup") {
            return .startupVerification
        }
        if signal.launchedAsLoginItem {
            return .loginItem
        }
        if signal.arguments.contains("--background")
            || signal.arguments.contains("--automation") {
            return .automation
        }
        if signal.receivedOpenURL {
            return .urlAutomation
        }
        return .interactive
    }

    static func resolve(
        current: TaskScopeLaunchContext,
        signal: TaskScopeLaunchSignal,
        finalizeInteractiveLaunch: Bool
    ) -> TaskScopeLaunchContext {
        let detected = detect(signal)
        if detected.suppressesAutomaticWindowPresentation {
            return detected
        }
        if current != .pending, current.suppressesAutomaticWindowPresentation {
            return current
        }
        return finalizeInteractiveLaunch ? .interactive : .pending
    }

    /// A URL keeps a launch that is still starting in the background even if it
    /// was activated, because Launch Services activates a cold URL launch
    /// before it delivers the URL. An App Intent or entity query never demotes
    /// a launch the user activated or reopened, in any phase.
    static func receivingAutomation(
        current: TaskScopeLaunchContext,
        phase: TaskScopeLaunchPhase,
        source: TaskScopeAutomationSource,
        hasInteractiveSignal: Bool
    ) -> TaskScopeLaunchContext {
        guard current != .startupVerification else { return current }
        if source == .intent, hasInteractiveSignal { return current }
        return phase == .starting || (current == .interactive && !hasInteractiveSignal)
            ? .urlAutomation : current
    }

    var suppressesAutomaticWindowPresentation: Bool {
        self != .interactive
    }

    var allowsExplicitCommands: Bool {
        self != .startupVerification
    }

    var performsRuntimeBootstrap: Bool {
        self != .startupVerification
    }
}

enum TaskScopeAutomationSource: Equatable, Sendable {
    case url
    case intent
}

enum TaskScopeLaunchPhase: Equatable, Sendable {
    case starting
    case running
}

/// Background launches remain accessories; an inactive interactive launch
/// keeps its Dock presence and waits for activation before showing windows.
enum TaskScopeLaunchPresentation: Equatable, Sendable {
    case background
    case presentNow
    case presentOnNextActivation

    static func resolve(context: TaskScopeLaunchContext, isActive: Bool) -> TaskScopeLaunchPresentation {
        guard !context.suppressesAutomaticWindowPresentation else { return .background }
        return isActive ? .presentNow : .presentOnNextActivation
    }
}

@MainActor
enum TaskScopeExternalStateRefresh {
    static func perform(
        refreshLoginItem: () -> Void,
        refreshNotificationAuthorization: () async -> Void
    ) async {
        refreshLoginItem()
        await refreshNotificationAuthorization()
    }
}

/// Launch admission is resolved before constructing stores or installing commands.
@MainActor
final class TaskScopeLaunchSession {
    static let shared = TaskScopeLaunchSession(
        context: TaskScopeLaunchContext.detect(TaskScopeLaunchSignal(
            arguments: ProcessInfo.processInfo.arguments,
            launchedAsLoginItem: false,
            receivedOpenURL: false
        )),
        runtime: .system,
        standardDefaults: { .standard }
    )

    struct Instance: Equatable {
        var processID: pid_t
        var userID: uid_t
        var bundleIdentifier: String
        var startTime: TimeInterval = 0
    }

    @MainActor
    struct Runtime {
        var bundleIdentifier: String?
        var processID: pid_t
        var userID: uid_t
        var runningInstances: @MainActor () -> [Instance]
        var reopen: @MainActor (pid_t) -> Void
        var terminate: @MainActor () -> Void
        /// This process's start time. A launch yields only to an instance that
        /// started earlier, so two copies started together cannot both hand off
        /// to each other and quit.
        var startTime: TimeInterval = .greatestFiniteMagnitude

        static var system: Runtime {
            Runtime(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                processID: ProcessInfo.processInfo.processIdentifier,
                userID: getuid(),
                runningInstances: {
                    guard let identifier = Bundle.main.bundleIdentifier else { return [] }
                    return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                        .compactMap { application in
                            guard !application.isTerminated,
                                  let info = processInfo(application.processIdentifier) else {
                                return nil
                            }
                            return Instance(
                                processID: application.processIdentifier,
                                userID: info.pbi_uid,
                                bundleIdentifier: identifier,
                                startTime: startTime(of: info)
                            )
                        }
                },
                reopen: { TaskScopeInstanceHandoff.system.perform(processID: $0) },
                terminate: { NSApp.terminate(nil) },
                // Unreadable (never expected for this process): yield to any
                // other instance, as every launch did before start times.
                startTime: processInfo(ProcessInfo.processInfo.processIdentifier).map(startTime(of:))
                    ?? .greatestFiniteMagnitude
            )
        }

        private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return info
        }

        private static func startTime(of info: proc_bsdinfo) -> TimeInterval {
            TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        }
    }

    let context: TaskScopeLaunchContext
    let userDefaults: UserDefaults
    private let runtime: Runtime
    private let otherInstance: Instance?
    private let isolatedSuiteName: String?
    private var didHandOff = false

    init(
        context: TaskScopeLaunchContext,
        runtime: Runtime,
        standardDefaults: () -> UserDefaults
    ) {
        self.context = context
        self.runtime = runtime
        otherInstance = context == .startupVerification ? nil : runtime.runningInstances().first {
            $0.processID != runtime.processID
                && $0.userID == runtime.userID
                && $0.bundleIdentifier == runtime.bundleIdentifier
                && ($0.startTime < runtime.startTime
                    || ($0.startTime == runtime.startTime && $0.processID < runtime.processID))
        }
        if context == .startupVerification || otherInstance != nil {
            // A disposable suite also prevents store initializers in a rejected
            // duplicate from rewriting the running instance's preferences.
            let suiteName = "TaskScope.Startup.\(UUID().uuidString)"
            isolatedSuiteName = suiteName
            userDefaults = TaskScopeVolatileDefaults(suiteName: suiteName)
        } else {
            isolatedSuiteName = nil
            userDefaults = standardDefaults()
        }
    }

    var allowsRuntime: Bool { otherInstance == nil && context.performsRuntimeBootstrap }

    @discardableResult
    func continueLaunching() -> Bool {
        guard let otherInstance else { return true }
        if !didHandOff {
            didHandOff = true
            runtime.reopen(otherInstance.processID)
            runtime.terminate()
        }
        return false
    }

    func installCommandHandler(
        on bus: AppCommandBus,
        handler: @escaping @MainActor @Sendable (TaskScopeCommand) async -> TaskScopeCommandResult
    ) {
        // A duplicate hands off and quits during will-finish; it never answers
        // commands, and its bus is left as it is.
        guard otherInstance == nil else { return }
        guard allowsRuntime else {
            // Startup verification still receives URL opens, intents and popover
            // commands. Answer them at once instead of leaving them queued
            // forever behind a handler that is never installed.
            bus.install { _ in AppCommandCoordinator.startupVerificationRejection }
            return
        }
        bus.install(handler: handler)
    }

    func cleanUp() {
        if let isolatedSuiteName {
            userDefaults.removeVolatileDomain(forName: isolatedSuiteName)
        }
    }
}

/// The app and startup verification construct exactly the same set of stores.
@MainActor
struct TaskScopeLaunchStores {
    let settings: SettingsStore
    let watchedApps: WatchedAppsStore
    let autoStopRules: AutoStopRulesStore
    let savedSelections: SavedSelectionsStore
    let showOnboarding: Bool

    init(session: TaskScopeLaunchSession, inventory: any ProcessInventoryProviding) {
        let defaults = session.userDefaults
        settings = SettingsStore(userDefaults: defaults)
        watchedApps = WatchedAppsStore(userDefaults: defaults)
        autoStopRules = AutoStopRulesStore(userDefaults: defaults, inventory: inventory)
        savedSelections = SavedSelectionsStore(userDefaults: defaults)
        showOnboarding = !defaults.bool(forKey: "TaskScope.onboarded.v1")
    }
}

@MainActor
final class TaskScopeTerminationHandler {
    typealias Install = (@escaping @MainActor @Sendable () -> Void) -> (() -> Void)
    private let install: Install
    private let terminate: @MainActor @Sendable () -> Void
    private var cancel: (() -> Void)?

    init(install: @escaping Install, terminate: @escaping @MainActor @Sendable () -> Void) {
        self.install = install
        self.terminate = terminate
    }

    static func system(terminate: @escaping @MainActor @Sendable () -> Void) -> TaskScopeTerminationHandler {
        TaskScopeTerminationHandler(install: { callback in
            // Dispatch observes the signal only after its default exit action
            // has been disabled. Deliver the ordinary AppKit quit on main.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { callback() }
            }
            source.resume()
            return { source.cancel() }
        }, terminate: terminate)
    }

    func start() {
        guard cancel == nil else { return }
        cancel = install(terminate)
    }

    func stop() {
        cancel?()
        cancel = nil
    }
}

/// Startup stores use only encoded Data and the onboarding Bool. Keep both in
/// a uniquely named volatile domain, with no fallback to application defaults.
/// All access is serialized by the launch session and stores on the main actor.
private final class TaskScopeVolatileDefaults: UserDefaults {
    private let domainName: String

    init(suiteName: String) {
        domainName = suiteName
        super.init(suiteName: suiteName)!
        setVolatileDomain([:], forName: domainName)
    }

    override func object(forKey defaultName: String) -> Any? {
        volatileDomain(forName: domainName)[defaultName]
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func bool(forKey defaultName: String) -> Bool {
        object(forKey: defaultName) as? Bool ?? false
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        var values = volatileDomain(forName: domainName)
        values[defaultName] = value
        setVolatileDomain(values, forName: domainName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(value as Any, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        set(nil as Any?, forKey: defaultName)
    }
}

/// The duplicate's handoff uses the running copy's bundle, not the new copy.
@MainActor
struct TaskScopeInstanceHandoff {
    var applicationURL: (pid_t) -> URL?
    var yieldActivation: (pid_t) -> Void
    var openApplication: (URL, NSWorkspace.OpenConfiguration) -> Void

    static var system: TaskScopeInstanceHandoff {
        TaskScopeInstanceHandoff(
            applicationURL: { NSRunningApplication(processIdentifier: $0)?.bundleURL },
            yieldActivation: {
                if let application = NSRunningApplication(processIdentifier: $0) {
                    NSApp.yieldActivation(to: application)
                }
            },
            openApplication: { url, configuration in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        )
    }

    func perform(processID: pid_t) {
        guard let url = applicationURL(processID) else { return }
        yieldActivation(processID)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Launch Services sends a reopen event to the existing instance,
        // including an accessory instance whose windows were suppressed.
        configuration.createsNewApplicationInstance = false
        openApplication(url, configuration)
    }
}
