import Foundation

struct GlobalProtectServiceObservation: Equatable, Sendable {
    enum State: Equatable, Sendable { case absent, running, unknown }
    var session: State
    var system: State

    /// Names and effective UID alone cannot identify another login session's
    /// setuid PanGPS. Only the fixed local jobs and a kernel product path count.
    static func read(runtime: ProcessLifecycleRuntime) async -> Self {
        func state(for service: GlobalProtectCompatibilityReport.Service) async -> State {
            let domain = service.isSystem ? "system" : "gui/\(runtime.userID)"
            let inspection = await runtime.runCommand(
                "/bin/launchctl print \(ShellCommandRunner.shellQuoted("\(domain)/\(service.label)"))", 15
            )
            switch GlobalProtectCompatibilityChecker.loadedState(inspection, service: service) {
            case .notLoaded:
                return .absent
            case .unknown:
                return .unknown
            case .loaded:
                guard let pid = ProcessLifecycleController.launchJobPID(from: inspection) else {
                    return LaunchctlJobListing.hasNoRunningPID(inspection.stdout) ? .absent : .unknown
                }
                guard case .success(let inventory) = await runtime.loadProcessInventory(),
                      var process = inventory.first(where: { $0.pid == pid }),
                      process.uid == 0 || (!service.isSystem && process.uid == runtime.userID),
                      let path = runtime.executablePathForPID(pid) else { return .unknown }
                process.executablePath = path
                return GlobalProtectCompatibilityChecker.trustedName(process) == .panGPS ? .running : .unknown
            }
        }
        let session = await state(for: .pangps)
        let system = await state(for: .pangpsd)
        return Self(session: session, system: system)
    }
}

extension ProcessLifecycleController {
    /// Only an explicit Keep Off action may request privileges. Background
    /// enforcement verifies the system state without prompting or changing it.
    static func disableSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        allowAdministratorPrompt: Bool,
        runtime: ProcessLifecycleRuntime
    ) async -> LifecycleBatchResult {
        guard preset.isBuiltInGlobalProtect else { return .notNeeded }
        let job = WatchedAppPreset.globalProtectSystemDaemon
        let before = await systemOffState(job, runtime: runtime)
        guard let before else {
            return systemResult(job, .verified, "System VPN service is disabled persistently and unloaded.")
        }
        let sessionJob = WatchedAppPreset.globalProtectSessionAgent
        let preservesLoadedDaemon = runtime.fileExists(sessionJob.plistPath)
        let daemonInstalled = runtime.fileExists(job.plistPath)
        if preservesLoadedDaemon || !daemonInstalled {
            let inspection = await runtime.runCommand(
                "/bin/launchctl print \(ShellCommandRunner.shellQuoted("system/\(job.label)"))", 15
            )
            let notLoaded = GlobalProtectCompatibilityChecker.loadedState(inspection, service: .pangpsd) == .notLoaded
            if preservesLoadedDaemon, !notLoaded {
                return systemResult(job, .failed, "The system VPN service is loaded or its state is unknown. Its override and loaded state were preserved because this installation restores the login-session service. Keep Off is incomplete.")
            }
            // With no daemon plist installed and launchd confirming that nothing
            // is loaded, there is nothing to disable. An override is still never
            // written without a matching plist.
            if !daemonInstalled, notLoaded {
                return systemResult(job, .alreadyUnloaded, "No system VPN daemon is installed or loaded; nothing to disable. Reinstalling GlobalProtect can add it again.")
            }
        }
        guard allowAdministratorPrompt else {
            return systemResult(job, .failed, "\(before) Choose Apply Keep Off to stop the system VPN service with administrator approval.")
        }
        // Retain a usable restoration path before introducing a persistent
        // disable override. Never move, rewrite, or remove vendor files.
        guard runtime.fileExists(job.plistPath),
              runtime.launchAgentLabel(job.plistPath) == job.label else {
            return systemResult(job, .failed, "The system service plist is missing or its label does not match. Nothing was disabled; restoration could not be guaranteed.")
        }
        let result = await requestAdminServiceChange(
            adminDisableScript(for: job, preservingLoadedDaemon: preservesLoadedDaemon),
            prompt: "TaskScope needs administrator approval to stop and disable the GlobalProtect system VPN service (\(job.label)). Open restores it.",
            runtime: runtime
        )
        let retry = "Choose Open to restore GlobalProtect or Apply Keep Off to retry."
        let reason: String
        switch AdministratorStopOutcome(result) {
        case .disabled(let bootoutStatus):
            // bootout can return before launchd finishes removing the job, and
            // can exit nonzero both while removal is in progress and after it
            // completed. The bounded wait and its final inspection decide.
            guard let remaining = await waitForSystemOff(job, runtime: runtime) else {
                return systemResult(job, .changed, "System VPN service disabled persistently and unloaded; Open restores the required services without reinstalling.")
            }
            let bootout = bootoutStatus.map { " launchctl bootout exited with status \($0)." } ?? ""
            return systemResult(job, .failed, "\(remaining)\(bootout) \(retry)")
        case .timedOut:
            // A late approval may already have run the disable step, and
            // launchd may still be removing the job; then wait as for `.disabled`.
            let timedOut = "The administrator request was not completed within 90 seconds; approval may not have been given."
            if await systemDisabledState(job, runtime: runtime) == .disabled {
                guard let remaining = await waitForSystemOff(job, runtime: runtime) else {
                    return systemResult(job, .changed, "System VPN service disabled persistently and unloaded; verified after the administrator request timed out.")
                }
                return systemResult(job, .failed, "\(timedOut) \(remaining) \(retry)")
            }
            reason = timedOut
        case .cancelled:
            reason = "Administrator approval was cancelled; TaskScope made no change."
        case .denied(let code):
            reason = "Administrator approval was denied or could not be requested (AppleScript error \(code)); TaskScope made no change."
        case .failed(let detail):
            let trimmed = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
            reason = "The administrator stop did not confirm its disable step (\(trimmed))."
        }
        // No confirmed removal is in progress, so there is nothing to wait for;
        // one inspection reports the current state.
        let remaining = await systemOffState(job, runtime: runtime)
        return systemResult(job, .failed, "\(reason) \(remaining ?? "The service is off, but the administrator command did not finish successfully.") \(retry)")
    }

    /// Printed by the privileged stop only after `launchctl disable` succeeds.
    /// `do shell script` returns stdout only when its script exits 0, so the
    /// script reports bootout's status instead of exiting with it.
    static let systemDisablePhaseMarker = "TASKSCOPE_SYSTEM_DISABLED"
    static let systemBootoutStatusPrefix = "TASKSCOPE_BOOTOUT_EXIT="

    /// What the privileged stop reported. Only `.disabled` started a removal
    /// that waiting can confirm.
    enum AdministratorStopOutcome: Equatable {
        /// The disable phase ran. A nonzero bootout status is not a verdict:
        /// launchd may still be removing the job, or may already have.
        case disabled(bootoutStatus: Int32?)
        case cancelled
        case timedOut
        case denied(Int)
        case failed(String)

        init(_ result: ShellCommandResult) {
            // The runner stopped osascript at its time limit. Whether root ran
            // the script is unknown; launchd inspection decides.
            if result.exitCode == ShellCommandRunner.timedOutExitCode { self = .timedOut; return }
            if result.stdout.contains(ProcessLifecycleController.systemDisablePhaseMarker) {
                let status = result.stdout
                    .range(of: ProcessLifecycleController.systemBootoutStatusPrefix)
                    .flatMap { prefix in
                        Int32(result.stdout[prefix.upperBound...].prefix { $0.isASCII && $0.isNumber })
                    }
                self = .disabled(bootoutStatus: status)
                return
            }
            guard let error = Self.appleScriptError(in: result.stderr) else {
                self = .failed(result.failureDescription)
                return
            }
            switch error.number {
            case -128, -60006:
                // userCanceledErr, errAuthorizationCanceled
                self = .cancelled
            case -60005, -60007:
                // errAuthorizationDenied, errAuthorizationInteractionNotAllowed
                self = .denied(error.number)
            default:
                self = .failed(error.message.isEmpty ? result.failureDescription : error.message)
            }
        }

        /// osascript reports a failed script on stderr as
        /// "<range>: execution error: <message> (<number>)". AppleScript and
        /// Authorization Services use negative numbers; a positive number is
        /// the root script's own exit status.
        static func appleScriptError(in stderr: String) -> (message: String, number: Int)? {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = text.range(of: "execution error: "),
                  text.hasSuffix(")"),
                  let open = text.range(of: " (", options: .backwards),
                  start.upperBound <= open.lowerBound,
                  let number = Int(text[open.upperBound..<text.index(before: text.endIndex)]) else {
                return nil
            }
            return (String(text[start.upperBound..<open.lowerBound]), number)
        }
    }

    /// Restores a required system override; bootstrap belongs to Open. When the
    /// installed session agent supplies PanGPS, keep an unused system daemon
    /// disabled so every Open/Keep Off cycle does not request root privileges.
    static func enableSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime
    ) async -> LifecycleBatchResult {
        guard preset.isBuiltInGlobalProtect else { return .notNeeded }
        let job = WatchedAppPreset.globalProtectSystemDaemon
        let sessionJob = WatchedAppPreset.globalProtectSessionAgent
        let usesSessionService = runtime.fileExists(sessionJob.plistPath)
        let before = await systemDisabledState(job, runtime: runtime)
        switch before {
        case .enabled, .noOverride:
            return systemResult(job, .verified, "No persistent system disable override; no process was started.")
        case .unknown where !usesSessionService:
            return systemResult(job, .failed, "Could not read the system service disable override. Refresh and try again; no system state was changed.")
        case .unknown, .disabled:
            // A session installation never changes the system override here, so
            // an unreadable override must not block restoring the session job.
            break
        }
        if usesSessionService {
            guard runtime.launchAgentLabel(sessionJob.plistPath) == sessionJob.label else {
                return systemResult(job, .failed, "The installed login-session service plist has an unreadable or mismatched label. The system disable override was preserved; no administrator command was requested.")
            }
            return systemResult(job, .verified, "This installation uses the login-session VPN service. The separate system daemon remains disabled; no administrator approval is needed to restore the session service.")
        }
        let script = "/bin/launchctl enable \(ShellCommandRunner.shellQuoted("system/\(job.label)"))"
        let result = await requestAdminServiceChange(
            script,
            prompt: "TaskScope needs administrator approval to re-enable the GlobalProtect system VPN service (\(job.label)). Nothing is started.",
            runtime: runtime
        )
        let after = await systemDisabledState(job, runtime: runtime)
        if result.exitCode == ShellCommandRunner.timedOutExitCode {
            // A late approval may still have cleared the override; launchd decides.
            guard after == .enabled else {
                return systemResult(job, .failed, "The administrator request was not completed within 90 seconds; approval may not have been given. Choose Open to retry.")
            }
            return systemResult(job, .changed, "Persistent system disable cleared and verified after the administrator request timed out; no process was started.")
        }
        guard result.succeeded, after == .enabled else {
            return systemResult(job, .failed, "Could not verify that the system service was re-enabled. Administrator approval may have been cancelled or policy may have rejected the change. Choose Open to retry.")
        }
        return systemResult(job, .changed, "Persistent system disable cleared and verified; no process was started.")
    }

    static func adminDisableScript(for job: SystemLaunchDaemonJob, preservingLoadedDaemon: Bool = false) -> String {
        let target = ShellCommandRunner.shellQuoted("system/\(job.label)")
        // Recheck inside the privileged command in case launchd loaded the
        // daemon while authorization was pending.
        let preserve = preservingLoadedDaemon
            ? "if /bin/launchctl print \(target) >/dev/null 2>&1; then exit 1; fi\n" : ""
        // Once disable succeeds the script exits 0 so its phase marker reaches
        // TaskScope; launchd inspection, not bootout's status, decides the stop.
        return preserve + """
        /bin/launchctl disable \(target) || exit $?
        echo \(systemDisablePhaseMarker)
        if /bin/launchctl print \(target) >/dev/null 2>&1; then
          /bin/launchctl bootout \(target) || echo "\(systemBootoutStatusPrefix)$?"
        fi
        exit 0
        """
    }

    private static func requestAdminServiceChange(
        _ script: String, prompt: String, runtime: ProcessLifecycleRuntime
    ) async -> ShellCommandResult {
        // The prompt names who asks and why; the dialog otherwise shows only
        // the stock "osascript wants to make changes" text.
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(script))"
            + " with administrator privileges with prompt \(ShellCommandRunner.appleScriptString(prompt))"
        // The daemon declares ExitTimeOut=20; allow time for authorization plus
        // launchd's graceful shutdown. No direct signal is sent to PanGPS.
        return await runtime.runCommand(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))", 90
        )
    }

    private static func systemDisabledState(
        _ job: SystemLaunchDaemonJob, timeout: TimeInterval = 15, runtime: ProcessLifecycleRuntime
    ) async -> GlobalProtectCompatibilityReport.DisabledState {
        let result = await runtime.runCommand("/bin/launchctl print-disabled system", timeout)
        return GlobalProtectCompatibilityChecker.disabledState(result, label: job.label)
    }

    /// nil means both independent launchd checks succeeded. A failed, timed-out,
    /// or unrecognized probe never establishes that the service is off.
    private static func systemOffState(
        _ job: SystemLaunchDaemonJob, deadline: TimeInterval? = nil, runtime: ProcessLifecycleRuntime
    ) async -> String? {
        let remaining = deadline.map { $0 - runtime.systemUptime() } ?? 15
        guard remaining > 0, !Task.isCancelled else { return "System stop verification did not complete." }
        let disabled = await systemDisabledState(job, timeout: min(remaining, 15), runtime: runtime)
        let printRemaining = deadline.map { $0 - runtime.systemUptime() } ?? 15
        guard printRemaining > 0, !Task.isCancelled else { return "System stop verification did not complete." }
        let result = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted("system/\(job.label)"))", min(printRemaining, 15)
        )
        guard GlobalProtectCompatibilityChecker.loadedState(result, service: .pangpsd) == .notLoaded else {
            return "The system VPN service is still loaded or its state could not be verified."
        }
        guard disabled == .disabled else {
            return "The persistent system disable override is not verified; the VPN service could start again."
        }
        return nil
    }

    private static func waitForSystemOff(
        _ job: SystemLaunchDaemonJob, runtime: ProcessLifecycleRuntime
    ) async -> String? {
        let deadline = runtime.systemUptime() + 30
        var remaining: String? = "System stop verification did not complete."
        for attempt in 0...60 {
            guard runtime.systemUptime() < deadline, !Task.isCancelled else { break }
            remaining = await systemOffState(job, deadline: deadline, runtime: runtime)
            guard remaining != nil else { return nil }
            let sleepSeconds = min(0.5, deadline - runtime.systemUptime())
            guard sleepSeconds > 0, !Task.isCancelled else { break }
            if attempt < 60 { await runtime.sleep(UInt64(sleepSeconds * 1_000_000_000)) }
        }
        return remaining
    }

    private static func systemResult(
        _ job: SystemLaunchDaemonJob, _ state: LifecycleJobState, _ detail: String
    ) -> LifecycleBatchResult {
        LifecycleBatchResult(jobs: [LifecycleJobResult(label: job.label, state: state, detail: detail)])
    }
}
