import Combine
import Foundation

/// Serializes process reads and mutations without knowing how those operations
/// are implemented. Mutations take priority over queued reads, while equivalent
/// reads are coalesced so polling cannot build up obsolete work.
@MainActor
final class ProcessOperationGate: ObservableObject {
    enum Read: Equatable {
        case watchedStatus
        case processList
    }

    enum Kind: Equatable {
        case read(Read)
        case mutation

        fileprivate var isMutation: Bool {
            self == .mutation
        }
    }

    @Published private(set) var state: ProcessOperationState = .idle
    @Published private(set) var isWorking = false

    private struct Waiter {
        var id: UUID
        var operationID: UUID
        var kind: Kind
        var continuation: CheckedContinuation<Bool, Never>
    }

    private struct ActiveOperation {
        var id: UUID
        var kind: Kind
    }

    private struct Joiner {
        var id: UUID
        var operationID: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var activeOperation: ActiveOperation?
    private var waiters: [Waiter] = []
    private var joiners: [Joiner] = []

    /// True while a mutation holds the gate. Unlike `state`, which shows the most
    /// recent queue activity, this is not overwritten when another caller queues
    /// or joins behind the running mutation.
    var isMutationActive: Bool {
        activeOperation?.kind.isMutation == true
    }

    /// `reportsProgress: false` keeps `isWorking` down for a read nobody is
    /// waiting on, such as a silent background poll, so the footer keeps its
    /// last result. Mutations always report progress.
    @discardableResult
    func run(
        kind: Kind,
        reportsProgress: Bool = true,
        _ operation: () async -> Void
    ) async -> Bool {
        guard await acquire(for: kind) else {
            return false
        }
        guard !Task.isCancelled else {
            release(completed: false)
            return false
        }

        isWorking = kind.isMutation || reportsProgress
        state = kind.isMutation ? .runningMutation : .runningRefresh
        defer {
            isWorking = false
            // An owner cancelled mid-run may not have published a result, so
            // its joiners must retry with their own work instead of treating
            // the read as delivered.
            release(completed: !Task.isCancelled)
        }

        await operation()
        return true
    }

    private func acquire(for kind: Kind) async -> Bool {
        while !Task.isCancelled {
            if activeOperation == nil {
                activeOperation = ActiveOperation(id: UUID(), kind: kind)
                return true
            }

            if case .read(let requestedRead) = kind {
                if let activeOperation,
                   activeOperation.kind == .read(requestedRead) {
                    let completed = await join(operationID: activeOperation.id)
                    if completed || Task.isCancelled {
                        return false
                    }
                    continue
                }
                if let queued = waiters.first(where: { $0.kind == .read(requestedRead) }) {
                    let completed = await join(operationID: queued.operationID)
                    if completed || Task.isCancelled {
                        return false
                    }
                    continue
                }
            }

            return await enqueue(kind: kind)
        }

        return false
    }

    private func enqueue(kind: Kind) async -> Bool {
        let waiterID = UUID()
        let operationID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(
                    Waiter(
                        id: waiterID,
                        operationID: operationID,
                        kind: kind,
                        continuation: continuation
                    )
                )
                state = .queued
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    /// Waits for an equivalent read to publish its result without executing a
    /// duplicate closure. `false` means the owner was cancelled, either while
    /// queued or mid-run, in which case `acquire` retries using this caller's
    /// work (unless this caller was itself cancelled).
    private func join(operationID: UUID) async -> Bool {
        let joinerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                joiners.append(
                    Joiner(
                        id: joinerID,
                        operationID: operationID,
                        continuation: continuation
                    )
                )
                state = .coalesced
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelJoiner(id: joinerID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        completeJoiners(for: waiter.operationID, completed: false)
        updateWaitingState()
    }

    private func cancelJoiner(id: UUID) {
        guard let index = joiners.firstIndex(where: { $0.id == id }) else {
            return
        }
        let joiner = joiners.remove(at: index)
        joiner.continuation.resume(returning: false)
        updateWaitingState()
    }

    private func release(completed: Bool) {
        if let activeOperation {
            completeJoiners(for: activeOperation.id, completed: completed)
        }
        if waiters.isEmpty {
            activeOperation = nil
            state = .idle
        } else {
            let nextIndex = waiters.firstIndex { $0.kind.isMutation } ?? 0
            let next = waiters.remove(at: nextIndex)
            activeOperation = ActiveOperation(id: next.operationID, kind: next.kind)
            next.continuation.resume(returning: true)
        }
    }

    private func completeJoiners(for operationID: UUID, completed: Bool) {
        let completedJoiners = joiners.filter { $0.operationID == operationID }
        joiners.removeAll { $0.operationID == operationID }
        completedJoiners.forEach { $0.continuation.resume(returning: completed) }
    }

    private func updateWaitingState() {
        if !joiners.isEmpty {
            state = .coalesced
        } else if !waiters.isEmpty {
            state = .queued
        } else if let activeOperation {
            state = activeOperation.kind.isMutation
                ? .runningMutation
                : .runningRefresh
        } else {
            state = .idle
        }
    }
}
