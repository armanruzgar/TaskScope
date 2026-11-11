import Foundation

/// Only fixed product identifiers, bounded version strings, states, and counts
/// cross into this model. Raw probe output and process records never do.
struct GlobalProtectCompatibilityReport: Equatable, Sendable {
    enum Service: String, CaseIterable, Sendable {
        case pangpa, pangps, pangpsd

        var label: String { "com.paloaltonetworks.gp.\(rawValue)" }
        var isSystem: Bool { self == .pangpsd }
        var plistPath: String {
            "/Library/\(isSystem ? "LaunchDaemons" : "LaunchAgents")/\(label).plist"
        }
        var displayName: String {
            switch self {
            case .pangpa: "pangpa (user agent)"
            case .pangps: "pangps (login-session VPN service, optional install)"
            case .pangpsd: "pangpsd (protected system service)"
            }
        }
    }

    enum UnknownReason: String, Equatable, Sendable {
        case unavailable = "probe failed or access unavailable"
        case timedOut = "probe timed out"
        case cancelled = "probe cancelled"
        case unrecognized = "unrecognized probe output"
    }

    enum PlistState: Equatable, Sendable {
        case installed(disabledByDefault: Bool)
        case missing
        case unreadable
        case labelMismatch

        var text: String {
            switch self {
            case .installed(let disabled):
                "Installed; label verified; plist default \(disabled ? "disabled" : "enabled")"
            case .missing: "Not installed at the known path"
            case .unreadable: "Unknown (plist unreadable or invalid)"
            case .labelMismatch: "Installed; unexpected label (redacted)"
            }
        }
    }

    enum DisabledState: Equatable, Sendable {
        case disabled, enabled, noOverride
        case unknown(UnknownReason)

        var text: String {
            switch self {
            case .disabled: "Disabled (explicit override)"
            case .enabled: "Enabled (explicit override)"
            case .noOverride: "No override; plist default applies"
            case .unknown(let reason): "Unknown (\(reason.rawValue))"
            }
        }
    }

    enum LoadedState: Equatable, Sendable {
        case loaded, notLoaded
        case unknown(UnknownReason)

        var text: String {
            switch self {
            case .loaded: "Loaded"
            case .notLoaded: "Not loaded"
            case .unknown(let reason): "Unknown (\(reason.rawValue))"
            }
        }
    }

    struct Job: Equatable, Sendable {
        let service: Service
        let plist: PlistState
        let disabled: DisabledState
        let loaded: LoadedState
    }

    enum ProcessName: String, CaseIterable, Sendable {
        case globalProtect = "GlobalProtect", panGPA = "PanGPA", panGPS = "PanGPS"
    }

    struct ProcessCounts: Equatable, Sendable {
        let name: ProcessName
        var currentUser = 0
        var root = 0
        var otherUser = 0
        var unverified = 0
    }

    let capturedAt: Date
    let macOSVersion: String
    let macOSBuild: String
    let taskScopeVersion: String
    let taskScopeBuild: String
    let globalProtectVersion: String
    let globalProtectBuild: String
    let architecture: String
    /// nil means persisted settings could not be read, not that Keep Off is off.
    let keepOffRequested: Bool?
    let jobs: [Job]
    let processes: [ProcessCounts]
    let inventoryFailure: UnknownReason?
    let systemProcessVerified: Bool
    var sessionProcessVerified: Bool = false

    /// One representation is used for preview, clipboard, and UTF-8 export.
    /// Never append raw stderr, launchd dumps, plist values, or process paths.
    var redactedSummary: String {
        var lines = [
            "TaskScope GlobalProtect compatibility self-check (format 1)",
            "Captured: \(ISO8601DateFormatter().string(from: capturedAt))",
            "Read-only observation; not a certification of compatibility or VPN connectivity.",
            "macOS: \(macOSVersion) (build \(macOSBuild))",
            "TaskScope: \(taskScopeVersion) (build \(taskScopeBuild))",
            "TaskScope process architecture: \(architecture)",
            "GlobalProtect: \(globalProtectVersion) (build \(globalProtectBuild))",
            "Keep GlobalProtect Off intent: \(keepOffRequested.map { $0 ? "On" : "Off" } ?? "Unknown (not read or settings unreadable)")",
            "",
            "Known launch jobs (current GUI user / system):"
        ]
        for job in jobs {
            lines += [
                "\(job.service.displayName): \(job.service.label)",
                "  Plist: \(job.plist.text)",
                "  launchd override: \(job.disabled.text)",
                "  launchd service: \(job.loaded.text)"
            ]
        }
        lines += ["", "Process observations:"]
        if let inventoryFailure {
            lines.append("Unknown (\(inventoryFailure.rawValue)); no absence inferred.")
        } else {
            for process in processes {
                lines.append("\(process.name.rawValue): current user \(process.currentUser), root \(process.root), other user \(process.otherUser), unverified identity/owner \(process.unverified)")
            }
            lines.append("Counts require a kernel executable path in the known product directories and a known owner. Name-only candidates are unverified.")
            lines.append("Root PanGPS can belong to the login-session job (setuid) or the system daemon; owner alone does not identify its launch job.")
        }
        lines += ["", "Login-session VPN service process:"]
        if inventoryFailure != nil {
            lines.append("Unknown (process inventory unavailable).")
        } else if sessionProcessVerified {
            lines.append("Verified PanGPS matching the login-session launchd PID, owner and known product path.")
        } else if jobs.first(where: { $0.service == .pangps })?.loaded == .notLoaded {
            lines.append("Not loaded.")
        } else {
            lines.append("Not verified. Loaded does not mean running or healthy.")
        }
        lines += ["", "Protected system-service process:"]
        if inventoryFailure != nil {
            lines.append("Unknown (process inventory unavailable).")
        } else if systemProcessVerified {
            lines.append("Verified root PanGPS matching the system launchd PID and known product path.")
        } else {
            lines.append("Not verified. See launchd service state above; loaded does not mean running or healthy.")
        }
        lines += [
            "",
            "Scope: known built-in paths and labels only; relocated or additional jobs may be missed. Probes are not an atomic snapshot. Policy may change state later.",
            "No launch jobs, processes, preferences, VPN connections, or permissions were changed by this check. No administrator approval was requested.",
            "Privacy: usernames, UIDs, PIDs, hostnames, executable/home paths, arguments, unrelated jobs, raw tool output, and organization/VPN configuration are omitted. Nothing is uploaded.",
            "Manual lifecycle, login/reboot persistence, and managed-policy checks must be recorded separately."
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
