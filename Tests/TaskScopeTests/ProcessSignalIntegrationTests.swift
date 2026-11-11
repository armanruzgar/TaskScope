import Darwin
import Foundation
import XCTest
@testable import TaskScope

@MainActor
final class ProcessSignalIntegrationTests: XCTestCase {
    func testGracefulStopLetsControlledChildExitWithoutSIGKILL() async throws {
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-signal-ready-\(UUID().uuidString)")
        // Written by the child's own TERM handler, so it proves the stop was a
        // delivered SIGTERM that the child handled, not a kill.
        let handledMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-signal-handled-\(UUID().uuidString)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            "trap '/usr/bin/touch \(ShellCommandRunner.shellQuoted(handledMarker.path)); sleep 1; exit 0' TERM; /usr/bin/touch \(ShellCommandRunner.shellQuoted(readyMarker.path)); while :; do sleep 0.05; done"
        ]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: readyMarker)
            try? FileManager.default.removeItem(at: handledMarker)
        }

        guard try await waitForMarker(readyMarker) else {
            XCTFail("Controlled child did not report that its TERM handler was ready.")
            return
        }

        let target = AppProcess(
            pid: pid,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            cpu: 0,
            memoryMB: 0,
            command: "/tmp/TaskScope Controlled Child",
            elapsedTime: "00:01",
            startTime: "controlled-child-\(pid)",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
        let signaler = RecordingDarwinSignaler()
        let manager = ProcessManager(
            processInventory: FixedProcessInventory(processes: [target]),
            processSignaler: signaler,
            settleAfterProcessChange: {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            },
            dependencies: .inert
        )
        manager.enableNotifications = false

        let result = await manager.terminate(target)

        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(signaler.sentSignals, [SIGTERM])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: handledMarker.path),
            "the child's TERM handler did not run"
        )
        XCTAssertFalse(child.isRunning)
    }

    /// An invalid signal number is refused by the kernel before anything is
    /// delivered, so this exercises the real `kill(2)` errno path on the
    /// test's own child without signalling it.
    func testKernelRejectionKeepsItsErrno() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
        }

        XCTAssertEqual(DarwinProcessSignaler().deliver(NSIG + 1, to: pid), .rejected(errno: EINVAL))
        XCTAssertFalse(DarwinProcessSignaler().send(NSIG + 1, to: pid))
        XCTAssertTrue(DarwinProcessSignaler().isAlive(pid))
        XCTAssertTrue(child.isRunning)
    }

    /// `kill(pid, 0)` still succeeds for a zombie, which has already exited and
    /// only awaits `waitpid`. Liveness must consult the kernel state.
    func testZombieIsNotReportedAlive() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil), 0)
        defer {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        var isZombie = false
        for _ in 0..<400 where !isZombie {
            isZombie = ProcessSignalGuard.isZombie(pid)
            if !isZombie { usleep(5_000) }
        }
        XCTAssertTrue(isZombie, "precondition: the child became a zombie")
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "precondition: kill(pid, 0) succeeds for a zombie")

        XCTAssertFalse(DarwinProcessSignaler().isAlive(pid))
    }

    /// Signal 0 is harmless, so the guard can be exercised against the real
    /// kernel: `kill(0, 0)` would succeed, and pid 1 exists, if they were not
    /// refused before the call.
    func testSignalGuardRefusesProcessGroupAndLaunchdPIDs() {
        let signaler = DarwinProcessSignaler()

        XCTAssertEqual(signaler.deliver(0, to: 0), .rejected(errno: EINVAL))
        XCTAssertFalse(signaler.send(0, to: 1))
        XCTAssertFalse(signaler.send(0, to: -1))
        XCTAssertFalse(signaler.isAlive(0))
        XCTAssertFalse(signaler.isAlive(1))
    }

    func testDeliveryDistinguishesAVanishedProcessFromARejectedSignal() throws {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil), 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)

        XCTAssertEqual(DarwinProcessSignaler().deliver(0, to: pid), .noSuchProcess)
        XCTAssertEqual(DarwinProcessSignaler().deliver(0, to: 1), .rejected(errno: EINVAL))
    }

    private func waitForMarker(_ marker: URL) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return FileManager.default.fileExists(atPath: marker.path)
    }
}

private struct FixedProcessInventory: ProcessInventoryProviding {
    var processes: [AppProcess]

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private final class RecordingDarwinSignaler: ProcessSignaling {
    private let lock = NSLock()
    private var signals: [Int32] = []

    var sentSignals: [Int32] {
        lock.withLock { signals }
    }

    func send(_ signal: Int32, to pid: Int32) -> Bool {
        deliver(signal, to: pid) == .delivered
    }

    func deliver(_ signal: Int32, to pid: Int32) -> ProcessSignalDelivery {
        lock.withLock { signals.append(signal) }
        return DarwinProcessSignaler().deliver(signal, to: pid)
    }

    func isAlive(_ pid: Int32) -> Bool {
        DarwinProcessSignaler().isAlive(pid)
    }
}
