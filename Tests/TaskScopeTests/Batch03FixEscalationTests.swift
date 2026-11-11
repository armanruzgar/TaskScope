import Darwin
import XCTest
@testable import TaskScope

/// Drives the real preset termination path
/// (ProcessLifecycleController.terminateProcess -> ProcessTerminationController)
/// through an injected runtime. The "kernel" is a closure; nothing is signalled.
final class Batch03EscalationRecheckTests: XCTestCase {
    /// The survivor row in the refreshed inventory is unchanged (same pid, start
    /// time and inventory path, so the identity filter passes), but by the time
    /// SIGKILL would be sent its pid resolves to another binary (PID reuse or
    /// exec after the refreshed read).
    func testEscalationDoesNotSIGKILLAPIDThatNowResolvesToAnotherBinary() async {
        let recorder = Batch03SignalRecorder()
        let outcome = await terminate(recorder: recorder) { pid, signalled in
            signalled ? "/usr/libexec/unrelated-daemon" : "/Applications/Example.app/Contents/MacOS/Example"
        }
        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(recorder.signals.map(\.signal), [SIGTERM],
                       "SIGKILL was sent to a pid whose kernel path no longer matches")
    }

    func testEscalationDoesNotSIGKILLAPIDWhoseKernelPathNoLongerResolves() async {
        let recorder = Batch03SignalRecorder()
        let outcome = await terminate(recorder: recorder) { _, signalled in
            signalled ? nil : "/Applications/Example.app/Contents/MacOS/Example"
        }
        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(recorder.signals.map(\.signal), [SIGTERM])
    }

    /// Control: with the kernel path unchanged the survivor is force-stopped,
    /// so the two tests above fail only because of the path re-check.
    func testControlUnchangedKernelPathIsForceStopped() async {
        let recorder = Batch03SignalRecorder()
        let outcome = await terminate(recorder: recorder) { _, _ in
            "/Applications/Example.app/Contents/MacOS/Example"
        }
        XCTAssertEqual(outcome, .signalled)
        XCTAssertEqual(recorder.signals.map(\.signal), [SIGTERM, SIGKILL])
    }

    private func terminate(
        recorder: Batch03SignalRecorder,
        kernelPath: @escaping @Sendable (Int32, Bool) -> String?
    ) async -> ProcessTerminationOutcome {
        let target = AppProcess(
            pid: 4242, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0,
            command: "/Applications/Example.app/Contents/MacOS/Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            elapsedTime: "00:10", startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
        let runtime = ProcessLifecycleRuntime(
            userID: getuid(),
            fileExists: { _ in false },
            launchAgentLabel: { _ in nil },
            runCommand: { command, _ in
                ShellCommandResult(command: command, stdout: "", stderr: "fake", exitCode: 1)
            },
            // The target never exits and keeps its identity in every read.
            loadProcessInventory: { .success([target]) },
            executablePathForPID: { pid in kernelPath(pid, !recorder.isEmpty) },
            sendSignal: { signal, pid in recorder.append(signal, pid); return true },
            isProcessAlive: { _ in true },
            sleep: { _ in },
            systemUptime: { 0 }
        )
        return await ProcessLifecycleController.terminateProcess(
            named: "Example",
            policy: .gracefulThenForce,
            expectedExecutableDirectory: "/Applications/Example.app/Contents/MacOS/",
            currentPID: 999_999,
            runtime: runtime
        )
    }
}

final class Batch03SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(signal: Int32, pid: Int32)] = []
    func append(_ signal: Int32, _ pid: Int32) { lock.withLock { recorded.append((signal, pid)) } }
    var signals: [(signal: Int32, pid: Int32)] { lock.withLock { recorded } }
    var isEmpty: Bool { lock.withLock { recorded.isEmpty } }
}
