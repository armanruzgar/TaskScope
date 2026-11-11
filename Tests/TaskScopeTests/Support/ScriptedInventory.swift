import Foundation
import XCTest
@testable import TaskScope

/// The process inventory for tests (L07-8, T01-15). Reads return the script in
/// order. A read past the script fails the test, unless the test asked for the
/// last result to repeat with `repeatsLast`, so a test also catches reads it did
/// not expect. Numbered reads can be held until the test releases them, to
/// interleave a read with other work deterministically.
final class ScriptedInventory: ProcessInventoryProviding, @unchecked Sendable {
    typealias Read = Result<[AppProcess], ProcessInventoryError>

    private let lock = NSLock()
    private var script: [Read]
    private var repeatsLast: Bool
    private var reads = 0
    private var extendedRequests: [Bool] = []
    private var heldReads: Set<Int>
    private var releasedReads: Set<Int> = []
    private var holds: [Int: CheckedContinuation<Void, Never>] = [:]
    private var readWaiters: [(read: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let file: StaticString
    private let line: UInt

    /// Reads return `script` in order. With `repeatsLast`, every read after the
    /// script returns its last entry; without it, such a read fails the test.
    /// Reads numbered in `holding` (counting from 1) wait for `release(read:)`.
    init(
        _ script: [Read],
        repeatsLast: Bool = false,
        holding heldReads: Set<Int> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.script = script
        self.repeatsLast = repeatsLast
        self.heldReads = heldReads
        self.file = file
        self.line = line
    }

    /// Every read returns `processes`.
    convenience init(processes: [AppProcess], file: StaticString = #filePath, line: UInt = #line) {
        self.init([.success(processes)], repeatsLast: true, file: file, line: line)
    }

    /// Every read fails with `error`.
    convenience init(failing error: ProcessInventoryError, file: StaticString = #filePath, line: UInt = #line) {
        self.init([.failure(error)], repeatsLast: true, file: file, line: line)
    }

    /// How many reads have started.
    var readCount: Int { lock.withLock { reads } }

    /// The `fetchExtendedStats` argument of each read, in order.
    var extendedStatsRequests: [Bool] { lock.withLock { extendedRequests } }

    /// Replaces the reads still to come.
    func script(_ reads: [Read], repeatsLast: Bool = false) {
        lock.withLock {
            script = reads
            self.repeatsLast = repeatsLast
        }
    }

    /// From now on every read returns `processes`.
    func setProcesses(_ processes: [AppProcess]) {
        script([.success(processes)], repeatsLast: true)
    }

    /// From now on every read fails with `error`.
    func fail(_ error: ProcessInventoryError) {
        script([.failure(error)], repeatsLast: true)
    }

    /// Holds the next read until `releaseHeldReads()` or `release(read:)`, and
    /// returns its number.
    @discardableResult
    func holdNextRead() -> Int {
        lock.withLock {
            heldReads.insert(reads + 1)
            return reads + 1
        }
    }

    /// Lets every held read that has started return, and stops holding reads
    /// that have not started yet.
    func releaseHeldReads() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            releasedReads.formUnion(heldReads)
            heldReads.removeAll()
            let waiting = Array(holds.values)
            holds.removeAll()
            return waiting
        }
        continuations.forEach { $0.resume() }
    }

    /// Holds read number `read` (counting from 1) until `release(read:)`.
    func hold(read: Int) {
        _ = lock.withLock { heldReads.insert(read) }
    }

    /// Returns once read number `read` (counting from 1) has started.
    func waitForRead(_ read: Int) async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock { () -> Bool in
                if reads >= read { return true }
                readWaiters.append((read, continuation))
                return false
            }
            if started { continuation.resume() }
        }
    }

    /// Lets held read number `read` return.
    func release(read: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            releasedReads.insert(read)
            return holds.removeValue(forKey: read)
        }
        continuation?.resume()
    }

    func load(fetchExtendedStats: Bool) async -> Read {
        let (number, result, waiters, held) = lock.withLock {
            () -> (Int, Read?, [CheckedContinuation<Void, Never>], Bool) in
            reads += 1
            extendedRequests.append(fetchExtendedStats)
            let result: Read?
            if !script.isEmpty, script.count > 1 || !repeatsLast {
                result = script.removeFirst()
            } else if repeatsLast, let last = script.last {
                result = last
            } else {
                result = nil
            }
            let ready = readWaiters.filter { $0.read <= reads }.map(\.continuation)
            readWaiters.removeAll { $0.read <= reads }
            return (reads, result, ready, heldReads.contains(reads) && !releasedReads.contains(reads))
        }
        waiters.forEach { $0.resume() }
        if held {
            await withCheckedContinuation { continuation in
                let released = lock.withLock { () -> Bool in
                    if releasedReads.contains(number) { return true }
                    holds[number] = continuation
                    return false
                }
                if released { continuation.resume() }
            }
        }
        guard let result else {
            XCTFail("Process inventory read \(number) was not scripted", file: file, line: line)
            return .failure(.commandFailed("The test did not script this process inventory read."))
        }
        return result
    }
}
