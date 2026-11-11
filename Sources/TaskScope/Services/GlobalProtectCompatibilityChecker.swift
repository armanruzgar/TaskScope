import Darwin
import Foundation

/// A deliberately separate dependency surface from ProcessLifecycleRuntime:
/// there is no signal, bootstrap, enable/disable, open, or preference writer.
struct GlobalProtectCompatibilityRuntime: Sendable {
    typealias Service = GlobalProtectCompatibilityReport.Service
    enum Probe: Hashable, Sendable {
        case userDisabled, systemDisabled, service(Service), macOSVersion, macOSBuild

        func command(userID: uid_t) -> String {
            switch self {
            case .userDisabled: "/bin/launchctl print-disabled gui/\(userID)"
            case .systemDisabled: "/bin/launchctl print-disabled system"
            case .service(let service):
                "/bin/launchctl print \(service.isSystem ? "system" : "gui/\(userID)")/\(service.label)"
            case .macOSVersion: "/usr/bin/sw_vers -productVersion"
            case .macOSBuild: "/usr/bin/sw_vers -buildVersion"
            }
        }
    }

    var userID: uid_t
    var inspectPlist: @Sendable (Service) -> GlobalProtectCompatibilityReport.PlistState
    var runProbe: @Sendable (Probe) async -> ShellCommandResult
    var loadInventory: @Sendable () async -> Result<[AppProcess], ProcessInventoryError>
    var versions: @Sendable () -> (taskScope: String?, taskScopeBuild: String?, globalProtect: String?, globalProtectBuild: String?)
    var executablePathForPID: @Sendable (Int32) -> String? = { _ in nil }
    var now: @Sendable () -> Date = { Date() }

    static let live = Self(
        userID: getuid(),
        inspectPlist: { service in
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: service.plistPath))
                return GlobalProtectCompatibilityChecker.plistState(data, service: service)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return .missing
            } catch {
                return .unreadable
            }
        },
        runProbe: { probe in
            await ShellCommandRunner.run(probe.command(userID: getuid()), timeout: 5)
        },
        loadInventory: { await ProcessListReader.currentProcessList(fetchExtendedStats: false) },
        versions: {
            let app = taskScopeVersionMetadata(Bundle.main.infoDictionary)
            // Read only version metadata, never VPN preferences or configuration.
            let gp = (try? Data(contentsOf: URL(fileURLWithPath: "/Applications/GlobalProtect.app/Contents/Info.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
            return (
                app.version,
                app.build,
                gp?["CFBundleShortVersionString"] as? String,
                gp?["CFBundleVersion"] as? String
            )
        },
        executablePathForPID: { ProcessListReader.executablePath(for: $0) }
    )

    static func taskScopeVersionMetadata(_ info: [String: Any]?) -> (version: String?, build: String?) {
        // XCTest and other hosts have their own bundle versions. Never label
        // the host's version as TaskScope's when running outside the app bundle.
        guard info?["CFBundleExecutable"] as? String == "TaskScope" else { return (nil, nil) }
        return (info?["CFBundleShortVersionString"] as? String, info?["CFBundleVersion"] as? String)
    }
}

struct GlobalProtectCompatibilityChecker: Sendable {
    typealias Report = GlobalProtectCompatibilityReport
    typealias Probe = GlobalProtectCompatibilityRuntime.Probe
    var runtime: GlobalProtectCompatibilityRuntime = .live

    func check(keepOffRequested: Bool?) async -> Report {
        let capturedAt = runtime.now()
        let versions = runtime.versions()
        let plists = Report.Service.allCases.map { runtime.inspectPlist($0) }
        async let inventoryRead = runtime.loadInventory()
        let results = await withTaskGroup(of: (Probe, ShellCommandResult).self) { group in
            let probes: [Probe] = [.userDisabled, .systemDisabled, .macOSVersion, .macOSBuild]
                + Report.Service.allCases.map { .service($0) }
            for probe in probes {
                group.addTask { (probe, await runtime.runProbe(probe)) }
            }
            var results: [Probe: ShellCommandResult] = [:]
            for await (probe, result) in group { results[probe] = result }
            return results
        }
        let jobs = zip(Report.Service.allCases, plists).map { service, plist in
            Report.Job(
                service: service,
                plist: plist,
                disabled: Self.disabledState(results[service.isSystem ? .systemDisabled : .userDisabled]!, label: service.label),
                loaded: Self.loadedState(results[.service(service)]!, service: service)
            )
        }
        let inventory = await inventoryRead
        var counts = Report.ProcessName.allCases.map { Report.ProcessCounts(name: $0) }
        var inventoryFailure: Report.UnknownReason?
        var systemProcessVerified = false
        var sessionProcessVerified = false
        switch inventory {
        case .failure(let error):
            inventoryFailure = error == .cancelled ? .cancelled : .unavailable
        case .success(let processes):
            for process in processes {
                let trustedName = Self.trustedName(process)
                guard let name = trustedName ?? Report.ProcessName(rawValue: process.name),
                      let index = counts.firstIndex(where: { $0.name == name }) else { continue }
                guard trustedName != nil, let uid = process.uid else {
                    counts[index].unverified += 1
                    continue
                }
                if uid == 0 { counts[index].root += 1 }
                else if uid == runtime.userID { counts[index].currentUser += 1 }
                else { counts[index].otherUser += 1 }
            }
            let sessionResult = results[.service(.pangps)]!
            if Self.loadedState(sessionResult, service: .pangps) == .loaded,
               let pid = Self.topLevelPID(sessionResult.stdout),
               var process = processes.first(where: { $0.pid == pid }),
               process.uid == 0 || process.uid == runtime.userID,
               let path = runtime.executablePathForPID(pid) {
                process.executablePath = path
                sessionProcessVerified = Self.trustedName(process) == .panGPS
            }
            let systemResult = results[.service(.pangpsd)]!
            if Self.loadedState(systemResult, service: .pangpsd) == .loaded,
               let pid = Self.topLevelPID(systemResult.stdout) {
                systemProcessVerified = processes.contains {
                    $0.pid == pid && $0.uid == 0 && Self.trustedName($0) == .panGPS
                }
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return Report(
            capturedAt: capturedAt,
            macOSVersion: Self.version(results[.macOSVersion]!),
            macOSBuild: Self.version(results[.macOSBuild]!, osBuild: true),
            taskScopeVersion: Self.safeVersion(versions.taskScope),
            taskScopeBuild: Self.safeBuildNumber(versions.taskScopeBuild),
            globalProtectVersion: Self.safeVersion(versions.globalProtect),
            globalProtectBuild: Self.safeVersion(versions.globalProtectBuild),
            architecture: architecture,
            keepOffRequested: keepOffRequested,
            jobs: jobs,
            processes: counts,
            inventoryFailure: inventoryFailure,
            systemProcessVerified: systemProcessVerified,
            sessionProcessVerified: sessionProcessVerified
        )
    }

    static func plistState(_ data: Data, service: Report.Service) -> Report.PlistState {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let label = dictionary["Label"] as? String else { return .unreadable }
        guard LaunchctlJobListing.normalizedLabel(label) == service.label else { return .labelMismatch }
        if let value = dictionary["Disabled"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return .unreadable
            }
            return .installed(disabledByDefault: number.boolValue)
        }
        return .installed(disabledByDefault: false)
    }

    static func disabledState(_ result: ShellCommandResult, label: String) -> Report.DisabledState {
        guard result.succeeded else { return .unknown(failureReason(result)) }
        let lines = result.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "disabled services = {", lines.last == "}" else { return .unknown(.unrecognized) }
        var found: Report.DisabledState?
        for line in lines.dropFirst().dropLast() {
            // Both boolean and word forms have shipped in launchctl. Parse the
            // entire table so a changed format never becomes a false no-override.
            guard let match = line.range(of: #"^"[^"]+"\s*=>\s*(true|false|enabled|disabled)$"#, options: .regularExpression) ,
                  match == line.startIndex..<line.endIndex,
                  let quote = line.dropFirst().firstIndex(of: "\"") else { return .unknown(.unrecognized) }
            let key = String(line[line.index(after: line.startIndex)..<quote])
            guard key == label else { continue }
            guard found == nil else { return .unknown(.unrecognized) }
            let value = line.components(separatedBy: "=>")[1].trimmingCharacters(in: .whitespaces)
            found = (value == "true" || value == "disabled") ? .disabled : .enabled
        }
        return found ?? .noOverride
    }

    static func loadedState(_ result: ShellCommandResult, service: Report.Service) -> Report.LoadedState {
        if result.succeeded { return .loaded }
        // A missing GUI domain, denied read, signal, or arbitrary exit 113 must
        // not be mistaken for a confirmed absent service.
        if LaunchctlJobListing.confirmsAbsence(result, label: service.label) {
            return .notLoaded
        }
        return .unknown(failureReason(result))
    }

    static func topLevelPID(_ output: String) -> Int32? {
        LaunchctlJobListing.pid(output)
    }

    static func trustedName(_ process: AppProcess) -> Report.ProcessName? {
        guard let path = process.executablePath,
              path == URL(fileURLWithPath: path).standardizedFileURL.path,
              path.hasPrefix("/Applications/GlobalProtect.app/Contents/")
                || path.hasPrefix("/Library/Application Support/PaloAltoNetworks/GlobalProtect/") else { return nil }
        return Report.ProcessName(rawValue: URL(fileURLWithPath: path).lastPathComponent)
    }

    static func failureReason(_ result: ShellCommandResult) -> Report.UnknownReason {
        switch result.exitCode {
        case ShellCommandRunner.timedOutExitCode: .timedOut
        case ShellCommandRunner.cancelledExitCode: .cancelled
        default: .unavailable
        }
    }

    private static func safeBuildNumber(_ value: String?) -> String {
        guard let value else { return "Unavailable" }
        // TaskScope uses a positive integer build counter, not GlobalProtect's
        // dotted/suffixed version format. Match the support report's size bound.
        guard value.count <= 64,
              value.range(of: #"\A[1-9][0-9]{0,63}\z"#, options: .regularExpression) != nil else {
            return "Unavailable (unrecognized value redacted)"
        }
        return value
    }

    static func safeVersion(_ value: String?, osBuild: Bool = false) -> String {
        guard let value else { return "Unavailable" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = osBuild ? #"^[0-9]{1,3}[A-Z][0-9]{1,6}[a-z]?$"# : #"^[0-9]{1,6}(\.[0-9]{1,6}){0,3}(-[a-z]?[0-9]{1,6})?$"#
        guard trimmed.count <= 40,
              let match = trimmed.range(of: pattern, options: .regularExpression),
              match == trimmed.startIndex..<trimmed.endIndex else { return "Unavailable (unrecognized value redacted)" }
        return trimmed
    }

    private static func version(_ result: ShellCommandResult, osBuild: Bool = false) -> String {
        result.succeeded ? safeVersion(result.stdout, osBuild: osBuild) : "Unknown (\(failureReason(result).rawValue))"
    }
}
