import AppKit
import Foundation

enum TaskScopeCommand: Equatable, Sendable {
    case refresh
    case openPresetEntity(WatchedPresetCommandTarget)
    case stopPresetEntity(WatchedPresetCommandTarget)
}

struct WatchedPresetCommandTarget: Equatable, Sendable {
    var id: UUID
    var displayName: String
}

struct TaskScopeCommandResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case completed
        case rejected
        case failed
    }

    var status: Status
    var message: String

    var succeeded: Bool {
        status == .completed
    }
}

@MainActor
final class AppCommandCoordinator {
    private let processManager: ProcessManager
    private let presets: () -> [WatchedAppPreset]
    private let allowsCommands: () -> Bool

    init(
        processManager: ProcessManager,
        presets: @escaping () -> [WatchedAppPreset],
        allowsCommands: @escaping () -> Bool = { true }
    ) {
        self.processManager = processManager
        self.presets = presets
        self.allowsCommands = allowsCommands
    }

    static let startupVerificationRejection = TaskScopeCommandResult(
        status: .rejected,
        message: "Commands are disabled during startup verification."
    )

    func perform(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        guard allowsCommands() else {
            return Self.startupVerificationRejection
        }

        switch command {
        case .refresh:
            // Any successful read clears inventory errors, but only this refresh
            // or the equivalent read it joins determines this command's result.
            let refreshed = await processManager.refreshWatchedStatus(showMessage: true)
            if Task.isCancelled || processManager.lastInventoryReadWasCancelled {
                return TaskScopeCommandResult(status: .rejected, message: "Refresh was cancelled.")
            }
            return TaskScopeCommandResult(
                status: refreshed ? .completed : .failed,
                message: processManager.message
            )

        case .openPresetEntity(let target):
            guard let preset = preset(id: target.id) else {
                return missingPresetResult(target.displayName)
            }
            return await processManager.openApp(preset)

        case .stopPresetEntity(let target):
            guard let preset = preset(id: target.id) else {
                return missingPresetResult(target.displayName)
            }
            return await processManager.quitAllKillable(preset)

        }
    }

    private func preset(id: UUID) -> WatchedAppPreset? {
        presets().first { $0.id == id }
    }

    private func missingPresetResult(_ name: String) -> TaskScopeCommandResult {
        TaskScopeCommandResult(
            status: .rejected,
            message: "No watched-app preset matches “\(name)”."
        )
    }

}

@MainActor
final class AppCommandBus {
    static let shared = AppCommandBus()

    private typealias Handler = @MainActor @Sendable (TaskScopeCommand) async -> TaskScopeCommandResult

    private struct PendingCommand {
        var id: UUID
        var continuation: CheckedContinuation<Handler?, Never>?
    }

    private var handler: Handler?
    private var pending: [PendingCommand] = []
    private var activeCommandID: UUID?

    private var receivedIntent = false
    var onIntentExecution: (() -> Void)? {
        didSet {
            if receivedIntent { onIntentExecution?() }
        }
    }

    init() {}

    func prepareForIntentExecution() {
        receivedIntent = true
        onIntentExecution?()
    }

    func install(
        handler: @escaping @MainActor @Sendable (TaskScopeCommand) async -> TaskScopeCommandResult
    ) {
        self.handler = handler
        startNextIfNeeded()
    }

    func submit(_ command: TaskScopeCommand) async -> TaskScopeCommandResult {
        // Each command owns its task so cancellation reaches the handler and
        // any mutation gate it is waiting for, without cancelling its neighbors.
        let id = UUID()
        // Reserve submission order before scheduling the execution task.
        pending.append(PendingCommand(id: id))
        let execution = Task { @MainActor in
            guard let handler = await waitForTurn(id: id) else {
                return Self.cancelledResult
            }
            defer {
                activeCommandID = nil
                startNextIfNeeded()
            }
            // Admission and cancellation can race. The task's cancellation bit
            // is set synchronously even if queue cleanup has not run yet.
            guard !Task.isCancelled else { return Self.cancelledResult }
            return await handler(command)
        }
        return await withTaskCancellationHandler {
            await execution.value
        } onCancel: {
            execution.cancel()
        }
    }

    private static var cancelledResult: TaskScopeCommandResult {
        TaskScopeCommandResult(status: .rejected, message: "Command cancelled before execution.")
    }

    private func waitForTurn(id: UUID) async -> Handler? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    cancelPending(id: id)
                    continuation.resume(returning: nil)
                    return
                }
                guard let index = pending.firstIndex(where: { $0.id == id }) else {
                    continuation.resume(returning: nil)
                    return
                }
                pending[index].continuation = continuation
                startNextIfNeeded()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(id: id)
            }
        }
    }

    private func cancelPending(id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation?.resume(returning: nil)
        startNextIfNeeded()
    }

    private func startNextIfNeeded() {
        guard let handler, activeCommandID == nil,
              let continuation = pending.first?.continuation else { return }
        let item = pending.removeFirst()
        activeCommandID = item.id
        continuation.resume(returning: handler)
    }
}
