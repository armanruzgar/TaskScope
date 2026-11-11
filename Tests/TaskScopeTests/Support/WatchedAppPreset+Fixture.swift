import Foundation
@testable import TaskScope

extension WatchedAppPreset {
    /// A custom preset for tests: `<name>.app` in /Applications with one helper
    /// called `<name>Helper`, no protected processes and no launchd jobs.
    static func fixture(
        id: UUID = UUID(),
        name: String = "Example",
        helperProcessNames: [String]? = nil,
        protectedProcessNames: [String] = [],
        appPath: String? = nil,
        userLaunchAgentJobs: [UserLaunchAgentJob] = [],
        systemLaunchDaemonJobs: [SystemLaunchDaemonJob] = []
    ) -> WatchedAppPreset {
        WatchedAppPreset(
            id: id,
            displayName: name,
            mainProcessName: name,
            helperProcessNames: helperProcessNames ?? ["\(name)Helper"],
            protectedProcessNames: protectedProcessNames,
            appPath: appPath ?? "/Applications/\(name).app",
            userLaunchAgentJobs: userLaunchAgentJobs,
            systemLaunchDaemonJobs: systemLaunchDaemonJobs
        )
    }
}
