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
///
/// The running copy is the one that holds the per-user single-instance lock
/// (A01-8). A launch that cannot take the lock hands off to the copy its record
/// names. A copy that is quitting keeps the lock only while it still has an
/// action to finish or stop: a launch waits for it, never hands off to it, and
/// becomes the instance once it lets go, even while the quitting process is
/// still listed. The earlier-start rule (A01-7) decides only when the lock
/// cannot: no lock file, no identifiable holder, or a quitting holder that does
/// not let go in time. A quit that begins after a launch has chosen to hand off,
/// before its reopen reaches the holder, still ends both; no lock can see that
/// a reopen was never handled.
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
        /// This process's start time. The lock record carries it, so a later
        /// process that reuses a holder's PID is not taken for the holder. When
        /// the lock cannot decide, a launch yields only to an instance that
        /// started earlier, so two copies started together cannot both hand off
        /// to each other and quit.
        var startTime: TimeInterval = .greatestFiniteMagnitude
        /// The single-instance lock; nil when there is none to take, and then
        /// the earlier-start rule alone decides.
        var instanceLock: TaskScopeInstanceLock?
        /// Blocks the launching main thread between lock attempts. Admission
        /// runs before stores read preferences, so a launch that waits for a
        /// quitting copy starts from the settings that copy saved.
        var pause: @MainActor (TimeInterval) -> Void = { _ in }

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
                    ?? .greatestFiniteMagnitude,
                instanceLock: TaskScopeInstanceLock.fileURL(
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    applicationSupport: FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask
                    ).first
                ).map { TaskScopeInstanceLock.file(at: $0) },
                pause: { Thread.sleep(forTimeInterval: $0) }
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

    struct AdmissionWait: Equatable, Sendable {
        var attempts: Int
        var interval: TimeInterval
    }

    /// How long a launch looks for the holder's record. The holder writes it
    /// right after locking, so a missing record is a matter of microseconds.
    static let holderRecordWait = AdmissionWait(attempts: 25, interval: 0.02)
    /// How long a launch waits for a quitting copy to let the lock go. That
    /// copy keeps it about six seconds at most: up to five for its action and
    /// about one to stop the commands still running.
    static let quittingHolderWait = AdmissionWait(attempts: 200, interval: 0.05)

    let context: TaskScopeLaunchContext
    let userDefaults: UserDefaults
    private let runtime: Runtime
    private let otherInstance: Instance?
    private let isolatedSuiteName: String?
    private var didHandOff = false
    /// Whether this process holds the single-instance lock.
    private(set) var holdsInstanceLock: Bool

    init(
        context: TaskScopeLaunchContext,
        runtime: Runtime,
        standardDefaults: () -> UserDefaults
    ) {
        self.context = context
        self.runtime = runtime
        // Startup verification never takes the lock, waits or hands off, so a
        // staged copy can be checked while TaskScope runs.
        let admission = context == .startupVerification ? Admission() : Self.admit(runtime)
        otherInstance = admission.otherInstance
        holdsInstanceLock = admission.holdsInstanceLock
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

    private struct Admission {
        var otherInstance: Instance?
        var holdsInstanceLock = false
    }

    private static func admit(_ runtime: Runtime) -> Admission {
        func fallback() -> Admission { Admission(otherInstance: earlierInstance(runtime)) }
        guard let lock = runtime.instanceLock else { return fallback() }
        let own = TaskScopeInstanceRecord(processID: runtime.processID, startTime: runtime.startTime, state: .running)
        var recordWaits = 0
        var quittingWaits = 0
        while true {
            let wait: AdmissionWait
            switch lock.acquire(own) {
            case .acquired:
                return Admission(otherInstance: nil, holdsInstanceLock: true)
            case .unavailable:
                return fallback()
            case .held(let record?) where record.state == .quitting:
                guard quittingWaits < quittingHolderWait.attempts else { return fallback() }
                quittingWaits += 1
                wait = quittingHolderWait
            case .held(let record):
                if let record, let holder = listedHolder(record, runtime) {
                    return Admission(otherInstance: holder)
                }
                guard recordWaits < holderRecordWait.attempts else { return fallback() }
                recordWaits += 1
                wait = holderRecordWait
            }
            runtime.pause(wait.interval)
        }
    }

    /// The listed instance a lock record names, if it is still that process:
    /// the same PID and start time, user and bundle identifier, and not this one.
    private static func listedHolder(_ record: TaskScopeInstanceRecord, _ runtime: Runtime) -> Instance? {
        guard record.processID != runtime.processID else { return nil }
        return runtime.runningInstances().first {
            $0.processID == record.processID
                && $0.startTime == record.startTime
                && $0.userID == runtime.userID
                && $0.bundleIdentifier == runtime.bundleIdentifier
        }
    }

    /// A01-7: yield only to an instance that started earlier (on equal start
    /// times, the lower PID), so two copies cannot hand off to each other.
    private static func earlierInstance(_ runtime: Runtime) -> Instance? {
        runtime.runningInstances().first {
            $0.processID != runtime.processID
                && $0.userID == runtime.userID
                && $0.bundleIdentifier == runtime.bundleIdentifier
                && ($0.startTime < runtime.startTime
                    || ($0.startTime == runtime.startTime && $0.processID < runtime.processID))
        }
    }

    /// A quit that waits for an action keeps the lock until the action is over
    /// and records that this copy is quitting, so a launch meanwhile waits for
    /// it instead of handing off to it.
    func markQuitting() {
        guard holdsInstanceLock else { return }
        runtime.instanceLock?.update(TaskScopeInstanceRecord(
            processID: runtime.processID, startTime: runtime.startTime, state: .quitting
        ))
    }

    /// Lets the lock go once this copy has saved its settings and no action is
    /// running any more; a launch from then on becomes the instance.
    func releaseInstanceLock() {
        guard holdsInstanceLock else { return }
        holdsInstanceLock = false
        runtime.instanceLock?.release()
    }

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
        releaseInstanceLock()
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
    /// Shared by the preset deletion policy and ProcessManager.
    let keepOffActivity: KeepOffActivity

    init(session: TaskScopeLaunchSession, inventory: any ProcessInventoryProviding) {
        let defaults = session.userDefaults
        let settings = SettingsStore(userDefaults: defaults)
        self.settings = settings
        keepOffActivity = KeepOffActivity()
        watchedApps = WatchedAppsStore(
            userDefaults: defaults,
            changePolicy: .keepOff(settings: settings, activity: keepOffActivity)
        )
        autoStopRules = AutoStopRulesStore(userDefaults: defaults, inventory: inventory)
        savedSelections = SavedSelectionsStore(userDefaults: defaults)
        showOnboarding = !defaults.bool(forKey: "TaskScope.onboarded.v1")
        // Keep Off is never imported. Its intent can outlive a preset (lost in
        // a recovery reset, or deleted by an older build), so a preset an
        // import creates sheds any intent left for its identity and arrives not
        // kept off. Launch prunes nothing: a preset store in recovery can look
        // empty.
        watchedApps.presetsCreatedByImport = { createdIDs in
            guard !settings.keptOffPresetIDs.isDisjoint(with: createdIDs) else { return }
            settings.keptOffPresetIDs.subtract(createdIDs)
        }
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
