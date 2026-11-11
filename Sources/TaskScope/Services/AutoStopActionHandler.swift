import Foundation

/// Builds the closure the auto-stop engine calls to stop a process. This is the
/// production wiring; tests drive it too so the authority check the engine
/// relies on immediately before `kill(2)` is exercised end to end.
@MainActor
enum AutoStopActionHandlerFactory {
    static func make(
        processManager: ProcessManager,
        rules: AutoStopRulesStore
    ) -> AutoStopActionHandler {
        { [weak rules] rule, process, kind in
            await processManager.terminate(
                process,
                isAuthorized: {
                    rules?.authorizes(rule, kind: kind) ?? false
                }
            )
        }
    }
}
