import Darwin
import Foundation
import XCTest
@testable import TaskScope

/// The process signaler for tests (T01-15). It records every signal it is
/// asked to send and answers per PID: delivered (the default), refused, or gone
/// before the signal arrived. A live PID can exit on SIGTERM or SIGKILL.
final class FakeSignaler: ProcessSignaling, @unchecked Sendable {
    struct Sent: Equatable {
        var signal: Int32
        var pid: Int32
    }

    private let lock = NSLock()
    private var alive: Set<Int32>
    private let everyPIDAlive: Bool
    private let exitsOnTerminate: Bool
    private let exitsOnKill: Bool
    private var rejected: [Int32: Int32]
    private let rejectingAll: Bool
    private let forbiddenReason: String?
    private let file: StaticString
    private let line: UInt
    private var missing: Set<Int32>
    private var exited: Set<Int32> = []
    private var sentSignals: [Sent] = []
    private var fixedAnswer: ProcessSignalDelivery?

    /// - Parameters:
    ///   - alive: PIDs `isAlive` reports alive, unless `everyPIDAlive`.
    ///   - everyPIDAlive: `isAlive` is true for every PID that has not exited.
    ///   - exitsOnTerminate: a delivered SIGTERM ends the target; `isAlive` is
    ///     false afterwards, while later signals are still reported delivered.
    ///   - exitsOnKill: the same for SIGKILL.
    ///   - rejected: PIDs whose signals the kernel refuses with `EPERM`.
    ///   - rejectingAll: the kernel refuses every signal with `EPERM`.
    ///   - missing: PIDs that no longer exist when signalled (`ESRCH`).
    init(
        alive: Set<Int32> = [],
        everyPIDAlive: Bool = false,
        exitsOnTerminate: Bool = false,
        exitsOnKill: Bool = false,
        rejected: Set<Int32> = [],
        rejectingAll: Bool = false,
        missing: Set<Int32> = [],
        forbiddenReason: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.alive = alive
        self.everyPIDAlive = everyPIDAlive
        self.exitsOnTerminate = exitsOnTerminate
        self.exitsOnKill = exitsOnKill
        self.rejected = Dictionary(uniqueKeysWithValues: rejected.map { ($0, EPERM) })
        self.rejectingAll = rejectingAll
        self.forbiddenReason = forbiddenReason
        self.file = file
        self.line = line
        self.missing = missing
    }

    /// A signaler for tests that must send no signal: each request fails the
    /// test with `reason` and is refused.
    static func forbidding(
        _ reason: String = "No process may be signalled",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FakeSignaler {
        FakeSignaler(forbiddenReason: reason, file: file, line: line)
    }

    /// Every signal asked for, in order, including refused ones.
    var sent: [Sent] { lock.withLock { sentSignals } }

    /// When set, every signal gets this answer, whatever its PID.
    var answer: ProcessSignalDelivery? {
        get { lock.withLock { fixedAnswer } }
        set { lock.withLock { fixedAnswer = newValue } }
    }

    /// Refuses signals to `pid` with `errno`.
    func reject(_ pid: Int32, errno: Int32 = EPERM) {
        lock.withLock { rejected[pid] = errno }
    }

    /// Marks `pid` alive or exited.
    func setAlive(_ pid: Int32, _ isAlive: Bool) {
        lock.withLock {
            if isAlive {
                alive.insert(pid)
                exited.remove(pid)
            } else {
                alive.remove(pid)
                exited.insert(pid)
            }
        }
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        deliver(signal, to: pid) == .delivered
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        if let forbiddenReason {
            XCTFail("\(forbiddenReason): signal \(signal) to PID \(pid)", file: file, line: line)
        }
        return lock.withLock {
            sentSignals.append(Sent(signal: signal, pid: pid))
            if let fixedAnswer { return fixedAnswer }
            if missing.contains(pid) { return .noSuchProcess }
            if let errno = rejected[pid] { return .rejected(errno: errno) }
            if rejectingAll || forbiddenReason != nil { return .rejected(errno: EPERM) }
            if (signal == SIGTERM && exitsOnTerminate) || (signal == SIGKILL && exitsOnKill) {
                alive.remove(pid)
                exited.insert(pid)
            }
            return .delivered
        }
    }

    func isAlive(_ pid: Int32) -> Bool {
        lock.withLock {
            guard !missing.contains(pid), !exited.contains(pid) else { return false }
            return everyPIDAlive || alive.contains(pid)
        }
    }
}
