import ApplicationServices
import Foundation

struct SupportDiagnosticsCollector {
    var runtime: ProcessLifecycleRuntime = .live

    /// Inspects only the selected preset's configured user jobs. No inventory,
    /// privilege prompt, lifecycle mutation or log collection is performed.
    func inspectPreset(
        _ preset: WatchedAppPreset, keepOffRequested: Bool?
    ) async -> SupportDiagnosticsReport.Preset {
        var agents: [SupportDiagnosticsReport.LaunchAgent] = []
        for (index, job) in preset.lifecycleUserLaunchAgentJobs.enumerated() {
            let state: SupportDiagnosticsReport.LaunchAgent.State
            if Task.isCancelled {
                state = .unknown
            } else if !PresetFieldValidation.isValidLaunchAgentLabel(job.label) {
                // launchctl reads such a label as another service or as the whole
                // login domain, and would answer as if the job were loaded.
                state = .unknown
            } else {
                let result = await runtime.runCommand(
                    "/bin/launchctl print \(ShellCommandRunner.shellQuoted("gui/\(runtime.userID)/\(job.label)"))",
                    5
                )
                // Cancellation/timeouts cannot establish that a job is absent,
                // even if partial output contains a service-not-found message.
                if Task.isCancelled || result.terminatedBySignal != nil || result.exitCode < 0 {
                    state = .unknown
                } else {
                    switch ProcessLifecycleController.launchJobInspection(from: result, label: job.label) {
                    case .loaded: state = .loaded
                    case .notLoaded: state = .notLoaded
                    case .failed: state = .unknown
                    }
                }
            }
            agents.append(.init(
                number: index + 1, required: job.isRequired,
                plistFound: runtime.fileExists(job.plistPath), state: state
            ))
        }
        return .init(
            kind: preset.isBuiltInGlobalProtect ? .builtInGlobalProtect : .custom,
            appBundleFound: runtime.fileExists(preset.appPath),
            keepOffRequested: keepOffRequested, userLaunchAgents: agents
        )
    }

    @MainActor
    static func permissions(
        notificationsEnabled: Bool?,
        authorization: @MainActor () async -> NotificationService.AuthorizationState = {
            let service = NotificationService.shared
            await service.refreshAuthorizationStatus()
            return service.authorizationState
        },
        accessibility: @MainActor () -> Bool = { AXIsProcessTrusted() },
        loginState: @MainActor () -> LoginItemState = { SystemLoginItemService().state }
    ) async -> SupportDiagnosticsReport.Permissions {
        let authorizationState = await authorization()
        let notifications: SupportDiagnosticsReport.Permissions.Notification
        switch authorizationState {
        case .unknown: notifications = .unknown
        case .notDetermined: notifications = .notRequested
        case .denied: notifications = .denied
        case .authorized: notifications = .allowed
        case .provisional: notifications = .provisional
        }
        let login: SupportDiagnosticsReport.Permissions.LoginItem
        switch loginState() {
        case .notRegistered: login = .off
        case .enabled: login = .on
        case .requiresApproval: login = .requiresApproval
        case .notFound: login = .unavailable
        }
        return .init(
            notifications: notifications, notificationsEnabledInApp: notificationsEnabled,
            accessibilityGranted: accessibility(), launchAtLogin: login
        )
    }
}
