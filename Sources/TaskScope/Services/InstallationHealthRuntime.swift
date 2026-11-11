import AppKit
import ApplicationServices
import Darwin
import Foundation
import Security

/// Read-only probes, separate from lifecycle and permission-request services.
struct InstallationHealthRuntime: Sendable {
    var permissions: @MainActor @Sendable () async -> HealthPermissionEvidence
    var bundle: @Sendable () -> HealthBundleEvidence
    var paths: @Sendable ([WatchedAppPreset]) -> [HealthPathFinding]
    var recoveries: @MainActor @Sendable () -> Set<InstallationHealthReport.Recovery>
    var now: @Sendable () -> Date = { Date() }
    /// How long a collection waits for the file and signature probes.
    var probeTimeout: TimeInterval = 10
    var probeRunner = InstallationHealthProbeRunner()

    func collect(_ input: InstallationHealthInput) async -> InstallationHealthReport {
        // File and signature work runs on the probe runner's own queue, never
        // on Swift's cooperative pool, and is waited for only until a deadline.
        // Cancellation invalidates publication; probes never write or prompt
        // for permission.
        let checkedAt = now()
        let presets = input.presets
        let readsPaths = input.presetsReadable
        let paths = paths
        let probes = await probeRunner.run(
            timeout: probeTimeout,
            bundle: bundle,
            paths: { readsPaths ? paths(presets) : [] }
        )
        let unfinishedDetail = probes.earlierProbePending
            ? "An earlier check is still waiting for the file system; a volume may be unresponsive. Refresh Health to try again later."
            : "The check did not finish in time; a volume may be unresponsive. Refresh Health to try again."
        let permissionEvidence = await permissions()
        var report = await InstallationHealthAssessment.report(
            input: input, permissions: permissionEvidence,
            bundle: probes.bundle ?? HealthBundleEvidence(
                identity: .unavailable, identityDetail: unfinishedDetail,
                signature: .unverified, metadata: .unavailable
            ),
            paths: probes.paths ?? [], recoveries: recoveries(), checkedAt: checkedAt
        )
        var unfinished: Set<InstallationHealthReport.Category> = []
        if probes.bundle == nil { unfinished.formUnion([.signing, .appIntents, .bundleIdentity]) }
        if readsPaths, probes.paths == nil { unfinished.insert(.presetPaths) }
        for index in report.findings.indices where unfinished.contains(report.findings[index].category) {
            report.findings[index].state = .unavailable
            report.findings[index].detail = unfinishedDetail
        }
        return report
    }

    static let live = Self(
        permissions: {
            let service = NotificationService.shared
            await service.refreshAuthorizationStatus()
            return .init(
                notificationsAvailable: service.isAvailable,
                notifications: service.authorizationState,
                accessibilityTrusted: AXIsProcessTrusted(),
                loginItem: service.isAvailable ? SystemLoginItemService().state : .notFound
            )
        },
        bundle: { InstallationHealthProbe.inspectBundle() },
        paths: { InstallationHealthProbe.inspectPaths($0) },
        recoveries: { InstallationHealthRecovery.available() }
    )
}

/// Runs the blocking Health probes on one dedicated serial queue. open, stat
/// and read on a volume that stopped answering can block indefinitely, and on
/// the cooperative pool every such call would pin one of its few threads.
/// The caller waits only until a deadline; evidence that finished by then is
/// kept. While a probe is still blocked, later runs start nothing new and
/// report the checks as pending.
final class InstallationHealthProbeRunner: @unchecked Sendable {
    struct Result: Sendable {
        var bundle: HealthBundleEvidence?
        var paths: [HealthPathFinding]?
        var earlierProbePending = false
    }

    private let lock = NSLock()
    private var probeInFlight = false
    private let queue = DispatchQueue(label: "TaskScope.InstallationHealthProbes", qos: .userInitiated)

    func run(
        timeout: TimeInterval,
        bundle: @escaping @Sendable () -> HealthBundleEvidence,
        paths: @escaping @Sendable () -> [HealthPathFinding]
    ) async -> Result {
        let admitted = lock.withLock {
            guard !probeInFlight else { return false }
            probeInFlight = true
            return true
        }
        guard admitted else { return Result(earlierProbePending: true) }

        let progress = ProbeProgress()
        queue.async { [self] in
            progress.setBundle(bundle())
            progress.setPaths(paths())
            lock.withLock { probeInFlight = false }
            progress.finish()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, timeout)) {
            progress.finish()
        }
        return await withTaskCancellationHandler {
            await progress.result()
        } onCancel: {
            progress.finish()
        }
    }

    /// Evidence gathered so far, delivered once: when the probes complete, at
    /// the deadline, or on cancellation, whichever comes first.
    private final class ProbeProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Result()
        private var delivered: Result?
        private var waiter: CheckedContinuation<Result, Never>?

        func setBundle(_ bundle: HealthBundleEvidence) {
            lock.withLock { current.bundle = bundle }
        }

        func setPaths(_ paths: [HealthPathFinding]) {
            lock.withLock { current.paths = paths }
        }

        func finish() {
            let (continuation, result): (CheckedContinuation<Result, Never>?, Result) = lock.withLock {
                if delivered == nil { delivered = current }
                let continuation = waiter
                waiter = nil
                return (continuation, delivered ?? current)
            }
            continuation?.resume(returning: result)
        }

        func result() async -> Result {
            await withCheckedContinuation { continuation in
                let ready: Result? = lock.withLock {
                    if let delivered { return delivered }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

enum InstallationHealthProbe {
    private enum ReadFailure: Error { case malformed, tooLarge }

    /// Bounded, regular-file reads also avoid blocking on a configured FIFO.
    static func readDictionary(_ url: URL, limit: Int = 2_000_000) throws -> [String: Any] {
        // Open follows symlinks, including ENOENT for dangling targets. Inspect
        // the descriptor we actually read so a path swap cannot turn a checked
        // regular file into a blocking FIFO between the check and the open.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ReadFailure.malformed }
        guard metadata.st_size >= 0, metadata.st_size <= limit else { throw ReadFailure.tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ReadFailure.tooLarge }
        // App Intents extraction uses JSON; Info.plist and job plists may be binary.
        let value = (try? JSONSerialization.jsonObject(with: data))
            ?? (try? PropertyListSerialization.propertyList(from: data, format: nil))
        guard let dictionary = value as? [String: Any] else { throw ReadFailure.malformed }
        return dictionary
    }

    static func missing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    static func inspectPaths(_ presets: [WatchedAppPreset]) -> [HealthPathFinding] {
        presets.enumerated().flatMap { index, preset -> [HealthPathFinding] in
            let prefix = "Preset \(index + 1)"
            var results: [HealthPathFinding] = []
            do {
                let app = URL(fileURLWithPath: preset.appPath)
                guard preset.appPath.hasPrefix("/"), app.pathExtension.lowercased() == "app" else {
                    throw ReadFailure.malformed
                }
                let info = try readDictionary(app.appendingPathComponent("Contents/Info.plist"))
                guard let executable = info["CFBundleExecutable"] as? String,
                      validExecutableName(executable), info["CFBundlePackageType"] as? String == "APPL" else {
                    throw ReadFailure.malformed
                }
                let path = app.appendingPathComponent("Contents/MacOS/\(executable)")
                var metadata = stat()
                guard stat(path.path, &metadata) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard metadata.st_mode & S_IFMT == S_IFREG,
                      FileManager.default.isExecutableFile(atPath: path.path) else {
                    throw ReadFailure.malformed
                }
                results.append(.init(state: .healthy, detail: "\(prefix): app bundle and executable found; launch behavior is unverified."))
            } catch {
                results.append(pathFailure(error, subject: "\(prefix): app bundle"))
            }
            let jobs = preset.lifecycleUserLaunchAgentJobs.map { ($0.plistPath, $0.label, $0.isRequired) }
                + preset.lifecycleSystemLaunchDaemonJobs.map { ($0.plistPath, $0.label, true) }
            for (number, job) in jobs.enumerated() {
                let subject = "\(prefix), launch plist \(number + 1)"
                do {
                    guard job.0.hasPrefix("/") else { throw ReadFailure.malformed }
                    let info = try readDictionary(URL(fileURLWithPath: job.0))
                    guard info["Label"] as? String == job.1 else { throw ReadFailure.malformed }
                    results.append(.init(state: .healthy, detail: "\(subject): configured label matches; load state is not checked."))
                } catch {
                    if !job.2 && missing(error) {
                        results.append(.init(state: .healthy, detail: "\(subject): optional file is not installed."))
                    } else {
                        results.append(pathFailure(error, subject: subject))
                    }
                }
            }
            return results
        }
    }

    private static func pathFailure(_ error: Error, subject: String) -> HealthPathFinding {
        if missing(error) {
            return .init(state: .stale, detail: "\(subject): configured path is missing. Review the preset or its installer.")
        }
        if error is ReadFailure {
            return .init(state: .unverified, detail: "\(subject): content, type, executable, or label could not be verified.")
        }
        return .init(state: .unavailable, detail: "\(subject): file could not be read; absence is not established.")
    }

    static func validExecutableName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    static func validBundleIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 255
            && value.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil
    }

    static func metadataState(at app: URL) -> InstallationHealthReport.State {
        let root = app.appendingPathComponent("Contents/Resources/Metadata.appintents")
        do {
            let version = try readDictionary(root.appendingPathComponent("version.json"))
            let actions = try readDictionary(root.appendingPathComponent("extract.actionsdata"), limit: 8_000_000)
            return validMetadata(version: version, actions: actions) ? .healthy : .unverified
        } catch {
            return missing(error) ? .unavailable : .unverified
        }
    }

    static func validMetadata(version: [String: Any], actions: [String: Any]) -> Bool {
        guard version["version"] as? String == "3.0",
              let tools = version["toolsVersion"] as? String, !tools.isEmpty else { return false }
        for (group, names) in [
            "actions": ["OpenWatchedAppIntent", "RefreshTaskScopeIntent", "StopWatchedAppIntent"],
            "entities": ["WatchedPresetEntity"], "queries": ["WatchedPresetEntityQuery"]
        ] {
            guard let entries = actions[group] as? [String: Any],
                  names.allSatisfy({ entries[$0] is [String: Any] }) else { return false }
        }
        guard let shortcuts = actions["autoShortcuts"], JSONSerialization.isValidJSONObject(shortcuts),
              let data = try? JSONSerialization.data(withJSONObject: shortcuts),
              let text = String(data: data, encoding: .utf8) else { return false }
        return ["Refresh ${applicationName}", "Stop ${app} in ${applicationName}", "Open ${app} in ${applicationName}"]
            .allSatisfy { text.contains($0) }
    }

    /// Inspects the running app's bundle. `app` is a parameter so tests can
    /// point the same production checks at fixture bundles.
    static func inspectBundle(at app: URL = Bundle.main.bundleURL) -> HealthBundleEvidence {
        guard app.pathExtension.lowercased() == "app" else {
            return .init(identity: .unavailable, identityDetail: "Running outside a packaged .app. Use the installed TaskScope app for permission and integration checks.", signature: .unverified, metadata: .unavailable)
        }
        let info: [String: Any]
        do {
            info = try readDictionary(app.appendingPathComponent("Contents/Info.plist"))
        } catch {
            return .init(identity: missing(error) ? .stale : .unverified,
                         identityDetail: "The running app’s on-disk metadata is missing or unreadable. It may have been moved or replaced; verify the installation before relaunching.",
                         signature: .unverified, metadata: .unverified)
        }
        var diskCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &diskCode)
        var signature = HealthSignature.unverified
        var signingIdentifier: String?
        if created == errSecSuccess, let diskCode {
            let status = SecStaticCodeCheckValidity(diskCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode).union(.noNetworkAccess), nil)
            var dictionary: CFDictionary?
            let copied = SecCodeCopySigningInformation(diskCode, [], &dictionary)
            let signing = dictionary as? [String: Any]
            signingIdentifier = signing?[kSecCodeInfoIdentifier as String] as? String
            signature = signatureState(status: status, informationStatus: copied,
                                       flags: (signing?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value)
        }
        var runningCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &runningCode)
        let dynamicStatus = selfStatus == errSecSuccess && runningCode != nil
            ? SecCodeCheckValidityWithErrors(runningCode!, .noNetworkAccess, nil, nil)
            : (selfStatus == errSecSuccess ? errSecCSInternalError : selfStatus)
        let identity = identityState(
            info: info, runningIdentifier: Bundle.main.bundleIdentifier,
            signingIdentifier: signingIdentifier, dynamicStatus: dynamicStatus
        )
        let detail: String
        switch identity {
        case .healthy:
            detail = "The configured bundle identifier, signing identifier, and running code agree with this on-disk app. This does not detect other installed copies or prove permission continuity across future builds."
        case .stale:
            detail = "The on-disk app no longer matches this running instance. Review the installation, then quit and relaunch it yourself; previous permission results may not apply to the replacement."
        default:
            detail = "The bundle identifier or running/on-disk code relationship could not be verified. A custom identifier is allowed; changing it can create separate preferences and permissions."
        }
        return .init(identity: identity, identityDetail: detail, signature: signature, metadata: metadataState(at: app))
    }

    static func identityState(info: [String: Any], runningIdentifier: String?, signingIdentifier: String?,
                              dynamicStatus: OSStatus) -> InstallationHealthReport.State {
        if dynamicStatus == errSecCSStaticCodeChanged { return .stale }
        guard let identifier = info["CFBundleIdentifier"] as? String, validBundleIdentifier(identifier),
              info["CFBundleExecutable"] as? String == "TaskScope",
              info["CFBundlePackageType"] as? String == "APPL" else { return .unverified }
        guard let runningIdentifier else { return .unverified }
        guard identifier == runningIdentifier else { return .stale }
        guard identifier == signingIdentifier, dynamicStatus == errSecSuccess else { return .unverified }
        return .healthy
    }

    static func signatureState(status: OSStatus, informationStatus: OSStatus, flags: UInt32?) -> HealthSignature {
        if status == errSecCSUnsigned { return .unsigned }
        if status == errSecSuccess, informationStatus == errSecSuccess, let flags {
            return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 ? .adHoc : .signed
        }
        if [errSecCSSignatureFailed, errSecCSBadResource, errSecCSResourcesInvalid,
            errSecCSResourcesNotFound, errSecCSResourcesNotSealed, errSecCSUnsignedNestedCode].contains(status) {
            return .invalid
        }
        return .unverified
    }
}

/// Navigation only: no TCC reset, registration, re-signing, deletion, or lifecycle actions.
@MainActor
enum InstallationHealthRecovery {
    static func systemSettingsURL() -> URL? {
        // Use macOS's system-owned location, not a third-party app that happens
        // to register the same bundle identifier with Launch Services.
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        guard url.resolvingSymlinksInPath() == url,
              Bundle(url: url)?.bundleIdentifier == "com.apple.systempreferences",
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    static func runningAppURL() -> URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension.lowercased() == "app",
              let info = try? InstallationHealthProbe.readDictionary(url.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleExecutable"] as? String == "TaskScope" else { return nil }
        return url
    }

    /// The workspace effects behind recovery, injectable so the destination
    /// checks and navigation can be tested without opening anything.
    @MainActor
    struct Environment {
        var systemSettingsURL: @MainActor () -> URL?
        var runningAppURL: @MainActor () -> URL?
        var finderAvailable: @MainActor () -> Bool
        var openApplication: @MainActor (URL) async throws -> Void
        var revealInFinder: @MainActor (URL) -> Void

        static let live = Environment(
            systemSettingsURL: { InstallationHealthRecovery.systemSettingsURL() },
            runningAppURL: { InstallationHealthRecovery.runningAppURL() },
            finderAvailable: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") != nil
            },
            openApplication: { url in
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            },
            revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
    }

    static func available() -> Set<InstallationHealthReport.Recovery> {
        available(in: .live)
    }

    static func available(in environment: Environment) -> Set<InstallationHealthReport.Recovery> {
        var result: Set<InstallationHealthReport.Recovery> = [.reviewPresets]
        if environment.systemSettingsURL() != nil { result.insert(.systemSettings) }
        if environment.runningAppURL() != nil, environment.finderAvailable() {
            result.insert(.revealApp)
        }
        return result
    }

    static func perform(_ action: InstallationHealthReport.Recovery) async -> Bool {
        await perform(action, in: .live)
    }

    static func perform(
        _ action: InstallationHealthReport.Recovery,
        in environment: Environment
    ) async -> Bool {
        switch action {
        case .systemSettings:
            guard let url = environment.systemSettingsURL() else { return false }
            do {
                try await environment.openApplication(url)
                return true
            } catch { return false }
        case .revealApp:
            guard let url = environment.runningAppURL(), environment.finderAvailable() else { return false }
            environment.revealInFinder(url)
            return true // Request submitted; Finder provides no completion result.
        case .reviewPresets:
            return true // The owning Settings view handles this local navigation.
        }
    }
}
