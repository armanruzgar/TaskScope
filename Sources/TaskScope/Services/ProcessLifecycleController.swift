import Foundation

enum ProcessLifecycleController {
    /// GlobalProtect's current per-user PanGPS agent declares an ExitTimeOut of
    /// 20 seconds. Give launchd enough time to honor that contract before the
    /// command runner cancels bootout and an immediate inspection reports a
    /// false "remained loaded" failure.
    private static let launchAgentBootoutTimeout: TimeInterval = 30

    /// How long a loaded-but-not-yet-running system daemon is given before its
    /// readiness is reported as unverifiable. TaskScope never restarts a loaded
    /// system daemon, so waiting for launchd is the only recovery it performs.
    static let systemDaemonReadinessTimeout: TimeInterval = 15

    enum LaunchJobInspection: Equatable {
        case loaded
        case notLoaded
        case failed(String)
    }

    /// The result of inspecting a protected system launch daemon without
    /// privileges. Only `.notLoaded` (and an inspection that could not decide)
    /// may lead to an administrator bootstrap request.
    enum SystemDaemonReadiness: Equatable {
        /// launchd reports a pid and a fresh inventory shows that pid running the
        /// expected process.
        case ready
        /// launchd has the service loaded but its process is not (yet) verifiable.
        case loadedButNotReady
        case notLoaded
        case inspectionFailed(String)
    }

    static func settleAfterProcessChange(
        runtime: ProcessLifecycleRuntime = .live
    ) async {
        await ProcessTerminationController.settle(runtime: runtime)
    }

    @discardableResult
    static func terminateProcess(
        named name: String,
        policy: TerminationPolicy,
        expectedExecutableDirectory: String,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> ProcessTerminationOutcome {
        await ProcessTerminationController.terminate(
            named: name,
            policy: policy,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            runtime: runtime
        )
    }

    /// Stops a preset's scoped processes for Quit App, Quit Helpers, Quit All
    /// and Keep Off. The main process is stopped first, exactly as on its own,
    /// so helpers that exit with it are never signalled. All helper names then
    /// share one inventory read, one graceful window and one escalation pass,
    /// rather than a window and two reads per name.
    static func terminateProcesses(
        for preset: WatchedAppPreset,
        scope: PresetStopScope,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> [ProcessTerminationOutcome] {
        var outcomes: [ProcessTerminationOutcome] = []
        if scope != .helpers {
            outcomes.append(await ProcessTerminationController.terminate(
                named: preset.mainProcessName,
                policy: .gracefulThenForce,
                expectedExecutableDirectory: preset.mainExecutableDirectory,
                excludingPID: currentPID,
                runtime: runtime
            ))
        }
        if scope != .app {
            outcomes += await ProcessTerminationController.terminate(
                requests: preset.helperProcessNames.map {
                    ProcessTerminationController.Request(
                        name: $0,
                        expectedExecutableDirectory: preset.bundleContentsDirectory
                    )
                },
                policy: .gracefulThenForce,
                excludingPID: currentPID,
                runtime: runtime
            )
        }
        return outcomes
    }

    /// Unloads the preset's per-user launch agents.
    ///
    /// A job whose loaded pid is listed in `preservingPIDs` is left loaded. Quit
    /// Helpers passes the main process pids here because on some GlobalProtect
    /// layouts the `pangpa` agent's Program *is* the main GlobalProtect binary,
    /// and booting it out would quit the app the user asked to keep.
    static func unloadUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingPIDs: Set<Int32> = [],
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []

        for job in jobs.reversed() {
            guard PresetFieldValidation.isValidLaunchAgentLabel(job.label) else {
                results.append(LifecycleJobResult(
                    label: job.label, state: .failed, detail: PresetFieldValidation.launchAgentLabelError
                ))
                continue
            }
            let target = "gui/\(uid)/\(job.label)"
            let plistExists = runtime.fileExists(job.plistPath)
            let status = await inspectLaunchJob(target, label: job.label, runtime: runtime)
            switch status.inspection {
            case .notLoaded:
                // An absent plist is not a failure when the goal is to *stop* the
                // job: there is nothing loaded and nothing to unload, so the stop
                // succeeded. `.missing` is reserved for the bootstrap paths, where
                // an absent plist genuinely prevents the requested action.
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyUnloaded,
                    detail: plistExists
                        ? "Already unloaded."
                        : "No plist at \(job.plistPath); job is not loaded."
                ))
                continue
            case .failed(let detail):
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not inspect job state: \(detail)"
                ))
                continue
            case .loaded:
                break
            }

            // A loaded job whose pid cannot be read may be running the main
            // process the caller asked to keep. Leave it loaded and say so.
            if !preservingPIDs.isEmpty, status.pid == nil, !status.hasNoRunningPID {
                results.append(LifecycleJobResult(
                    label: job.label, state: .failed,
                    detail: "Left loaded: its pid could not be read, so TaskScope could not confirm that it does not run the main \(preset.mainProcessName) process."
                ))
                continue
            }
            if let loadedPID = status.pid, preservingPIDs.contains(loadedPID) {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyLoaded,
                    detail: "Left loaded: it runs the main \(preset.mainProcessName) process (pid \(loadedPID))."
                ))
                continue
            }

            let command = "/bin/launchctl bootout \(ShellCommandRunner.shellQuoted(target))"
            let result = await runtime.runCommand(command, launchAgentBootoutTimeout)
            let after = await inspectAfterBootout(target, label: job.label, commandResult: result, runtime: runtime)
            let didUnload = after == .notLoaded
            results.append(LifecycleJobResult(
                label: job.label,
                state: didUnload
                    ? .changed
                    : .failed,
                detail: didUnload
                    ? (
                        plistExists
                            ? "Unloaded and verified."
                            : "No plist at \(job.plistPath); loaded job was still unloaded and verified."
                    )
                    : lifecycleInspectionFailure(
                        after,
                        commandResult: result,
                        fallback: "Job remained loaded."
                    )
            ))
        }

        await settleAfterProcessChange(runtime: runtime)
        return LifecycleBatchResult(jobs: results)
    }

    /// Persistently disables configured per-user jobs and unloads any live
    /// instances, preserving the VPN service when background enforcement cannot
    /// verify a disconnect. This changes only the current user's launchd domain;
    /// protected system launch daemons are deliberately outside its scope.
    static func disableUserLaunchAgents(
        for preset: WatchedAppPreset,
        preservingVPNService: Bool = false,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []

        for job in jobs.reversed() {
            guard PresetFieldValidation.isValidLaunchAgentLabel(job.label) else {
                results.append(LifecycleJobResult(
                    label: job.label, state: .failed, detail: PresetFieldValidation.launchAgentLabelError
                ))
                continue
            }
            let target = "gui/\(uid)/\(job.label)"
            let disable = await runtime.runCommand(
                "/bin/launchctl disable \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            guard disable.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(disable, fallback: "Could not disable the user launch agent.")
                ))
                continue
            }

            // Background ticks cannot establish a disconnected tunnel. Persist
            // suppression without unloading the session VPN service underneath it.
            if preservingVPNService, preset.hasCanonicalGlobalProtectIdentity,
               job == WatchedAppPreset.globalProtectUserLaunchAgentJobs[1] {
                results.append(LifecycleJobResult(
                    label: job.label, state: .changed,
                    detail: "Disabled persistently; any loaded VPN service was preserved. Choose Apply Keep Off to disconnect and stop it."
                ))
                continue
            }

            switch await inspectLaunchJob(target, label: job.label, runtime: runtime).inspection {
            case .notLoaded:
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .changed,
                    detail: "Disabled persistently; already unloaded."
                ))
            case .failed(let detail):
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Disabled, but could not inspect the live job: \(detail)"
                ))
            case .loaded:
                let bootout = await runtime.runCommand(
                    "/bin/launchctl bootout \(ShellCommandRunner.shellQuoted(target))",
                    launchAgentBootoutTimeout
                )
                let after = await inspectAfterBootout(target, label: job.label, commandResult: bootout, runtime: runtime)
                let didUnload = after == .notLoaded
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: didUnload ? .changed : .failed,
                    detail: didUnload
                        ? "Disabled persistently and unloaded."
                        : lifecycleInspectionFailure(
                            after,
                            commandResult: bootout,
                            fallback: "The disabled job remained loaded."
                        )
                ))
            }
        }

        await settleAfterProcessChange(runtime: runtime)
        return LifecycleBatchResult(jobs: results)
    }

    /// Clears the persistent per-user disable bit without starting or restarting
    /// anything. The ordinary bootstrap path remains responsible for loading and
    /// verifying jobs when the user explicitly opens the preset.
    static func enableUserLaunchAgents(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        let jobs = preset.lifecycleUserLaunchAgentJobs
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []
        let disabledOverrides = await runtime.runCommand(
            "/bin/launchctl print-disabled \(ShellCommandRunner.shellQuoted("gui/\(uid)"))",
            15
        )

        for job in jobs {
            guard PresetFieldValidation.isValidLaunchAgentLabel(job.label) else {
                results.append(LifecycleJobResult(
                    label: job.label, state: .failed, detail: PresetFieldValidation.launchAgentLabelError
                ))
                continue
            }
            let before = GlobalProtectCompatibilityChecker.disabledState(disabledOverrides, label: job.label)
            let enabledDetail: String
            switch before {
            case .disabled:
                enabledDetail = "Persistent disable cleared; no process was started."
            case .enabled, .noOverride:
                enabledDetail = "No persistent disable override; no process was started."
            case .unknown:
                enabledDetail = "Enabled; previous disable state could not be read. No process was started."
            }
            let target = "gui/\(uid)/\(job.label)"
            let result = await runtime.runCommand(
                "/bin/launchctl enable \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            results.append(LifecycleJobResult(
                label: job.label,
                state: result.succeeded ? (before == .disabled ? .changed : .verified) : .failed,
                detail: result.succeeded
                    ? enabledDetail
                    : commandFailure(result, fallback: "Could not re-enable the user launch agent.")
            ))
        }
        return LifecycleBatchResult(jobs: results)
    }

    /// Loads the preset's per-user launch agents that are not already loaded.
    ///
    /// `launchctl enable` runs *before* `bootstrap`: launchd refuses to bootstrap
    /// a service that carries a persistent disable override, so enabling after a
    /// bootstrap could never take effect exactly when it was needed (after Keep
    /// Off had disabled the job). Enabling an already-enabled job is a no-op.
    static func bootstrapUserLaunchAgents(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        await bootstrapUserLaunchAgents(
            jobs: preset.lifecycleUserLaunchAgentJobs,
            avoidDuplicateGlobalProtectUI: preset.hasCanonicalGlobalProtectIdentity,
            runtime: runtime
        )
    }

    private static func bootstrapUserLaunchAgents(
        jobs: [UserLaunchAgentJob],
        avoidDuplicateGlobalProtectUI: Bool = false,
        runtime: ProcessLifecycleRuntime
    ) async -> LifecycleBatchResult {
        guard !jobs.isEmpty else { return .notNeeded }
        let uid = runtime.userID
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard PresetFieldValidation.isValidLaunchAgentLabel(job.label) else {
                results.append(LifecycleJobResult(
                    label: job.label, state: .failed, detail: PresetFieldValidation.launchAgentLabelError
                ))
                continue
            }
            guard runtime.fileExists(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: job.isRequired ? .missing : .alreadyUnloaded,
                    detail: job.isRequired
                        ? "Missing plist at \(job.plistPath)."
                        : "Optional launch agent is not installed at \(job.plistPath)."
                ))
                continue
            }
            guard let plistLabel = runtime.launchAgentLabel(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not read a valid Label from \(job.plistPath)."
                ))
                continue
            }
            guard plistLabel == job.label else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Configured label does not match plist Label \(plistLabel)."
                ))
                continue
            }

            let target = "gui/\(uid)/\(job.label)"
            switch await inspectLaunchJob(target, label: job.label, runtime: runtime).inspection {
            case .loaded:
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .alreadyLoaded,
                    detail: "Already loaded; no restart needed."
                ))
                continue
            case .failed(let detail):
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "Could not inspect job state: \(detail)"
                ))
                continue
            case .notLoaded:
                break
            }

            if avoidDuplicateGlobalProtectUI,
               job == WatchedAppPreset.globalProtectUserLaunchAgentJobs[0] {
                guard case .success(let inventory) = await runtime.loadProcessInventory() else {
                    results.append(LifecycleJobResult(
                        label: job.label, state: .failed,
                        detail: "Could not check for an existing GlobalProtect window; no second instance was started."
                    ))
                    continue
                }
                let existingUI = inventory.contains {
                    $0.uid == runtime.userID
                        && runtime.executablePathForPID($0.pid) == GlobalProtectAccessibilityDisconnect.executable
                }
                if existingUI {
                    results.append(LifecycleJobResult(
                        label: job.label, state: .verified,
                        detail: "GlobalProtect is already open outside this launch job; the UI agent was left unloaded to avoid a duplicate instance."
                    ))
                    continue
                }
            }

            let enable = await runtime.runCommand(
                "/bin/launchctl enable \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            guard enable.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(enable, fallback: "Could not enable the user launch agent before bootstrap.")
                ))
                continue
            }

            let bootstrap = await runtime.runCommand(
                "/bin/launchctl bootstrap \(ShellCommandRunner.shellQuoted("gui/\(uid)")) \(ShellCommandRunner.shellQuoted(job.plistPath))",
                15
            )
            // A nonzero bootstrap is not a verdict: the job may have been loaded
            // by something else in the meantime. Only launchd's state decides.
            let loadedAnyway = bootstrap.succeeded
                ? false
                : await inspectLaunchJob(target, label: job.label, runtime: runtime).inspection == .loaded
            guard bootstrap.succeeded || loadedAnyway else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: commandFailure(bootstrap, fallback: "Bootstrap failed.")
                ))
                continue
            }

            let kickstart = await runtime.runCommand(
                "/bin/launchctl kickstart \(ShellCommandRunner.shellQuoted(target))",
                15
            )
            // launchd's state decides the result, not kickstart's exit status, so
            // a retry that finds the job loaded agrees with this attempt.
            let verified = await inspectLaunchJob(target, label: job.label, runtime: runtime).inspection == .loaded
            results.append(LifecycleJobResult(
                label: job.label,
                state: verified ? .changed : .failed,
                detail: verified
                    ? (kickstart.succeeded
                        ? "Loaded and verified."
                        : "Loaded; the start request failed: \(commandFailure(kickstart, fallback: kickstart.failureDescription))")
                    : commandFailure(kickstart, fallback: "Job could not be verified.")
            ))
        }

        await settleAfterProcessChange(runtime: runtime)
        return LifecycleBatchResult(jobs: results)
    }

    /// Makes sure the immutable built-in preset's protected system daemon is
    /// loaded and running.
    ///
    /// Readiness is decided from `launchctl print system/<label>` plus a fresh
    /// process inventory: the reported pid must be running the expected process.
    /// No port probe is used; an unprivileged `lsof` cannot see a root daemon's
    /// descriptors, so it can never confirm readiness and only ever produced
    /// false negatives.
    ///
    /// Administrator approval is requested only when the daemon is *not loaded*
    /// (or its state could not be inspected). A loaded daemon is never restarted:
    /// `kickstart -k` on a live VPN daemon drops the user's session, so TaskScope
    /// waits for launchd instead and fails closed if the process never appears.
    static func ensureSystemLaunchDaemons(
        for preset: WatchedAppPreset,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> LifecycleBatchResult {
        guard preset.hasCanonicalGlobalProtectIdentity else { return .notNeeded }
        // On current installations PanGPS is a setuid executable launched by
        // gui/<uid>/pangps. Its effective root UID does not make it pangpsd.
        // When pre-logon is off, starting pangpsd can make it remove itself.
        // Restore the installed session service before starting the UI instead.
        let sessionJob = WatchedAppPreset.globalProtectUserLaunchAgentJobs[1]
        if runtime.fileExists(sessionJob.plistPath) {
            return await ensureGlobalProtectSessionService(sessionJob, runtime: runtime)
        }
        let jobs = preset.lifecycleSystemLaunchDaemonJobs
        guard !jobs.isEmpty else { return .notNeeded }
        var results: [LifecycleJobResult] = []

        for job in jobs {
            guard runtime.fileExists(job.plistPath) else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .missing,
                    detail: "Missing plist at \(job.plistPath)."
                ))
                continue
            }

            let readinessDeadline = runtime.systemUptime() + systemDaemonReadinessTimeout
            switch await systemLaunchDaemonReadiness(job, runtime: runtime) {
            case .ready:
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .verified,
                    detail: "Loaded process identity verified."
                ))
                continue
            case .loadedButNotReady:
                let verified = await waitForSystemLaunchDaemon(job, deadline: readinessDeadline, runtime: runtime)
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: verified ? .verified : .failed,
                    detail: verified
                        ? "Loaded process identity verified after waiting for launchd."
                        : "The daemon is loaded, but launchd did not report a running \(job.processName) within \(Int(systemDaemonReadinessTimeout)) seconds. TaskScope never restarts a loaded system daemon; use the organization's supported GlobalProtect recovery path."
                ))
                continue
            case .notLoaded, .inspectionFailed:
                break
            }

            // As the privileged disable path does, never ask root to bootstrap a
            // plist whose Label is not this job's.
            guard runtime.launchAgentLabel(job.plistPath) == job.label else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: "The system service plist has an unreadable or mismatched Label; no administrator command was requested."
                ))
                continue
            }

            let result = await requestAdminBootstrap(for: job, runtime: runtime)
            guard result.succeeded else {
                results.append(LifecycleJobResult(
                    label: job.label,
                    state: .failed,
                    detail: administratorBootstrapFailure(result)
                ))
                continue
            }

            let verified = await waitForSystemLaunchDaemon(job, runtime: runtime)
            results.append(LifecycleJobResult(
                label: job.label,
                state: verified ? .changed : .failed,
                detail: verified
                    ? "Bootstrapped and verified."
                    : "Bootstrap was approved, but launchd did not report a running \(job.processName) within \(Int(systemDaemonReadinessTimeout)) seconds."
            ))
        }

        return LifecycleBatchResult(jobs: results)
    }

    private static func ensureGlobalProtectSessionService(
        _ job: UserLaunchAgentJob,
        runtime: ProcessLifecycleRuntime
    ) async -> LifecycleBatchResult {
        let loaded = await bootstrapUserLaunchAgents(jobs: [job], runtime: runtime)
        guard loaded.succeeded else { return loaded }
        let target = "gui/\(runtime.userID)/\(job.label)"
        let deadline = runtime.systemUptime() + systemDaemonReadinessTimeout
        let attempts = Int(systemDaemonReadinessTimeout / 0.5)
        var requestedStart = loaded.didChangeState
        for attempt in 0...attempts {
            let remaining = deadline - runtime.systemUptime()
            guard remaining > 0, !Task.isCancelled else { break }
            let inspection = await runtime.runCommand(
                "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))", min(remaining, 15)
            )
            // A loaded job whose complete listing shows no pid is idle (for
            // example after PanGPS exited 0). Start it once. A plain kickstart,
            // unlike `kickstart -k`, never restarts a running job.
            if !requestedStart, inspection.succeeded, LaunchctlJobListing.hasNoRunningPID(inspection.stdout) {
                requestedStart = true
                let start = await runtime.runCommand(
                    "/bin/launchctl kickstart \(ShellCommandRunner.shellQuoted(target))", min(remaining, 15)
                )
                guard start.succeeded else {
                    let reason = commandFailure(start, fallback: start.failureDescription)
                    return LifecycleBatchResult(jobs: [LifecycleJobResult(
                        label: job.label, state: .failed,
                        detail: "Could not start the idle login-session VPN service (\(reason.hasSuffix(".") ? String(reason.dropLast()) : reason)). Choose Quit All, then Open to retry."
                    )])
                }
            }
            if let pid = launchJobPID(from: inspection),
               case .success(let inventory) = await runtime.loadProcessInventory(),
               let process = inventory.first(where: { $0.pid == pid }),
               process.uid == 0 || process.uid == runtime.userID,
               let path = runtime.executablePathForPID(pid) {
                var verified = process
                verified.executablePath = path
                if GlobalProtectCompatibilityChecker.trustedName(verified) == .panGPS,
                   runtime.systemUptime() <= deadline, !Task.isCancelled {
                    return LifecycleBatchResult(jobs: [LifecycleJobResult(
                        label: job.label,
                        state: loaded.didChangeState ? .changed : .verified,
                        detail: "Login-session VPN service is running; launchd PID and executable verified. It may run as root."
                    )])
                }
            }
            let sleepSeconds = min(0.5, deadline - runtime.systemUptime())
            guard sleepSeconds > 0, !Task.isCancelled else { break }
            if attempt < attempts { await runtime.sleep(UInt64(sleepSeconds * 1_000_000_000)) }
        }
        return LifecycleBatchResult(jobs: [LifecycleJobResult(
            label: job.label, state: .failed,
            detail: "The login-session VPN service was loaded, but a matching PanGPS process could not be verified. No separate system daemon was started. Choose Quit All, then Open to retry."
        )])
    }

    static func waitForProcessNamed(
        _ name: String,
        timeoutSeconds: TimeInterval,
        expectedExecutableDirectory: String? = nil,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> Bool {
        await ProcessTerminationController.waitUntilRunning(
            named: name,
            timeoutSeconds: timeoutSeconds,
            expectedExecutableDirectory: expectedExecutableDirectory,
            runtime: runtime
        )
    }

    /// Opens the bundle with Launch Services' default single-instance behavior.
    /// `open -n` would force a second instance, which duplicates GlobalProtect
    /// whenever its `pangpa` launch agent already runs the main binary.
    static func openAppBundle(
        at path: String,
        runtime: ProcessLifecycleRuntime = .live
    ) async -> AppBundleOpenResult {
        guard runtime.fileExists(path) else { return .failed("The app bundle is missing.") }
        let result = await runtime.runCommand(
            "/usr/bin/open \(ShellCommandRunner.shellQuoted(path))",
            15
        )
        if result.succeeded { return .opened }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(result.exitCode == ShellCommandRunner.timedOutExitCode
            ? "The launch request timed out." : (detail.isEmpty ? result.failureDescription : detail))
    }

    private static func inspectLaunchJob(
        _ target: String,
        label: String,
        runtime: ProcessLifecycleRuntime
    ) async -> (inspection: LaunchJobInspection, pid: Int32?, hasNoRunningPID: Bool) {
        let result = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))",
            15
        )
        return (
            launchJobInspection(from: result, label: label),
            launchJobPID(from: result),
            result.succeeded && LaunchctlJobListing.hasNoRunningPID(result.stdout)
        )
    }

    /// bootout can return before removal finishes, including a nonzero answer
    /// while removal is in progress. Final inspection determines the outcome;
    /// confirm disappearance without signalling or restarting that PID. A
    /// definitive refusal needs only one inspection, not a disappearance wait.
    private static func inspectAfterBootout(
        _ target: String,
        label: String,
        commandResult: ShellCommandResult,
        runtime: ProcessLifecycleRuntime
    ) async -> LaunchJobInspection {
        let detail = (commandResult.stderr + " " + commandResult.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shouldWait = commandResult.succeeded
            || commandResult.exitCode == 36
            || detail.contains("in progress")
            || commandResult.exitCode == ShellCommandRunner.timedOutExitCode
            || commandResult.terminatedBySignal != nil
            || detail.isEmpty
        let attempts = shouldWait ? Int(launchAgentBootoutTimeout / 0.5) : 0
        for attempt in 0...attempts {
            let state = await inspectLaunchJob(target, label: label, runtime: runtime).inspection
            guard state == .loaded, attempt < attempts else { return state }
            await runtime.sleep(500_000_000)
        }
        return .loaded
    }

    /// Only launchd's own answer for this label confirms absence. Any other
    /// failure, a timeout, or a signal says nothing about the job and must not
    /// let a stop report "already unloaded".
    static func launchJobInspection(from result: ShellCommandResult, label: String) -> LaunchJobInspection {
        if result.succeeded { return .loaded }
        if LaunchctlJobListing.confirmsAbsence(result, label: label) { return .notLoaded }
        let detail = [result.stderr, result.stdout].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "launchctl \(result.failureDescription)." : detail)
    }

    static func systemLaunchDaemonReadiness(
        _ job: SystemLaunchDaemonJob,
        timeout: TimeInterval = 15,
        runtime: ProcessLifecycleRuntime
    ) async -> SystemDaemonReadiness {
        let deadline = runtime.systemUptime() + timeout
        let target = "system/\(job.label)"
        let inspection = await runtime.runCommand(
            "/bin/launchctl print \(ShellCommandRunner.shellQuoted(target))",
            timeout
        )
        switch launchJobInspection(from: inspection, label: job.label) {
        case .notLoaded:
            return .notLoaded
        case .failed(let detail):
            return .inspectionFailed(detail)
        case .loaded:
            break
        }

        // Like the session service and the service observation, bind PanGPS to
        // launchd's pid, a root owner, and a kernel path in the product.
        guard let jobPID = launchJobPID(from: inspection),
              case .success(let inventory) = await runtime.loadProcessInventory(),
              var process = inventory.first(where: { $0.pid == jobPID && $0.name == job.processName }),
              process.uid == 0,
              let path = runtime.executablePathForPID(jobPID) else {
            return .loadedButNotReady
        }
        process.executablePath = path
        guard GlobalProtectCompatibilityChecker.trustedName(process) == .panGPS,
              runtime.systemUptime() <= deadline, !Task.isCancelled else {
            return .loadedButNotReady
        }
        return .ready
    }

    static func launchJobPID(from result: ShellCommandResult) -> Int32? {
        guard result.succeeded else { return nil }
        return GlobalProtectCompatibilityChecker.topLevelPID(result.stdout)
    }

    /// The deadline includes command and inventory time. The attempt cap also
    /// bounds tests whose injected sleep does not advance their clock.
    private static func waitForSystemLaunchDaemon(
        _ job: SystemLaunchDaemonJob,
        deadline: TimeInterval? = nil,
        runtime: ProcessLifecycleRuntime
    ) async -> Bool {
        let deadline = deadline ?? (runtime.systemUptime() + systemDaemonReadinessTimeout)
        let attempts = Int(systemDaemonReadinessTimeout / 0.5)
        for attempt in 0...attempts {
            let remaining = deadline - runtime.systemUptime()
            guard remaining > 0, !Task.isCancelled else { return false }
            if await systemLaunchDaemonReadiness(job, timeout: min(remaining, 15), runtime: runtime) == .ready {
                return runtime.systemUptime() <= deadline
            }
            let sleepSeconds = min(0.5, deadline - runtime.systemUptime())
            guard sleepSeconds > 0, !Task.isCancelled else { return false }
            if attempt < attempts { await runtime.sleep(UInt64(sleepSeconds * 1_000_000_000)) }
        }
        return false
    }

    /// The privileged script only ever bootstraps a daemon that launchd does not
    /// have loaded. When the service is already loaded it exits successfully
    /// without touching it; `kickstart -k` is never used on the system daemon.
    static func adminBootstrapScript(for job: SystemLaunchDaemonJob) -> String {
        let target = "system/\(job.label)"
        return """
        /bin/launchctl enable \(ShellCommandRunner.shellQuoted(target)) || exit $?
        if /bin/launchctl print \(ShellCommandRunner.shellQuoted(target)) >/dev/null 2>&1; then
          exit 0
        else
          /bin/launchctl bootstrap system \(ShellCommandRunner.shellQuoted(job.plistPath))
        fi
        """
    }

    private static func requestAdminBootstrap(
        for job: SystemLaunchDaemonJob,
        runtime: ProcessLifecycleRuntime
    ) async -> ShellCommandResult {
        let rootCommand = adminBootstrapScript(for: job)
        // The prompt names who asks and why; the dialog otherwise shows only
        // the stock "osascript wants to make changes" text.
        let prompt = "TaskScope needs administrator approval to start the GlobalProtect system VPN service (\(job.label))."
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(rootCommand))"
            + " with administrator privileges with prompt \(ShellCommandRunner.appleScriptString(prompt))"
        return await runtime.runCommand(
            "/usr/bin/osascript -e \(ShellCommandRunner.shellQuoted(appleScript))",
            60
        )
    }

    /// Names a refused approval plainly instead of showing osascript's raw
    /// error text. A timeout says nothing about whether root ran the script.
    private static func administratorBootstrapFailure(_ result: ShellCommandResult) -> String {
        if result.exitCode == ShellCommandRunner.timedOutExitCode {
            return "The administrator request was not completed within 60 seconds; approval may not have been given."
        }
        if let error = AdministratorStopOutcome.appleScriptError(in: result.stderr) {
            switch error.number {
            case -128, -60006: return "Administrator approval was cancelled; nothing was started."
            case -60005, -60007: return "Administrator approval was denied or could not be requested (AppleScript error \(error.number))."
            default: break
            }
        }
        return commandFailure(result, fallback: "Administrator approval or bootstrap failed.")
    }

    private static func commandFailure(_ result: ShellCommandResult, fallback: String) -> String {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? fallback : detail
    }

    private static func lifecycleInspectionFailure(
        _ inspection: LaunchJobInspection,
        commandResult: ShellCommandResult,
        fallback: String
    ) -> String {
        if case .failed(let detail) = inspection {
            return detail
        }
        return commandFailure(commandResult, fallback: fallback)
    }
}
