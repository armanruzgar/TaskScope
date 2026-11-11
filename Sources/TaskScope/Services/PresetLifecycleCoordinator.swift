import Combine
import Foundation

/// What one preset lifecycle action decided. The coordinator builds it at the
/// action's single exit; ProcessManager publishes it as it is.
struct PresetLifecycleOutcome: Equatable {
    enum ReportChange: Equatable {
        /// Leave the lifecycle report that is on screen.
        case unchanged
        /// Show this report, or clear it with nil.
        case replace(LifecycleReport?)
    }

    struct Diagnostic: Equatable {
        var presetID: UUID
        var action: LifecycleDiagnosticFailure.Action
        var backgroundEnforcement: Bool
        var reason: LifecycleDiagnosticFailure.Reason
        var jobs: [LifecycleJobResult]
    }

    var result: TaskScopeCommandResult
    /// The status line afterwards; nil leaves it as it is.
    var message: String?
    var report: ReportChange = .unchanged
    /// A failure to record in the lifecycle diagnostics.
    var diagnostic: Diagnostic?
}

/// What a preset lifecycle action needs from ProcessManager while it runs
/// inside ProcessManager's operation gate.
@MainActor
protocol PresetLifecycleHost: AnyObject {
    var dependencies: ProcessManager.Dependencies { get }
    /// The status line now.
    var message: String { get }
    /// The snapshots the last read published.
    var snapshots: [WatchedAppSnapshot] { get }
    var lastInventoryReadWasCancelled: Bool { get }
    /// True while an action holds the operation gate.
    var isMutationActive: Bool { get }
    /// Shows a step of a long action in the status line.
    func showProgress(_ message: String)
    /// An uncached inventory read, reduced to `preset`.
    func currentSnapshot(for preset: WatchedAppPreset) async -> Result<WatchedAppSnapshot, ProcessInventoryError>
    /// Reads the inventory after a change and publishes it; nil when the read failed.
    func refreshInventoryAfterMutation() async -> [AppProcess]?
    func snapshot(for preset: WatchedAppPreset, inventory: [AppProcess]) -> WatchedAppSnapshot
    /// Runs one background Keep Off pass for `preset` through the operation gate.
    func enforceKeepOff(_ preset: WatchedAppPreset) async
}

/// Runs the preset lifecycle: Open, Allow to Run, Keep Off and its background
/// enforcement, and the preset stops (Quit App, Quit Helpers, Quit App and
/// Helpers). Each action ends at one exit that turns its result into a
/// `PresetLifecycleOutcome`: the status, message, report and diagnostic reason
/// come from one value, so a new failure path cannot forget one of them.
@MainActor
final class PresetLifecycleCoordinator: ObservableObject {
    /// One explicit failed disconnect may be followed by a separately confirmed
    /// service stop. Never persisted or exposed to URLs. Polling reads it only
    /// to leave GlobalProtect's UI open for the user during the grace period.
    @Published private(set) var globalProtectDisconnectFailureID: UUID?
    /// How long background enforcement leaves GlobalProtect's UI alone after an
    /// explicit disconnect failed and told the user to complete its request.
    static let disconnectFailureGraceSeconds: TimeInterval = 180

    private var globalProtectDisconnectGraceUntil: Date?
    private struct BackgroundKeepOffFailure: Equatable {
        var message: String
        var jobs: [LifecycleJobResult]
    }
    /// The last failure background enforcement reported for each preset, so an
    /// identical failure on the next poll is not announced again.
    private var backgroundKeepOffFailures: [UUID: BackgroundKeepOffFailure] = [:]

    private let lifecycle: any ProcessLifecycleServicing
    private let now: () -> Date

    init(lifecycle: any ProcessLifecycleServicing, now: @escaping () -> Date) {
        self.lifecycle = lifecycle
        self.now = now
    }

    /// How an action ended, before it becomes an outcome.
    private enum Exit: Equatable {
        case completed(String)
        case failed(String, LifecycleDiagnosticFailure.Reason)
        /// Nothing was done. `publishesMessage` says whether the status line
        /// shows the reason.
        case rejected(String, publishesMessage: Bool)
        /// A read was cancelled, or the task was.
        case cancelled
    }

    /// What an action collected on its way to its exit.
    private struct Run {
        var jobs: [LifecycleJobResult] = []
        var report: PresetLifecycleOutcome.ReportChange = .unchanged
        /// Open: services or the app may have changed.
        var mayHaveChangedState = false
    }

    // MARK: - Refusals

    /// A preset stored with fields from a newer build may carry a restriction
    /// this build cannot honour, so none of its lifecycle actions run here. The
    /// store's copy is checked too, in case the caller holds a copy without them.
    func newerBuildRefusal(for preset: WatchedAppPreset, host: some PresetLifecycleHost) -> TaskScopeCommandResult? {
        guard preset.hasUnknownFields
            || host.dependencies.watchedPresets().contains(where: { $0.id == preset.id && $0.hasUnknownFields }) else {
            return nil
        }
        return TaskScopeCommandResult(status: .rejected, message: WatchedAppsStore.newerBuildMessage)
    }

    // MARK: - Open

    func open(_ preset: WatchedAppPreset, host: some PresetLifecycleHost) async -> PresetLifecycleOutcome {
        var run = Run()
        let exit = await openSteps(preset, host: host, run: &run)
        let name = preset.displayName
        if Task.isCancelled || exit == .cancelled {
            let message = run.mayHaveChangedState
                ? "Open for \(name) was cancelled; services or the app may already have changed."
                : "Open for \(name) was cancelled."
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .rejected, message: message),
                message: run.mayHaveChangedState ? message : nil,
                report: run.report
            )
        }
        return outcome(of: exit, run: run, presetID: preset.id, action: .open, backgroundEnforcement: false)
    }

    private func openSteps(
        _ preset: WatchedAppPreset,
        host: some PresetLifecycleHost,
        run: inout Run
    ) async -> Exit {
        let name = preset.displayName
        if preset.isBuiltInGlobalProtect { globalProtectDisconnectFailureID = nil }
        guard lifecycle.appBundleExists(at: preset.appPath) else {
            // Turning Keep Off off (or Open) must still remove the launchd
            // overrides when the app is gone, for example mid-reinstall or
            // before uninstalling, or a reinstalled client cannot start.
            let wasKeptOff = host.dependencies.isPresetKeptOff(preset)
            guard wasKeptOff || preset.isBuiltInGlobalProtect else {
                return .failed("Could not open \(name): app bundle is missing at \(preset.appPath).", .appBundleMissing)
            }
            run.mayHaveChangedState = true
            let allowed = await clearKeepOffOverrides(preset, host: host, run: &run)
            if allowed.succeeded {
                if !allowed.didChangeState { run.report = .replace(nil) }
                let state = wasKeptOff ? "is no longer kept off" : "is allowed to run"
                return .failed(
                    "\(name) \(state), but its app bundle is missing at \(preset.appPath); nothing was opened.",
                    .appBundleMissing
                )
            }
            let failure = allowed.failureSummary ?? "service could not be enabled"
            return .failed(
                "Could not allow \(name) to run: \(failure). Its app bundle is missing at \(preset.appPath); nothing was opened.",
                .appBundleMissing
            )
        }

        let initial = await host.currentSnapshot(for: preset)
        if case .failure(.cancelled) = initial { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard case .success(let beforeServices) = initial else {
            return .failed("Could not verify whether \(name) is already running; nothing was opened.", .inventoryUnavailable)
        }

        run.mayHaveChangedState = true
        // Whether the app was running before Open changed anything.
        var mainWasRunning = beforeServices.isMainRunning
        // A UI started directly while PanGPS was stopped can remain stuck
        // retrieving configuration even after the service returns. Restart
        // that orphaned UI before restoration; never unload the VPN job.
        if preset.isBuiltInGlobalProtect,
           beforeServices.isMainRunning,
           beforeServices.protectedRunning.isEmpty,
           beforeServices.unprivilegedProtectedRunning.isEmpty {
            let unloadedUI = await lifecycle.unloadUserLaunchAgents(for: preset.globalProtectInterfaceOnly)
            run.jobs += unloadedUI.jobs
            guard unloadedUI.succeeded else {
                run.report = .replace(LifecycleReport(title: "GlobalProtect UI Recovery", jobs: unloadedUI.jobs))
                return .failed("Could not close GlobalProtect's stalled interface. Its VPN service was not stopped.", .userLaunchAgentFailed)
            }
            let stoppedUI = await lifecycle.terminateMainProcess(for: preset)
            await lifecycle.settleAfterProcessChange()
            guard [.signalled, .noMatchingProcesses, .targetsExited].contains(stoppedUI),
                  case .success(let afterUIStop) = await host.currentSnapshot(for: preset),
                  !afterUIStop.isMainRunning else {
                return .failed(
                    "Could not verify that GlobalProtect's stalled interface closed; no second instance was started.",
                    .verificationUnavailable
                )
            }
            mainWasRunning = false
        }

        let ensuredDaemon = await lifecycle.ensureSystemLaunchDaemons(for: preset)
        run.jobs += ensuredDaemon.jobs
        guard ensuredDaemon.succeeded else {
            run.report = .replace(LifecycleReport(title: "\(name) Service Results", jobs: ensuredDaemon.jobs))
            return .failed("Could not open \(name): \(ensuredDaemon.failureSummary ?? "required service failed").", .systemServiceFailed)
        }
        // Bootstrap clears the override in the same administrator request.
        // Only a daemon that was already loaded can still need enabling.
        let systemEnable = preset.isBuiltInGlobalProtect
            ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
        run.jobs += systemEnable.jobs
        let daemonResult = LifecycleBatchResult(jobs: ensuredDaemon.jobs + systemEnable.jobs)
        guard systemEnable.succeeded else {
            run.report = .replace(LifecycleReport(title: "\(name) Service Results", jobs: daemonResult.jobs))
            return .failed(
                "Could not restore GlobalProtect: \(systemEnable.failureSummary ?? "system service could not be enabled").",
                .systemServiceFailed
            )
        }

        let wasKeptOff = host.dependencies.isPresetKeptOff(preset)
        let enableResult: LifecycleBatchResult
        // launchd overrides outlive TaskScope preferences (including reset
        // or reinstall). Explicit Open must recover them even without intent.
        if wasKeptOff || preset.isBuiltInGlobalProtect {
            enableResult = await lifecycle.enableUserLaunchAgents(for: preset)
            run.jobs += enableResult.jobs
            guard enableResult.succeeded else {
                run.report = .replace(LifecycleReport(title: "\(name) Service Results", jobs: daemonResult.jobs + enableResult.jobs))
                return .failed(
                    "Could not allow \(name) to run: \(enableResult.failureSummary ?? "user launch agent could not be enabled").",
                    .userLaunchAgentFailed
                )
            }
        } else {
            enableResult = .notNeeded
        }

        let agentResult = await lifecycle.bootstrapUserLaunchAgents(for: preset)
        run.jobs += agentResult.jobs
        guard agentResult.succeeded else {
            run.report = .replace(LifecycleReport(
                title: "\(name) Service Results",
                jobs: daemonResult.jobs + enableResult.jobs + agentResult.jobs
            ))
            return .failed("Could not open \(name): \(agentResult.failureSummary ?? "required user job failed").", .userLaunchAgentFailed)
        }
        if wasKeptOff || preset.isBuiltInGlobalProtect {
            host.dependencies.setPresetKeptOff(preset, false)
        }
        let serviceJobs = daemonResult.jobs + enableResult.jobs + agentResult.jobs
        let restored = daemonResult.didChangeState
            || enableResult.didChangeState
            || agentResult.didChangeState
        run.report = .replace(serviceJobs.isEmpty || (preset.isBuiltInGlobalProtect && !restored)
            ? nil
            : LifecycleReport(title: "\(name) Service Results", jobs: serviceJobs))

        // Late failures happen after Keep Off may have been cleared and the
        // services restored, so their messages say what already changed.
        var changes: [String] = []
        if wasKeptOff { changes.append("Keep Off was turned off") }
        if restored { changes.append("required services were restored") }
        let changeText = changes.joined(separator: " and ")
        let changeDetail = changeText.isEmpty
            ? ""
            : changeText.prefix(1).uppercased() + changeText.dropFirst() + ". "

        // Restoring the user launch agents can itself start the main process
        // (GlobalProtect's `pangpa` agent runs the main binary). Re-check with
        // a fresh inventory before opening so a second instance is never
        // launched, and fail closed when that check cannot be made.
        let afterServiceRead = await host.currentSnapshot(for: preset)
        if case .failure(.cancelled) = afterServiceRead { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard case .success(let afterServices) = afterServiceRead else {
            return .failed(
                changeDetail + "Could not verify whether \(name) started with its services; no app launch was requested.",
                .inventoryUnavailable
            )
        }
        let alreadyRunning = afterServices.isMainRunning
        // An app that was already running before Open changed anything is
        // brought forward by a plain `open`, which reuses the running
        // instance. One that appeared only after its agents were restored was
        // started by launchd and is not opened again. GlobalProtect's UI is
        // never opened over a running one.
        let activatesRunningApp = alreadyRunning
            && mainWasRunning
            && !preset.isBuiltInGlobalProtect
        let reportsAlreadyRunning = alreadyRunning
            && mainWasRunning
            && !activatesRunningApp

        let openResult: AppBundleOpenResult = alreadyRunning && !activatesRunningApp
            ? .opened
            : await lifecycle.openAppBundle(at: preset.appPath)
        if case .failed(let detail) = openResult {
            let reason = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
            return .failed(changeDetail + "Could not open \(name): \(reason).", .launchFailed)
        }

        if !alreadyRunning {
            _ = await lifecycle.waitForMainProcess(for: preset, timeoutSeconds: 5)
        }
        guard !Task.isCancelled else { return .cancelled }
        let finalInventory = await host.refreshInventoryAfterMutation()
        if finalInventory == nil, host.lastInventoryReadWasCancelled { return .cancelled }

        let priorState = alreadyRunning ? "was running" : "was launched"
        guard let finalInventory else {
            return .failed(changeDetail + "\(name) \(priorState), but TaskScope could not verify its final state.", .verificationUnavailable)
        }
        guard host.snapshot(for: preset, inventory: finalInventory).isMainRunning else {
            return .failed(changeDetail + "\(name) \(priorState), but its main process could not be verified.", .verificationUnavailable)
        }
        if reportsAlreadyRunning {
            return .completed(changeDetail + "\(name) is already running.")
        }
        return .completed(restored ? "Opened \(name) after restoring required services." : "Opened \(name).")
    }

    // MARK: - Allow to Run

    /// Clears the preset's Keep Off launchd overrides and its Keep Off intent
    /// without starting anything. Shows the report only when something changed
    /// or failed: verified, already-enabled jobs are not a restoration.
    private func clearKeepOffOverrides(
        _ preset: WatchedAppPreset,
        host: some PresetLifecycleHost,
        run: inout Run
    ) async -> LifecycleBatchResult {
        let systemEnable = preset.isBuiltInGlobalProtect
            ? await lifecycle.enableSystemLaunchDaemons(for: preset) : .notNeeded
        // Do not start restoring user jobs after a cancelled system request.
        let userEnable = systemEnable.succeeded
            ? await lifecycle.enableUserLaunchAgents(for: preset) : .notNeeded
        let enableResult = LifecycleBatchResult(jobs: systemEnable.jobs + userEnable.jobs)
        run.jobs += enableResult.jobs
        run.report = .replace(enableResult.didChangeState || !enableResult.succeeded
            ? LifecycleReport(title: "\(preset.displayName) Keep Off", jobs: enableResult.jobs)
            : nil)
        if enableResult.succeeded {
            host.dependencies.setPresetKeptOff(preset, false)
        }
        return enableResult
    }

    /// Turns Keep Off off without opening the app: clears the preset's launchd
    /// disable overrides and its Keep Off intent. Nothing is started.
    func allowToRun(_ preset: WatchedAppPreset, host: some PresetLifecycleHost) async -> PresetLifecycleOutcome {
        var run = Run()
        let enabled = await clearKeepOffOverrides(preset, host: host, run: &run)
        let name = preset.displayName
        let exit: Exit
        if enabled.succeeded {
            exit = .completed("\(name) is allowed to run. Nothing was started.")
        } else {
            let failure = enabled.failureSummary ?? "service could not be enabled"
            let systemFailed = enabled.jobs.contains {
                $0.label == WatchedAppPreset.globalProtectSystemDaemon.label && !$0.succeeded
            }
            exit = .failed(
                host.dependencies.isPresetKeptOff(preset)
                    ? "Keep Off remains requested: \(failure)."
                    : "Could not allow \(name) to run: \(failure).",
                systemFailed ? .systemServiceFailed : .userLaunchAgentFailed
            )
        }
        // Recorded as Open, as turning Keep Off off always has been.
        return outcome(of: exit, run: run, presetID: preset.id, action: .open, backgroundEnforcement: false)
    }

    // MARK: - Keep Off

    /// Persists intent and disables user jobs. An explicit built-in GlobalProtect
    /// action also disables/unloads the fixed system service with authorization;
    /// background enforcement only verifies it and never requests privileges.
    ///
    /// With `recordIntent == false` this is background enforcement. It re-checks
    /// the persisted intent *inside* the operation gate: a poll tick that decided
    /// to enforce can be queued behind a user's Open, which clears the intent, and
    /// running the enforcement afterwards would re-disable the agents the user
    /// just restored and quit the app they just opened.
    func keepOff(
        _ preset: WatchedAppPreset,
        recordIntent: Bool,
        confirmedFailureID: UUID?,
        host: some PresetLifecycleHost
    ) async -> PresetLifecycleOutcome {
        // Refusals before anything starts touch no bookkeeping.
        if let refusal = keepOffPreparationRefusal(preset, recordIntent: recordIntent, host: host) {
            return PresetLifecycleOutcome(result: TaskScopeCommandResult(status: .rejected, message: refusal), message: refusal)
        }
        if let confirmedFailureID {
            guard recordIntent, preset.isBuiltInGlobalProtect,
                  confirmedFailureID == globalProtectDisconnectFailureID else {
                let message = "This disconnect failure is no longer current. Choose Keep GlobalProtect Off again."
                return PresetLifecycleOutcome(result: TaskScopeCommandResult(status: .rejected, message: message), message: message)
            }
        }

        var run = Run()
        var report: LifecycleReport?
        var shouldPublishReport = false
        let exit = await keepOffSteps(
            preset, recordIntent: recordIntent, confirmedFailureID: confirmedFailureID, host: host,
            run: &run, report: &report, shouldPublishReport: &shouldPublishReport
        )

        if !recordIntent && (Task.isCancelled || exit == .cancelled) {
            return PresetLifecycleOutcome(result: TaskScopeCommandResult(
                status: .rejected, message: "Keep Off enforcement cancelled; it will retry on the next poll."
            ))
        }
        run.report = shouldPublishReport ? .replace(report) : .unchanged
        var outcome = outcome(of: exit, run: run, presetID: preset.id, action: .keepOff, backgroundEnforcement: !recordIntent)

        // Background enforcement runs on every poll: an identical failure is
        // reported once, until the preset is next kept off cleanly.
        let failure = BackgroundKeepOffFailure(message: outcome.result.message, jobs: run.jobs)
        let isDuplicate = !recordIntent && outcome.result.status == .failed
            && backgroundKeepOffFailures[preset.id] == failure
        if recordIntent || outcome.result.status == .completed {
            backgroundKeepOffFailures[preset.id] = nil
        } else if outcome.result.status == .failed {
            backgroundKeepOffFailures[preset.id] = failure
        }
        if isDuplicate {
            outcome.message = nil
            outcome.report = .unchanged
            outcome.diagnostic = nil
        }
        return outcome
    }

    /// Checked before disconnect and again afterwards: settings or the preset
    /// may change while the vendor UI is settling.
    private func keepOffPreparationRefusal(
        _ preset: WatchedAppPreset,
        recordIntent: Bool,
        host: some PresetLifecycleHost
    ) -> String? {
        guard recordIntent else { return nil }
        if !host.dependencies.isKeepOffIntentWritable() {
            return "Settings are unreadable. Reset settings in Settings → General before changing Keep Off."
        }
        let stored = host.dependencies.watchedPresets().first { $0.id == preset.id }
        if preset.isBuiltInGlobalProtect {
            guard stored?.isBuiltInGlobalProtect == true else {
                return "The built-in GlobalProtect preset was removed. Keep Off was not recorded and no services were disabled."
            }
        } else if stored != preset {
            // A queued Keep Off must not act on, or record intent for, a copy
            // the user has since edited or deleted.
            return "\(preset.displayName) was changed or removed. Keep Off was not recorded and nothing was stopped."
        }
        return nil
    }

    private func keepOffSteps(
        _ preset: WatchedAppPreset,
        recordIntent: Bool,
        confirmedFailureID: UUID?,
        host: some PresetLifecycleHost,
        run: inout Run,
        report: inout LifecycleReport?,
        shouldPublishReport: inout Bool
    ) async -> Exit {
        let name = preset.displayName
        guard recordIntent || !Task.isCancelled else { return .cancelled }
        if !recordIntent, !host.dependencies.isPresetKeptOff(preset) {
            return .rejected("Keep Off is no longer enabled for \(name); enforcement skipped.", publishesMessage: false)
        }

        if recordIntent && preset.isBuiltInGlobalProtect {
            globalProtectDisconnectFailureID = nil
            if confirmedFailureID == nil {
                host.showProgress("Disconnecting GlobalProtect before stopping its services…")
                if case .failed(let detail) = await lifecycle.disconnectGlobalProtectIfNeeded() {
                    globalProtectDisconnectFailureID = UUID()
                    globalProtectDisconnectGraceUntil = now().addingTimeInterval(Self.disconnectFailureGraceSeconds)
                    return .failed(detail, .disconnectFailed)
                }
            }
        }
        if let refusal = keepOffPreparationRefusal(preset, recordIntent: recordIntent, host: host) {
            return .rejected(refusal, publishesMessage: true)
        }
        // Record after a clean disconnect or separately confirmed recovery,
        // while holding the gate so polling cannot race the preparation.
        if recordIntent {
            host.dependencies.setPresetKeptOff(preset, true)
        }
        if recordIntent && preset.isBuiltInGlobalProtect {
            host.showProgress("Stopping GlobalProtect and its services…")
        }

        let inventoryWasAvailable: Bool
        switch await host.currentSnapshot(for: preset) {
        case .success:
            inventoryWasAvailable = true
        case .failure:
            inventoryWasAvailable = false
        }
        guard recordIntent || !Task.isCancelled else { return .cancelled }
        let userDisable = await lifecycle.disableUserLaunchAgents(for: preset, preservingVPNService: !recordIntent)
        guard recordIntent || !Task.isCancelled else { return .cancelled }
        let systemDisable = preset.isBuiltInGlobalProtect
            ? await lifecycle.disableSystemLaunchDaemons(for: preset, allowAdministratorPrompt: recordIntent)
            : .notNeeded
        guard recordIntent || !Task.isCancelled else { return .cancelled }
        let disableResult = LifecycleBatchResult(jobs: userDisable.jobs + systemDisable.jobs)
        run.jobs += disableResult.jobs
        // Background enforcement runs on every launch and poll tick; only a
        // failure is worth interrupting the user with a report sheet.
        if recordIntent || !disableResult.succeeded {
            shouldPublishReport = true
            report = disableResult.jobs.isEmpty
                ? nil
                : LifecycleReport(title: "\(name) Keep Off", jobs: disableResult.jobs)
        }

        guard inventoryWasAvailable else {
            return .failed(
                disableResult.succeeded
                    ? "Keep Off disabled relaunch jobs, but the process list was unavailable; running processes were not signalled and enforcement will retry."
                    : "Keep Off remains enabled, but TaskScope could neither verify processes nor disable relaunch jobs.",
                .inventoryUnavailable
            )
        }

        let terminationOutcomes = await lifecycle.terminateProcesses(for: preset, scope: .all)
        if recordIntent && preset.isBuiltInGlobalProtect {
            host.showProgress("Verifying GlobalProtect is off…")
        }
        await lifecycle.settleAfterProcessChange()
        let finalInventory = await host.refreshInventoryAfterMutation()
        guard recordIntent || !Task.isCancelled else { return .cancelled }
        let nowSnapshot = host.snapshot(for: preset, inventory: finalInventory ?? [])
        let serviceObservation = preset.isBuiltInGlobalProtect
            ? await host.dependencies.globalProtectServiceObservation() : nil
        guard recordIntent || !Task.isCancelled else { return .cancelled }

        if !disableResult.succeeded {
            return .failed(
                "Keep Off was requested, but stopping services failed: \(disableResult.failureSummary ?? "unknown failure").",
                systemDisable.succeeded ? .userLaunchAgentFailed : .systemServiceFailed
            )
        }
        if terminationOutcomes.contains(.inventoryUnavailable) {
            return .failed(
                "Keep Off disabled relaunch jobs, but the process list became unavailable before app processes could be stopped.",
                .inventoryUnavailable
            )
        }
        if terminationOutcomes.contains(.signalRejected) {
            return .failed("Keep Off disabled relaunch jobs, but a running process rejected the stop signal.", .signalRejected)
        }
        if terminationOutcomes.contains(.escalationUnavailable) || finalInventory == nil
            || serviceObservation?.session == .unknown || serviceObservation?.system == .unknown {
            return .failed("Keep Off is enabled, but TaskScope could not verify the final process state.", .verificationUnavailable)
        }
        if preset.isBuiltInGlobalProtect
            && (serviceObservation?.system == .running
                || (serviceObservation == nil && !nowSnapshot.protectedRunning.isEmpty)) {
            return .failed(
                "Keep Off was requested, but a privileged VPN service is still running. Check the service report and your organization's policy before retrying.",
                .stillRunning
            )
        }
        if recordIntent && serviceObservation?.session == .running {
            return .failed(
                "Keep Off was requested, but the login-session VPN service is still running. Choose Apply Keep Off to retry the session stop.",
                .stillRunning
            )
        }
        if nowSnapshot.hasBackgroundKeepOffTargets
            || (recordIntent && serviceObservation == nil && nowSnapshot.hasCurrentUserLaunchAgent) {
            let processes = preset.isBuiltInGlobalProtect ? "user-facing GlobalProtect processes" : "\(name) processes"
            return .failed("Keep Off is enabled, but \(processes) may still run.", .stillRunning)
        }
        if preset.isBuiltInGlobalProtect && !recordIntent
            && (serviceObservation?.session == .running
                || (serviceObservation == nil && nowSnapshot.hasCurrentUserLaunchAgent)) {
            return .completed("Keep Off disabled relaunch jobs. The running login-session VPN service was preserved; choose Apply Keep Off for a confirmed disconnect and stop.")
        }
        if preset.isBuiltInGlobalProtect {
            return .completed("GlobalProtect is off. Its user agents are disabled; the system VPN service is disabled or not installed. Choose Open to restore them without reinstalling.")
        }
        if !nowSnapshot.protectedRunning.isEmpty {
            return .completed("\(name) app is kept off. Protected system service remains available.")
        }
        if !nowSnapshot.unprivilegedProtectedRunning.isEmpty {
            let names = nowSnapshot.unprivilegedProtectedRunning.joined(separator: ", ")
            return .completed("\(name) is kept off. Its user launch agents are disabled; a per-user \(names) instance is still running and should exit as launchd finishes unloading it.")
        }
        if preset.lifecycleUserLaunchAgentJobs.isEmpty {
            return .completed("\(name) is kept off. TaskScope stops it whenever it finds it running.")
        }
        return .completed("\(name) is kept off. Its user launch agents are disabled.")
    }

    // MARK: - Background enforcement

    /// Enforces persisted Keep Off intent after startup and if a user-facing job
    /// is restored externally. The system disable override persists in launchd;
    /// polling never requests authorization or repeatedly fights a restored system
    /// service. Its running state stays visible with an explicit retry action.
    ///
    /// Enforcement never queues behind a user-initiated mutation: while one runs
    /// the user is changing exactly the state enforcement would act on, and the
    /// gated re-check inside Keep Off is the last line of defence for a tick
    /// that had already decided before the mutation started.
    ///
    /// A tick that has just applied fresh snapshots passes `usingFreshSnapshots`,
    /// so deciding whether enforcement is needed costs no second read. Keep Off
    /// still reads uncached inside the gate before it disables or signals.
    func enforceKeptOffPresets(force: Bool, usingFreshSnapshots: Bool, host: some PresetLifecycleHost) async {
        for preset in host.dependencies.keptOffPresets() {
            guard !host.isMutationActive else { continue }
            // A failed explicit disconnect sent the user to GlobalProtect to
            // answer its request, and enforcement would close that UI. Leave it
            // for a bounded time, or until the next explicit action clears the
            // failure.
            if preset.isBuiltInGlobalProtect,
               globalProtectDisconnectFailureID != nil,
               let graceUntil = globalProtectDisconnectGraceUntil,
               now() < graceUntil {
                continue
            }
            if !force {
                let current: WatchedAppSnapshot
                if usingFreshSnapshots, let fresh = host.snapshots.first(where: { $0.preset == preset }) {
                    current = fresh
                } else {
                    guard case .success(let fresh) = await host.currentSnapshot(for: preset) else { continue }
                    current = fresh
                }
                guard current.hasBackgroundKeepOffTargets else {
                    backgroundKeepOffFailures[preset.id] = nil
                    continue
                }
            }
            await host.enforceKeepOff(preset)
        }
    }

    // MARK: - Preset stops

    /// Quit App, Quit Helpers and Quit App and Helpers. They never disconnect
    /// the VPN, so for GlobalProtect they leave its session VPN service loaded;
    /// Keep Off and Quit All stop it only after a verified disconnect.
    func stop(_ preset: WatchedAppPreset, scope: PresetStopScope, host: some PresetLifecycleHost) async -> PresetLifecycleOutcome {
        let previousMessage = host.message
        host.showProgress(scope.progressMessage(for: preset))
        let initial = await host.currentSnapshot(for: preset)
        if case .failure(.cancelled) = initial {
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .rejected, message: "Stop for \(preset.displayName) was cancelled."),
                message: previousMessage
            )
        }
        var run = Run()
        let result: PresetStopResult
        if case .success(let before) = initial {
            let agentPreset = preset.stopScopeAgentPreset
            let agents: LifecycleBatchResult
            if scope == .helpers {
                // Unloading an agent running the main binary would also quit the app.
                agents = await lifecycle.unloadUserLaunchAgents(for: agentPreset, preservingPIDs: before.mainProcessPIDs)
            } else {
                agents = await lifecycle.unloadUserLaunchAgents(for: agentPreset)
            }
            run.jobs = agents.jobs
            run.report = .replace(agents.jobs.isEmpty
                ? nil
                : LifecycleReport(title: "\(preset.displayName) Relaunch Jobs", jobs: agents.jobs))
            let terminations = await lifecycle.terminateProcesses(for: preset, scope: scope)
            await lifecycle.settleAfterProcessChange()
            let finalInventory = await host.refreshInventoryAfterMutation()
            result = scope.result(
                before: before, after: host.snapshot(for: preset, inventory: finalInventory ?? []),
                terminations: terminations, agents: agents, refreshed: finalInventory != nil
            )
        } else {
            result = scope.inventoryFailure(for: preset)
        }
        let exit: Exit = result.failureReason.map { .failed(result.message, $0) } ?? .completed(result.message)
        return outcome(of: exit, run: run, presetID: preset.id, action: scope.diagnosticAction, backgroundEnforcement: false)
    }

    // MARK: - Restart

    /// Quit App and Helpers, then Open, as one action with one report. Offered
    /// for custom presets only: the built-in GlobalProtect preset's full stop is
    /// Quit All, whose disconnect and privileged steps a restart would repeat.
    func restart(_ preset: WatchedAppPreset, host: some PresetLifecycleHost) async -> PresetLifecycleOutcome {
        let name = preset.displayName
        guard !preset.isBuiltInGlobalProtect else {
            let message = "Restart is not offered for the built-in GlobalProtect preset. Use Quit All, then Open."
            return PresetLifecycleOutcome(result: TaskScopeCommandResult(status: .rejected, message: message), message: message)
        }
        // Restart's Open step turns Keep Off off. Checked inside the gate, so a
        // restart queued behind a Keep Off is refused too.
        guard !host.dependencies.isPresetKeptOff(preset) else {
            let message = "Restart is not available while Keep \(name) Off is on: restarting opens \(name), which turns Keep Off off. Turn Keep Off off first."
            return PresetLifecycleOutcome(result: TaskScopeCommandResult(status: .rejected, message: message), message: message)
        }
        let stopped = await stop(preset, scope: .all, host: host)
        guard stopped.result.status == .completed else {
            // The quit's own outcome, report and diagnostic; nothing is opened.
            var outcome = stopped
            if stopped.result.status == .failed {
                let message = "Could not restart \(name): \(stopped.result.message)"
                outcome.result = TaskScopeCommandResult(status: .failed, message: message)
                outcome.message = message
            }
            return outcome
        }
        host.showProgress("Opening \(name) again…")
        var opened = await open(preset, host: host)
        // One report for the whole restart: the relaunch jobs the quit unloaded
        // and the services Open restored.
        let jobs = Self.reportJobs(stopped.report) + Self.reportJobs(opened.report)
        opened.report = .replace(jobs.isEmpty ? nil : LifecycleReport(title: "\(name) Restart", jobs: jobs))
        switch opened.result.status {
        case .completed:
            let message = "Restarted \(name)."
            opened.result = TaskScopeCommandResult(status: .completed, message: message)
            opened.message = message
        case .failed:
            let message = "\(name) quit, but could not be opened again: \(opened.result.message)"
            opened.result = TaskScopeCommandResult(status: .failed, message: message)
            opened.message = message
        case .rejected:
            break
        }
        return opened
    }

    private static func reportJobs(_ change: PresetLifecycleOutcome.ReportChange) -> [LifecycleJobResult] {
        if case .replace(let report?) = change { return report.jobs }
        return []
    }

    // MARK: - The single exit

    /// Turns how an action ended into what ProcessManager publishes: the
    /// result, the status line, the report, and for a failure its diagnostic.
    private func outcome(
        of exit: Exit,
        run: Run,
        presetID: UUID,
        action: LifecycleDiagnosticFailure.Action,
        backgroundEnforcement: Bool
    ) -> PresetLifecycleOutcome {
        switch exit {
        case .completed(let message):
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .completed, message: message),
                message: message,
                report: run.report
            )
        case .failed(let message, let reason):
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .failed, message: message),
                message: message,
                report: run.report,
                diagnostic: PresetLifecycleOutcome.Diagnostic(
                    presetID: presetID, action: action, backgroundEnforcement: backgroundEnforcement,
                    reason: reason, jobs: run.jobs
                )
            )
        case .rejected(let message, let publishesMessage):
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .rejected, message: message),
                message: publishesMessage ? message : nil,
                report: run.report
            )
        case .cancelled:
            // The callers turn cancellation into their own result first.
            return PresetLifecycleOutcome(
                result: TaskScopeCommandResult(status: .rejected, message: "The action was cancelled."),
                report: run.report
            )
        }
    }
}
