import Darwin
import Foundation
import XCTest
@testable import TaskScope

/// DarwinProcessSignaler's reading of `kill(2)` through an injected call. The
/// injected call only records, and every case uses the null signal, so nothing
/// is ever sent; the controlled-child tests in ProcessSignalIntegrationTests
/// cover the real system call.
final class Batch03DarwinSignalerTests: XCTestCase {
    private final class KillLog: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [Int32] = []
        var calls: [Int32] { lock.withLock { pids } }
        func record(_ pid: Int32) { lock.withLock { pids.append(pid) } }
    }

    func testDeliveryMapsTheKernelAnswer() {
        let answers: [(answer: (Int32, Int32), delivery: ProcessSignalDelivery)] = [
            ((0, 0), .delivered),
            ((-1, ESRCH), .noSuchProcess),
            ((-1, EPERM), .rejected(errno: EPERM)),
            ((-1, EINVAL), .rejected(errno: EINVAL))
        ]
        for (answer, delivery) in answers {
            let signaler = DarwinProcessSignaler(kill: { _, _ in answer })
            XCTAssertEqual(signaler.deliver(0, to: 4242), delivery)
            XCTAssertEqual(signaler.send(0, to: 4242), delivery == .delivered)
        }
    }

    /// `kill(pid, 0)` failing with EPERM means the process exists but belongs
    /// to someone else, so it is alive. The test's own pid is used because the
    /// zombie check reads that pid's real kernel state; it is never signalled.
    func testLivenessTreatsPermissionDeniedAsAlive() {
        let pid = getpid()
        XCTAssertTrue(DarwinProcessSignaler(kill: { _, _ in (0, 0) }).isAlive(pid))
        XCTAssertTrue(DarwinProcessSignaler(kill: { _, _ in (-1, EPERM) }).isAlive(pid))
        XCTAssertFalse(DarwinProcessSignaler(kill: { _, _ in (-1, ESRCH) }).isAlive(pid))
    }

    func testPIDGuardRunsBeforeTheKernelCall() {
        let log = KillLog()
        let signaler = DarwinProcessSignaler(kill: { pid, _ in
            log.record(pid)
            return (0, 0)
        })
        for pid: Int32 in [1, 0, -1] {
            XCTAssertEqual(signaler.deliver(0, to: pid), .rejected(errno: EINVAL))
            XCTAssertFalse(signaler.isAlive(pid))
        }
        XCTAssertTrue(log.calls.isEmpty)
    }
}
