import Foundation
@testable import TaskScope

/// Test-only conveniences that used to live in the production controller.
/// The runtime has no default: a test must inject a fake, so these helpers can
/// never reach real processes.
extension ProcessLifecycleController {
    @discardableResult
    static func terminateProcess(
        named name: String,
        forceIfStillRunning: Bool,
        expectedExecutableDirectory: String,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        runtime: ProcessLifecycleRuntime
    ) async -> ProcessTerminationOutcome {
        await ProcessTerminationController.terminate(
            named: name,
            policy: forceIfStillRunning ? .gracefulThenForce : .graceful,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: currentPID,
            runtime: runtime
        )
    }

    static func matchingProcesses(
        named name: String,
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        ProcessTerminationController.matchingProcesses(named: name, in: inventory)
    }

    static func terminationTargets(
        named name: String,
        expectedExecutableDirectory: String?,
        excludingPID: Int32,
        currentUID: uid_t = getuid(),
        in inventory: [AppProcess]
    ) -> [AppProcess] {
        ProcessTerminationController.terminationTargets(
            named: name,
            expectedExecutableDirectory: expectedExecutableDirectory,
            excludingPID: excludingPID,
            currentUID: currentUID,
            in: inventory
        )
    }
}
