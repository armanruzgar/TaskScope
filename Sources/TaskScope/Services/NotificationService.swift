import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications

struct ProcessNotificationBaseline {
    private(set) var runningNames: Set<String>?

    mutating func rebaseline(_ names: Set<String>) {
        runningNames = names
    }

    mutating func transitions(
        to names: Set<String>,
        canNotify: Bool
    ) -> (started: Set<String>, stopped: Set<String>) {
        guard canNotify, let previous = runningNames else {
            runningNames = names
            return ([], [])
        }
        runningNames = names
        return (names.subtracting(previous), previous.subtracting(names))
    }
}

/// Keeps notification delivery disabled until a newly enabled configuration has
/// been re-baselined. The generation prevents an older authorization task from
/// completing after a newer toggle and restoring stale state.
@MainActor
final class NotificationEnablementCoordinator {
    private var generation: UInt64 = 0

    @discardableResult
    func beginConfiguration(
        setDeliveryEnabled: (Bool) -> Void
    ) -> UInt64 {
        generation &+= 1
        setDeliveryEnabled(false)
        return generation
    }

    @discardableResult
    func completeEnabledConfiguration<Baseline>(
        token: UInt64,
        currentBaseline: () -> Baseline,
        primeBaseline: (Baseline) -> Void,
        setDeliveryEnabled: (Bool) -> Void
    ) -> Bool {
        guard token == generation else { return false }
        primeBaseline(currentBaseline())
        setDeliveryEnabled(true)
        return true
    }
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum AuthorizationState: Equatable, Sendable {
        case unknown
        case notDetermined
        case denied
        case authorized
        case provisional

        var label: String {
            switch self {
            case .unknown: "Unknown"
            case .notDetermined: "Not requested"
            case .denied: "Denied"
            case .authorized: "Allowed"
            case .provisional: "Provisional"
            }
        }
    }

    static let shared = NotificationService()

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    /// `UNUserNotificationCenter` aborts the process when there is no app
    /// bundle (the bare SwiftPM executable, `swift test`). Every method that
    /// touches the center is a no-op unless this is true.
    let isAvailable: Bool
    /// Running names per watched preset, the baseline of the next diff.
    private var baselines: [UUID: ProcessNotificationBaseline] = [:]
    /// Test seams; `nil` uses UNUserNotificationCenter.
    private let readAuthorization: (@MainActor () async -> AuthorizationState)?
    private let deliver: (@MainActor (UNNotificationRequest) -> Void)?

    override private init() {
        isAvailable = Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        readAuthorization = nil
        deliver = nil
        super.init()
        guard isAvailable else {
            return
        }
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    /// A service that never touches UNUserNotificationCenter: authorization
    /// reads and delivery go to the given closures.
    init(
        isAvailable: Bool,
        authorizationState: AuthorizationState,
        readAuthorization: @escaping @MainActor () async -> AuthorizationState,
        deliver: @escaping @MainActor (UNNotificationRequest) -> Void
    ) {
        self.isAvailable = isAvailable
        self.authorizationState = authorizationState
        self.readAuthorization = readAuthorization
        self.deliver = deliver
        super.init()
    }

    func requestAuthorization() async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert])
        await refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() async {
        guard isAvailable else { return }
        if let readAuthorization {
            authorizationState = await readAuthorization()
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationState = Self.authorizationState(for: settings.authorizationStatus)
    }

    /// macOS sends no event when the user allows notifications in System
    /// Settings, so the polling tick re-reads a cached "cannot deliver"
    /// instead of absorbing transitions until TaskScope is activated. While
    /// delivery is possible, nothing is read.
    func refreshAuthorizationIfUndeliverable() async {
        guard isAvailable, !canDeliver else { return }
        await refreshAuthorizationStatus()
    }

    static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .provisional
        @unknown default:
            .unknown
        }
    }

    /// Starts new baselines from the given watched snapshots. Presets with
    /// notifications turned off are not tracked.
    func prime(_ snapshots: [WatchedAppSnapshot]) {
        baselines = [:]
        for snapshot in snapshots where snapshot.preset.notificationsEnabled {
            var baseline = ProcessNotificationBaseline()
            baseline.rebaseline(snapshot.runningNames)
            baselines[snapshot.preset.id] = baseline
        }
    }

    /// Announces what started and stopped since the baseline: at most one
    /// request per preset and direction, however many processes changed.
    func diffAndNotify(_ snapshots: [WatchedAppSnapshot]) {
        let notifiable = snapshots.filter { $0.preset.notificationsEnabled }
        let sharedNames = Self.sharedProcessNames(among: notifiable.map(\.preset))
        var next: [UUID: ProcessNotificationBaseline] = [:]
        for snapshot in notifiable {
            var baseline = baselines[snapshot.preset.id] ?? ProcessNotificationBaseline()
            let transitions = baseline.transitions(to: snapshot.runningNames, canNotify: canDeliver)
            next[snapshot.preset.id] = baseline
            func shown(_ names: Set<String>) -> Set<String> {
                Set(names.map { Self.displayName(for: $0, in: snapshot.preset, sharedNames: sharedNames) })
            }
            if !transitions.started.isEmpty {
                notify(Self.request(.started, names: shown(transitions.started), presetID: snapshot.preset.id))
            }
            if !transitions.stopped.isEmpty {
                notify(Self.request(.stopped, names: shown(transitions.stopped), presetID: snapshot.preset.id))
            }
        }
        baselines = next
    }

    /// The process names more than one of `presets` lists, such as
    /// JavaApplicationStub for two Java apps.
    nonisolated static func sharedProcessNames(among presets: [WatchedAppPreset]) -> Set<String> {
        var owners: [String: Set<UUID>] = [:]
        for preset in presets {
            for name in preset.killableNames + preset.protectedProcessNames {
                owners[name, default: []].insert(preset.id)
            }
        }
        return Set(owners.filter { $0.value.count > 1 }.keys)
    }

    /// A shared name is shown with its preset's display name, so two presets
    /// that run the same process name stay apart.
    nonisolated static func displayName(
        for name: String,
        in preset: WatchedAppPreset,
        sharedNames: Set<String>
    ) -> String {
        sharedNames.contains(name) ? "\(preset.displayName): \(name)" : name
    }

    enum Transition: String {
        case started, stopped
    }

    /// One preset's starts or stops. The identifier is stable per preset and
    /// direction, so a newer request replaces the older one in Notification
    /// Center, and the thread groups the preset's requests.
    static func request(_ transition: Transition, names: Set<String>, presetID: UUID) -> UNNotificationRequest {
        let sorted = names.sorted()
        let content = UNMutableNotificationContent()
        switch transition {
        case .started:
            content.title = sorted.count == 1 ? "Process Started" : "Processes Started"
            content.body = "\(englishList(sorted)) \(sorted.count == 1 ? "is" : "are") now running."
        case .stopped:
            content.title = sorted.count == 1 ? "Process Stopped" : "Processes Stopped"
            content.body = "\(englishList(sorted)) \(sorted.count == 1 ? "is" : "are") no longer running."
        }
        content.threadIdentifier = "TaskScope.watched.\(presetID.uuidString)"
        return UNNotificationRequest(
            identifier: "TaskScope.watched.\(presetID.uuidString).\(transition.rawValue)",
            content: content,
            trigger: nil
        )
    }

    private static func englishList(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    /// `.list` keeps a notification that arrived while TaskScope was frontmost
    /// in Notification Center, as background delivery does.
    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list]

    private var canDeliver: Bool {
        Self.canDeliver(for: authorizationState)
    }

    nonisolated static func canDeliver(for state: AuthorizationState) -> Bool {
        state == .authorized || state == .provisional
    }

    private func notify(_ request: UNNotificationRequest) {
        guard isAvailable else { return }
        if let deliver {
            deliver(request)
        } else {
            UNUserNotificationCenter.current().add(request)
        }
    }
}
