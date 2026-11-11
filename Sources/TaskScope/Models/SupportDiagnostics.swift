import Foundation

/// The export boundary accepts only fixed categories, counts and validated
/// version numbers. Never add raw messages, labels, preset names or paths here.
struct SupportDiagnosticsReport: Encodable, Equatable, Sendable {
    let schemaVersion = 2
    let app = "TaskScope"
    let version: String
    let build: String
    let macOS: String
    let architecture: Architecture
    let capturedAt: Date
    let permissions: Permissions
    let selectedPreset: Preset?
    let recentLifecycleFailures: [LifecycleDiagnosticFailure]

    enum Architecture: String, Encodable, Sendable {
        case arm64, x86_64, unknown

        static var current: Self {
            #if arch(arm64)
            .arm64
            #elseif arch(x86_64)
            .x86_64
            #else
            .unknown
            #endif
        }
    }

    struct Permissions: Encodable, Equatable, Sendable {
        enum Notification: String, Encodable, Sendable {
            case unknown, notRequested, denied, allowed, provisional
        }
        enum LoginItem: String, Encodable, Sendable {
            case off, on, requiresApproval, unavailable
        }
        let notifications: Notification
        let notificationsEnabledInApp: Bool?
        let accessibilityGranted: Bool
        let launchAtLogin: LoginItem
        // macOS grants administrator authorization per operation, not as a
        // persistent app permission that diagnostics can safely probe.
        let administratorAuthorization = "not queried; requested per privileged action"

        private enum CodingKeys: String, CodingKey {
            case notifications, notificationsEnabledInApp, accessibilityGranted, launchAtLogin, administratorAuthorization
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(notifications, forKey: .notifications)
            // Keep the schema key present: nil means persisted settings are unreadable.
            try container.encode(notificationsEnabledInApp, forKey: .notificationsEnabledInApp)
            try container.encode(accessibilityGranted, forKey: .accessibilityGranted)
            try container.encode(launchAtLogin, forKey: .launchAtLogin)
            try container.encode(administratorAuthorization, forKey: .administratorAuthorization)
        }
    }

    struct Preset: Encodable, Equatable, Sendable {
        enum Kind: String, Encodable, Sendable {
            case builtInGlobalProtect, custom
        }
        let reference = "selected-preset"
        let kind: Kind
        let appBundleFound: Bool
        let keepOffRequested: Bool?
        let userLaunchAgents: [LaunchAgent]

        private enum CodingKeys: String, CodingKey {
            case reference, kind, appBundleFound, keepOffRequested, userLaunchAgents
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(reference, forKey: .reference)
            try container.encode(kind, forKey: .kind)
            try container.encode(appBundleFound, forKey: .appBundleFound)
            try container.encode(keepOffRequested, forKey: .keepOffRequested)
            try container.encode(userLaunchAgents, forKey: .userLaunchAgents)
        }
    }

    struct LaunchAgent: Encodable, Equatable, Sendable {
        enum State: String, Encodable, Sendable {
            case loaded, notLoaded, unknown
        }
        let number: Int
        let required: Bool
        let plistFound: Bool
        let state: State
    }

    init(
        version: String?, build: String?, macOS: OperatingSystemVersion,
        architecture: Architecture = .current, capturedAt: Date,
        permissions: Permissions, selectedPreset: Preset?,
        recentLifecycleFailures: [LifecycleDiagnosticFailure]
    ) {
        self.version = Self.safeVersion(version)
        self.build = Self.safeVersion(build)
        self.macOS = "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)"
        self.architecture = architecture
        self.capturedAt = capturedAt
        self.permissions = permissions
        self.selectedPreset = selectedPreset
        self.recentLifecycleFailures = recentLifecycleFailures
    }

    private static func safeVersion(_ value: String?) -> String {
        guard let value, value.count <= 64,
              value.range(of: #"\A[0-9]+(?:\.[0-9]+){0,3}\z"#, options: .regularExpression) != nil else {
            return "unavailable"
        }
        return value
    }
}

struct LifecycleDiagnosticFailure: Encodable, Equatable, Sendable {
    enum Action: String, Encodable, CaseIterable, Sendable {
        case open, quitApp, quitHelpers, close, keepOff
    }
    enum Reason: String, Encodable, CaseIterable, Sendable {
        case disconnectFailed
        case incomplete, appBundleMissing, inventoryUnavailable
        case systemServiceFailed, userLaunchAgentFailed, launchFailed
        case signalRejected, verificationUnavailable, stillRunning
    }
    let occurredAt: Date
    let action: Action
    let backgroundEnforcement: Bool
    let reason: Reason
    let failedJobCount: Int
    let missingJobCount: Int
}

/// Redacts at capture time. The private UUID is used only to filter the session
/// history; even imported/custom UUIDs are never serialized into a report.
struct LifecycleDiagnosticsHistory {
    static let capacity = 20
    private struct Entry {
        let presetID: UUID
        let failure: LifecycleDiagnosticFailure
    }
    private var entries: [Entry] = []

    mutating func record(
        presetID: UUID, action: LifecycleDiagnosticFailure.Action,
        backgroundEnforcement: Bool = false,
        reason: LifecycleDiagnosticFailure.Reason, jobs: [LifecycleJobResult], at date: Date
    ) {
        entries.insert(Entry(presetID: presetID, failure: LifecycleDiagnosticFailure(
            occurredAt: date, action: action, backgroundEnforcement: backgroundEnforcement,
            reason: reason,
            failedJobCount: jobs.filter { $0.state == .failed }.count,
            missingJobCount: jobs.filter { $0.state == .missing }.count
        )), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    func failures(for presetID: UUID?) -> [LifecycleDiagnosticFailure] {
        entries.filter { $0.presetID == presetID }.map(\.failure)
    }

    mutating func clear() {
        entries.removeAll()
    }
}

/// One immutable byte buffer backs the preview, clipboard and file export.
/// No collection or re-encoding occurs when the user chooses Copy or Save.
struct SupportDiagnosticsPreview: Identifiable {
    let id = UUID()
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }

    init(report: SupportDiagnosticsReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        data = try encoder.encode(report)
    }

    func save(to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
