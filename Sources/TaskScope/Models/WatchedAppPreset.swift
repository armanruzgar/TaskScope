import Darwin
import Foundation

struct UserLaunchAgentJob: Codable, Equatable, Hashable, Sendable {
    var label: String
    var plistPath: String
    var isRequired: Bool
    /// The stored job carries keys this build does not know. A newer build may
    /// have added a field that narrows what may be done with the job, so the
    /// preset that owns it is read-only and refuses lifecycle actions, as rules
    /// with unknown fields are. Never encoded: the stored JSON keeps the keys.
    private(set) var hasUnknownFields = false

    init(label: String, plistPath: String, isRequired: Bool = true) {
        self.label = label
        self.plistPath = plistPath
        self.isRequired = isRequired
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case label, plistPath, isRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        plistPath = try container.decode(String.self, forKey: .plistPath)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? true
        hasUnknownFields = try StoredPresetKeys.containsUnknownKey(
            in: decoder,
            known: Set(CodingKeys.allCases.map(\.rawValue))
        )
    }

    // The marker is not part of a job's identity: the built-in preset's identity
    // check compares jobs, and a newer build's copy is still the same job.
    static func == (lhs: UserLaunchAgentJob, rhs: UserLaunchAgentJob) -> Bool {
        lhs.label == rhs.label && lhs.plistPath == rhs.plistPath && lhs.isRequired == rhs.isRequired
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(plistPath)
        hasher.combine(isRequired)
    }
}

struct SystemLaunchDaemonJob: Codable, Equatable, Hashable, Sendable {
    var label: String
    var plistPath: String
    var processName: String
    var servicePort: Int?
}

struct WatchedAppPreset: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID = UUID()
    var displayName: String
    var mainProcessName: String
    var helperProcessNames: [String]
    var protectedProcessNames: [String]
    var appPath: String
    var userLaunchAgentJobs: [UserLaunchAgentJob] = []
    var systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = []
    var notificationsEnabled: Bool = true

    var killableNames: [String] {
        [mainProcessName] + helperProcessNames
    }

    var lifecycleUserLaunchAgentJobs: [UserLaunchAgentJob] {
        if hasSupportedGlobalProtectIdentity {
            return Self.globalProtectUserLaunchAgentJobs
        }
        return userLaunchAgentJobs
    }

    /// The built-in preset reduced to its interface agent (`pangpa`). Actions
    /// that do not disconnect first use it, because unloading the session
    /// `pangps` job stops PanGPS and drops a connected tunnel without the
    /// vendor's disconnect, which can leave DNS unusable.
    var globalProtectInterfaceOnly: WatchedAppPreset {
        var value = self
        value.userLaunchAgentJobs = [Self.globalProtectUserLaunchAgentJobs[0]]
        // Clearing the daemon jobs also stops the legacy-payload match that
        // would expand back to both user jobs in lifecycleUserLaunchAgentJobs.
        value.systemLaunchDaemonJobs = []
        return value
    }

    var lifecycleSystemLaunchDaemonJobs: [SystemLaunchDaemonJob] {
        if hasSupportedGlobalProtectIdentity {
            return Self.globalProtectSystemLaunchDaemonJobs
        }
        return []
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        mainProcessName: String,
        helperProcessNames: [String],
        protectedProcessNames: [String],
        appPath: String,
        userLaunchAgentJobs: [UserLaunchAgentJob] = [],
        systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = [],
        notificationsEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.mainProcessName = mainProcessName
        self.helperProcessNames = helperProcessNames
        self.protectedProcessNames = protectedProcessNames
        self.appPath = appPath
        self.userLaunchAgentJobs = userLaunchAgentJobs
        self.systemLaunchDaemonJobs = systemLaunchDaemonJobs
        self.notificationsEnabled = notificationsEnabled
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, displayName, mainProcessName, helperProcessNames, protectedProcessNames
        case appPath, userLaunchAgentJobs, systemLaunchDaemonJobs, notificationsEnabled
    }

    /// Keys that older builds wrote and this build no longer models. They carry
    /// no authority, so they are ignored rather than treated as a newer build's
    /// fields; builds before 1.0 stored `priority` on every preset.
    static let retiredStoredKeys: Set<String> = ["priority"]

    /// The stored preset, or one of its launch agents, carries keys this build
    /// does not know. A newer build may have added a field that narrows the
    /// preset's authority (a stop scope, a confirmation, a job restriction), so
    /// this build keeps the preset read-only, refuses its lifecycle actions and
    /// leaves it out of Shortcuts, as it does for rules with unknown fields.
    /// Never encoded: the stored JSON keeps the unknown keys themselves.
    private(set) var hasUnknownFields = false

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decode(String.self, forKey: .displayName)
        mainProcessName = try container.decode(String.self, forKey: .mainProcessName)
        helperProcessNames = try container.decodeIfPresent([String].self, forKey: .helperProcessNames) ?? []
        protectedProcessNames = try container.decodeIfPresent([String].self, forKey: .protectedProcessNames) ?? []
        appPath = try container.decode(String.self, forKey: .appPath)
        userLaunchAgentJobs = try container.decodeIfPresent([UserLaunchAgentJob].self, forKey: .userLaunchAgentJobs) ?? []
        systemLaunchDaemonJobs = try container.decodeIfPresent([SystemLaunchDaemonJob].self, forKey: .systemLaunchDaemonJobs) ?? []
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        hasUnknownFields = try StoredPresetKeys.containsUnknownKey(
            in: decoder,
            known: Set(CodingKeys.allCases.map(\.rawValue)).union(Self.retiredStoredKeys)
        ) || userLaunchAgentJobs.contains(where: \.hasUnknownFields)
    }

    /// Fixed so the built-in preset keeps one identity across launches. It used to
    /// take the `UUID()` default, which a `static let` mints fresh per process, and
    /// the seeded default is never written to storage — so any Shortcut bound to
    /// this preset resolved to nothing after a relaunch.
    static let globalProtectID = UUID(uuidString: "1B0E5C1E-6B0A-4F2E-9E7B-2C3A5D8F41A7")!

    static let globalProtect = WatchedAppPreset(
        id: globalProtectID,
        displayName: "GlobalProtect",
        mainProcessName: "GlobalProtect",
        helperProcessNames: ["PanGPA"],
        protectedProcessNames: ["PanGPS"],
        appPath: "/Applications/GlobalProtect.app",
        userLaunchAgentJobs: globalProtectUserLaunchAgentJobs,
        systemLaunchDaemonJobs: globalProtectSystemLaunchDaemonJobs
    )

    var hasCanonicalGlobalProtectIdentity: Bool {
        hasFixedGlobalProtectFields
            && userLaunchAgentJobs == Self.globalProtectUserLaunchAgentJobs
            && systemLaunchDaemonJobs == Self.globalProtectSystemLaunchDaemonJobs
    }

    /// Recognizes the previous built-in payload so a trusted schema migration can
    /// add the optional per-user PanGPS agent without putting preferences into
    /// recovery mode. No custom identity or privileged field is accepted here.
    var hasSupportedGlobalProtectIdentity: Bool {
        hasFixedGlobalProtectFields
            && [
                Self.globalProtectUserLaunchAgentJobs,
                Self.legacyGlobalProtectUserLaunchAgentJobs
            ].contains(userLaunchAgentJobs)
            && systemLaunchDaemonJobs == Self.globalProtectSystemLaunchDaemonJobs
    }

    private var hasFixedGlobalProtectFields: Bool {
        id == Self.globalProtectID
            && displayName == "GlobalProtect"
            && mainProcessName == "GlobalProtect"
            && helperProcessNames == ["PanGPA"]
            && protectedProcessNames == ["PanGPS"]
            && appPath == "/Applications/GlobalProtect.app"
    }

    /// The configured app path with symbolic links resolved, in its on-disk
    /// spelling, which is how the kernel reports executable paths. The stored
    /// value stays the path the user configured, so it is resolved at use: a
    /// re-pointed link or a bundle installed later is followed, and nothing
    /// stored depends on the file system at save time. Falls back to the
    /// configured path when nothing exists there. The built-in preset is
    /// matched at its fixed location only.
    var resolvedAppPath: String {
        canonicalAppPath ?? appPath
    }

    private var canonicalAppPath: String? {
        guard id != Self.globalProtectID, let resolved = realpath(appPath, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `<appPath>/Contents/MacOS/`: a main-process match must be executed from
    /// here. Trailing slash included so prefix checks cannot match a sibling
    /// bundle whose name merely starts with this one.
    var mainExecutableDirectory: String {
        bundleDirectory("Contents/MacOS")
    }

    /// `<appPath>/Contents/`: helper matches must be executed from inside the
    /// bundle, anywhere under Contents.
    var bundleContentsDirectory: String {
        bundleDirectory("Contents")
    }

    private func bundleDirectory(_ component: String) -> String {
        // `realpath` output is already canonical. Standardizing it again would
        // drop a leading `/private`, which kernel executable paths keep.
        let root = canonicalAppPath ?? URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL.path
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(component, isDirectory: true).path + "/"
    }

    static let globalProtectUserLaunchAgentJobs = [
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangpa",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist"
        ),
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangps",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangps.plist",
            isRequired: false
        )
    ]

    static let legacyGlobalProtectUserLaunchAgentJobs = [
        UserLaunchAgentJob(
            label: "com.paloaltonetworks.gp.pangpa",
            plistPath: "/Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist"
        )
    ]

    static let globalProtectSystemLaunchDaemonJobs = [
        SystemLaunchDaemonJob(
            label: "com.paloaltonetworks.gp.pangpsd",
            plistPath: "/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist",
            processName: "PanGPS",
            servicePort: 4767
        )
    ]
}

struct WatchedAppSnapshot: Equatable, Sendable {
    var preset: WatchedAppPreset
    /// Main, helper, and root-owned protected names observed running. Root
    /// ownership alone does not identify the process's launchd domain.
    var runningNames: Set<String>
    /// PIDs of the processes that matched the main process definition. Lifecycle
    /// actions that must leave the main app alone (Quit Helpers) use these to
    /// keep a launch agent that runs the main binary loaded.
    var mainProcessPIDs: Set<Int32> = []
    /// Protected names observed running *without* root privileges. Such a
    /// process is a per-user instance (for GlobalProtect, the optional `pangps`
    /// user agent), never the protected system daemon, and it is reported
    /// separately so it is not mistaken for the daemon. It is still never
    /// signalled by name; Keep Off and Quit unload it through launchd only.
    var unprivilegedProtectedNames: Set<String> = []
    /// A supported GlobalProtect user-agent executable in the fixed bundle,
    /// owned by this user. Explicit Keep Off can unload it; polling preserves it.
    var hasCurrentUserLaunchAgent: Bool = false

    var hasKeepOffTargets: Bool {
        isMainRunning || hasHelpers || hasCurrentUserLaunchAgent
    }

    /// Polling can stop user-facing processes, but preserves the VPN service.
    var hasBackgroundKeepOffTargets: Bool {
        isMainRunning || hasHelpers
    }

    var isMainRunning: Bool {
        runningNames.contains(preset.mainProcessName)
    }

    var helpersRunning: [String] {
        preset.helperProcessNames.filter { runningNames.contains($0) }
    }

    var protectedRunning: [String] {
        preset.protectedProcessNames.filter { runningNames.contains($0) }
    }

    var hasHelpers: Bool {
        !helpersRunning.isEmpty
    }

    var unprivilegedProtectedRunning: [String] {
        preset.protectedProcessNames.filter { unprivilegedProtectedNames.contains($0) }
    }

    var hasAny: Bool {
        !runningNames.isEmpty || !unprivilegedProtectedNames.isEmpty
    }

    var detail: String {
        var names: [String] = []
        if isMainRunning {
            names.append(preset.mainProcessName)
        }
        names.append(contentsOf: helpersRunning)
        names.append(contentsOf: protectedRunning)
        names.append(contentsOf: unprivilegedProtectedRunning.map { "\($0) (user)" })
        return names.isEmpty ? "No watched processes" : names.joined(separator: ", ")
    }
}

extension WatchedAppSnapshot: Identifiable {
    var id: UUID { preset.id }
}

extension Array where Element == WatchedAppSnapshot {
    var aggregateStatus: ProcessStatus {
        if contains(where: { $0.isMainRunning }) {
            return .watchedRunning
        }
        if contains(where: { $0.hasHelpers }) {
            return .helpersOnly
        }
        if contains(where: { !$0.protectedRunning.isEmpty || !$0.unprivilegedProtectedRunning.isEmpty }) {
            return .protectedOnly
        }
        return .idle
    }

    var aggregateDetail: String {
        let running = compactMap { snap -> String? in
            guard snap.hasAny else { return nil }
            return snap.detail
        }
        return running.isEmpty ? "No watched processes" : running.joined(separator: " · ")
    }
}

/// Lists every key of a stored object so a decoder can tell whether the
/// payload holds fields this build does not model.
private enum StoredPresetKeys {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func containsUnknownKey(in decoder: Decoder, known: Set<String>) throws -> Bool {
        try decoder.container(keyedBy: AnyKey.self).allKeys.contains { !known.contains($0.stringValue) }
    }
}
