import Darwin
import Foundation

/// Shares a very recent read between non-destructive observers and joins identical
/// reads already in flight. Cache age and ordering use monotonic time, including
/// system sleep. Destructive identity checks use a separate uncached
/// provider so this optimization can never authorize a signal from cached data.
///
/// Only successful reads are cached, and a read is cached only if it *started*
/// no earlier than the read that produced the current cache entry, so a slow
/// read that finishes late can never replace a newer result. A cached read stays
/// fresh for `maximumAge` after it *completed*, so a slow read is still shared
/// with the next consumer.
///
/// A cancelled caller stops waiting at once and gets `.cancelled`. A shared read
/// is cancelled only when no caller waits for it any more, so a caller that
/// joined it is never failed by someone else's cancellation.
actor CoalescingProcessInventory: ProcessInventoryProviding {
    private struct CachedResult {
        var startedAt: TimeInterval
        var completedAt: TimeInterval
        var includesExtendedStats: Bool
        var processes: [AppProcess]
    }

    /// One upstream read and the callers waiting for it.
    private struct SharedRead {
        var task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Result<[AppProcess], ProcessInventoryError>, Never>]
        var startedAt: TimeInterval
        var generation: Int
        var includesExtendedStats: Bool
    }

    private let upstream: any ProcessInventoryProviding
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var cached: CachedResult?
    private var reads: [UUID: SharedRead] = [:]
    /// The reads a new caller may join. `invalidate()` detaches them; a detached
    /// read still answers the callers that were already waiting for it.
    private var joinableBasicRead: UUID?
    private var joinableExtendedRead: UUID?
    /// Advanced by `invalidate()`. A read that started under an older
    /// generation is neither cached nor joined by later callers.
    private var generation = 0

    /// Callers currently waiting for an upstream read.
    var waitingCallerCount: Int {
        reads.values.reduce(0) { $0 + $1.waiters.count }
    }

    init(
        upstream: any ProcessInventoryProviding = SystemProcessInventory(),
        maximumAge: TimeInterval = 0.5,
        now: @escaping @Sendable () -> TimeInterval = {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        }
    ) {
        self.upstream = upstream
        self.maximumAge = max(0, maximumAge)
        self.now = now
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        if let cached {
            let age = now() - cached.completedAt
            if age < 0 {
                // Defensively expire a discontinuous injected clock, including
                // in-flight reads that could otherwise restore the old epoch.
                invalidate()
            } else if age <= maximumAge,
                      cached.includesExtendedStats || !fetchExtendedStats {
                return .success(cached.processes)
            }
        }

        // An extended read also answers a basic request; a basic read never
        // answers an extended one.
        let readID = joinableExtendedRead ?? (fetchExtendedStats ? nil : joinableBasicRead) ?? UUID()
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                if reads[readID] != nil {
                    reads[readID]?.waiters[waiterID] = continuation
                    return
                }
                let task = Task { [upstream] in
                    let result = await upstream.load(fetchExtendedStats: fetchExtendedStats)
                    finish(readID, with: result)
                }
                reads[readID] = SharedRead(
                    task: task,
                    waiters: [waiterID: continuation],
                    startedAt: now(),
                    generation: generation,
                    includesExtendedStats: fetchExtendedStats
                )
                if fetchExtendedStats {
                    joinableExtendedRead = readID
                } else {
                    joinableBasicRead = readID
                }
            }
        } onCancel: {
            Task { await self.stopWaiting(waiterID, for: readID) }
        }
    }

    /// Discards the cached read and detaches in-flight reads after a mutation,
    /// so an observer cannot be served a list taken before a process was
    /// stopped or started.
    func invalidate() {
        generation &+= 1
        cached = nil
        joinableBasicRead = nil
        joinableExtendedRead = nil
    }

    private func stopWaiting(_ waiterID: UUID, for readID: UUID) {
        guard let waiter = reads[readID]?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: .failure(.cancelled))
        guard let read = reads[readID], read.waiters.isEmpty else { return }
        // Nobody waits for this read any more: stop it (and the commands it
        // runs) and let the next caller start a fresh one.
        reads[readID] = nil
        detach(readID)
        read.task.cancel()
    }

    private func finish(_ readID: UUID, with result: Result<[AppProcess], ProcessInventoryError>) {
        guard let read = reads.removeValue(forKey: readID) else { return }
        detach(readID)
        store(
            result,
            startedAt: read.startedAt,
            generation: read.generation,
            includesExtendedStats: read.includesExtendedStats
        )
        for waiter in read.waiters.values {
            waiter.resume(returning: result)
        }
    }

    private func detach(_ readID: UUID) {
        if joinableBasicRead == readID { joinableBasicRead = nil }
        if joinableExtendedRead == readID { joinableExtendedRead = nil }
    }

    private func store(
        _ result: Result<[AppProcess], ProcessInventoryError>,
        startedAt: TimeInterval,
        generation startedGeneration: Int,
        includesExtendedStats: Bool
    ) {
        guard startedGeneration == generation else { return }
        guard case .success(let processes) = result else { return }
        if let cached, cached.startedAt > startedAt { return }
        cached = CachedResult(
            startedAt: startedAt,
            completedAt: now(),
            includesExtendedStats: includesExtendedStats,
            processes: processes
        )
    }
}
