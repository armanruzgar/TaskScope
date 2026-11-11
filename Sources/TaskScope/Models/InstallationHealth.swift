import Foundation

/// Local-only observations. Deliberately separate from the support export schema.
struct InstallationHealthReport: Equatable, Sendable {
    enum State: String, Sendable {
        case healthy = "Verified"
        case off = "Off"
        case notRequested = "Not requested"
        case requiresApproval = "Requires approval"
        case denied = "Denied"
        case unavailable = "Unavailable"
        case stale = "Stale"
        case unverified = "Unverified"
    }

    enum Category: String, CaseIterable, Sendable {
        case notifications = "Notifications"
        case accessibility = "Accessibility"
        case loginItem = "Launch at Login"
        case signing = "Code signing"
        case appIntents = "App Intents / Shortcuts"
        case presetPaths = "Preset paths"
        case bundleIdentity = "Bundle identity"
    }

    enum Recovery: String, CaseIterable, Sendable {
        case systemSettings = "Open System Settings"
        case revealApp = "Reveal App Location"
        case reviewPresets = "Review Watched Apps"
    }

    struct Finding: Identifiable, Equatable, Sendable {
        var id: Category { category }
        let category: Category
        var state: State
        var detail: String
        var recovery: Recovery?
    }

    let checkedAt: Date
    var findings: [Finding]
    static let freshnessInterval: TimeInterval = 60

    func isFresh(at date: Date) -> Bool {
        (0..<Self.freshnessInterval).contains(date.timeIntervalSince(checkedAt))
    }

    func displayedFindings(at date: Date, invalidated: Bool) -> [Finding] {
        guard !invalidated, isFresh(at: date) else {
            return findings.map {
                Finding(category: $0.category, state: .stale,
                        detail: "Previous result: \($0.state.rawValue). Refresh to read current status.",
                        recovery: nil)
            }
        }
        return findings
    }
}

struct InstallationHealthInput: Equatable, Sendable {
    let presets: [WatchedAppPreset]
    let presetsReadable: Bool
    let notificationsEnabled: Bool?
}

enum HealthSignature: Equatable, Sendable {
    case signed, adHoc, unsigned, invalid, unverified
}

struct HealthBundleEvidence: Equatable, Sendable {
    var identity: InstallationHealthReport.State
    var identityDetail: String
    var signature: HealthSignature
    var metadata: InstallationHealthReport.State
    /// Whether the intact on-disk signature has the hardened runtime flag;
    /// nil when the signature could not be read or validated.
    var hardenedRuntime: Bool? = nil
}

struct HealthPermissionEvidence: Sendable {
    var notificationsAvailable: Bool
    var notifications: NotificationService.AuthorizationState
    var accessibilityTrusted: Bool
    var loginItem: LoginItemState
}

struct HealthPathFinding: Equatable, Sendable {
    let state: InstallationHealthReport.State
    let detail: String
}

enum InstallationHealthAssessment {
    typealias Finding = InstallationHealthReport.Finding

    static func report(
        input: InstallationHealthInput, permissions: HealthPermissionEvidence,
        bundle: HealthBundleEvidence, paths: [HealthPathFinding],
        recoveries: Set<InstallationHealthReport.Recovery>, checkedAt: Date
    ) -> InstallationHealthReport {
        var findings: [Finding] = []
        let notificationState: InstallationHealthReport.State
        let notificationDetail: String
        if !permissions.notificationsAvailable {
            notificationState = .unavailable
            notificationDetail = "Notifications require a packaged app. Launch the installed TaskScope.app."
        } else {
            switch permissions.notifications {
            case .denied:
                notificationState = .denied
                notificationDetail = "macOS denies notifications. Review TaskScope in System Settings > Notifications."
            case .notDetermined:
                notificationState = .notRequested
                notificationDetail = "Authorization has not been requested. Enable notifications in General to request it."
            case .unknown:
                notificationState = .unverified
                notificationDetail = "Notification authorization could not be established. Refresh to retry."
            case .authorized, .provisional:
                notificationState = .healthy
                notificationDetail = permissions.notifications == .provisional
                    ? "macOS allows quiet provisional notifications; banners are not guaranteed."
                    : "macOS allows notifications; Focus and delivery settings can still suppress banners."
            }
        }
        let preferenceDetail = input.notificationsEnabled.map {
            $0 ? " TaskScope’s notification toggle is on; each preset also has its own toggle."
                : " TaskScope’s notification toggle is off."
        } ?? " TaskScope’s notification preference is unreadable."
        findings.append(.init(category: .notifications, state: notificationState,
                              detail: notificationDetail + preferenceDetail, recovery: .systemSettings))
        findings.append(.init(
            category: .accessibility, state: permissions.accessibilityTrusted ? .healthy : .unverified,
            detail: permissions.accessibilityTrusted
                ? "macOS reports Accessibility trust for this process. Exact Activity Monitor selection still depends on its interface."
                : "Accessibility is not granted. macOS does not distinguish denial from a request never made here. Review Privacy & Security > Accessibility in System Settings; Activity Monitor can still open without exact selection.",
            recovery: .systemSettings
        ))
        let loginState: InstallationHealthReport.State
        let loginDetail: String
        switch permissions.loginItem {
        case .enabled:
            loginState = .healthy
            loginDetail = "macOS reports this app’s login item enabled; login execution has not been tested."
        case .notRegistered:
            loginState = .off
            loginDetail = "Launch at Login is not registered. Enable it from TaskScope’s main window if wanted."
        case .requiresApproval:
            loginState = .requiresApproval
            loginDetail = "Review TaskScope in System Settings > General > Login Items."
        case .notFound:
            loginState = .unavailable
            loginDetail = "macOS cannot find the login item. This alone does not prove a stale registration. Review Login Items and the bundle identity below."
        }
        findings.append(.init(category: .loginItem, state: loginState, detail: loginDetail, recovery: .systemSettings))

        let signingState: InstallationHealthReport.State
        let signingDetail: String
        switch bundle.signature {
        case .signed:
            signingState = .healthy
            signingDetail = "The on-disk signature passes local integrity validation. Signing eligibility, notarization, Gatekeeper acceptance, and App Intents execution are unverified."
        case .adHoc:
            signingState = .unavailable
            signingDetail = "The bundle has an intact ad-hoc signature. This packaging mode cannot execute TaskScope App Intents. See SUPPORT.md for a local signed build."
        case .unsigned:
            signingState = .unavailable
            signingDetail = "The app is unsigned. Review the source build and installation instructions in SUPPORT.md."
        case .invalid:
            signingState = .unavailable
            signingDetail = "The on-disk signature failed integrity validation. Review the staged build before replacing the app; diagnostics do not reinstall or re-sign it."
        case .unverified:
            signingState = .unverified
            signingDetail = "Signature integrity could not be checked for this installation."
        }
        findings.append(.init(
            category: .signing, state: signingState,
            detail: signingDetail + Self.hardenedRuntimeSentence(bundle.hardenedRuntime, signature: bundle.signature),
            recovery: .revealApp
        ))
        let intentsState: InstallationHealthReport.State
        if bundle.identity == .stale { intentsState = .stale }
        else if [.adHoc, .unsigned, .invalid].contains(bundle.signature) { intentsState = .unavailable }
        else { intentsState = bundle.metadata == .healthy ? .unverified : bundle.metadata }
        var intentsDetail = bundle.metadata == .healthy
            ? "Expected packaged actions and shortcut phrases are present. Shortcuts discovery, signing eligibility, and execution remain unverified; no action was run."
            : "Expected App Intents metadata is missing, unreadable, or unsupported. Verify the staged bundle using the source build instructions in SUPPORT.md."
        if [.adHoc, .unsigned, .invalid].contains(bundle.signature) {
            intentsDetail = "The signing problem above blocks App Intents readiness. " + intentsDetail
        }
        if bundle.identity == .stale {
            intentsDetail = "The app on disk changed; this running instance cannot establish its readiness. " + intentsDetail
        }
        findings.append(.init(
            category: .appIntents, state: intentsState,
            detail: intentsDetail, recovery: .revealApp
        ))
        let pathState = !input.presetsReadable ? InstallationHealthReport.State.unverified
            : paths.contains(where: { $0.state == .unavailable }) ? .unavailable
            : paths.contains(where: { $0.state == .stale }) ? .stale
            : paths.contains(where: { $0.state == .unverified }) ? .unverified : .healthy
        let pathDetail = !input.presetsReadable
            ? "Saved presets are in recovery mode; fallback entries cannot verify your saved paths. Review Watched Apps and preserve the backup."
            : paths.isEmpty ? "No presets are configured."
            : paths.map(\.detail).joined(separator: "\n")
        findings.append(.init(category: .presetPaths, state: pathState, detail: pathDetail, recovery: .reviewPresets))
        findings.append(.init(category: .bundleIdentity, state: bundle.identity,
                              detail: bundle.identityDetail, recovery: .revealApp))
        if bundle.identity == .stale {
            for index in findings.indices where [.notifications, .accessibility, .loginItem].contains(findings[index].category) {
                findings[index].detail = "Observed for the running instance: \(findings[index].state.rawValue). The app on disk changed; permission continuity for its replacement is unverified. " + findings[index].detail
                findings[index].state = .stale
            }
        }
        for index in findings.indices {
            if let recovery = findings[index].recovery, !recoveries.contains(recovery) {
                findings[index].recovery = nil
            }
        }
        return .init(checkedAt: checkedAt, findings: findings)
    }

    /// Says whether an intact signature carries the hardened runtime, which the
    /// TaskScope scripts set on every build. Reported, not graded: the signing
    /// state stays what the signature check found.
    static func hardenedRuntimeSentence(_ hardenedRuntime: Bool?, signature: HealthSignature) -> String {
        guard signature == .signed || signature == .adHoc, let hardenedRuntime else { return "" }
        return hardenedRuntime
            ? " The hardened runtime is on."
            : " The hardened runtime is off; builds made with the current TaskScope scripts turn it on."
    }
}
