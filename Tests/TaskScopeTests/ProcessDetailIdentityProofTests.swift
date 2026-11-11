import Darwin
import Foundation
import XCTest
@testable import TaskScope

/// Integration coverage for the live `ps` detail reader and its PID-reuse guard.
@MainActor
final class ProcessDetailIdentityProofTests: XCTestCase {
    func testDetailRejectsStaleRowWhoseIdentityNoLongerOwnsThePID() async throws {
        // A real process that genuinely owns the PID under test. It plays the role
        // of the *new* occupant after PID reuse.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do sleep 0.05; done"]
        try child.run()
        let recycledPID = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(recycledPID, SIGKILL)
                child.waitUntilExit()
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        // The row the user is still looking at, captured while `recycledPID` belonged
        // to Xcode. `AppProcess.startTime` and the detail reader both use the same
        // `ps lstart` field, so the values are directly comparable.
        let staleRow = AppProcess.fixture(
            pid: recycledPID,
            parentPID: 1,
            cpu: 12.5,
            memoryMB: 1_024,
            command: "Xcode",
            elapsedTime: "01:00",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )

        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler(rejectingAll: true),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false

        // Positive control: the very same PID, read with the identity the live
        // process actually has, must still resolve. This proves the nil below comes
        // from the identity check and not from `ps` failing or the parser breaking.
        let liveDetail = await manager.detail(for: matchingRow(for: recycledPID))
        XCTAssertNotNil(
            liveDetail,
            "Precondition: /bin/ps must resolve live PID \(recycledPID) for a matching identity."
        )
        XCTAssertEqual(liveDetail?.command, "/bin/sh")

        // The recycled-PID case: `terminate(_:forceKill:)` rejects exactly this
        // state with `.stale`, and `detail(for:)` now applies the same rule instead
        // of pairing a stale Name with a fresh Command/User/Started in the sheet.
        let detail = await manager.detail(for: staleRow)
        XCTAssertNil(
            detail,
            """
            detail(for:) accepted a row whose identity no longer owns PID \(recycledPID); \
            ProcessDetailSheet would have shown Name "\(staleRow.name)" beside \
            Command "\(detail?.command ?? "-")" from a different process.
            """
        )
    }

    /// Builds a row whose identity matches whatever currently owns `pid`, by reading
    /// the same `ps lstart` field the inventory uses.
    private func matchingRow(for pid: Int32) async -> AppProcess {
        let read = await ShellCommandRunner.run(executable: "/bin/ps", arguments: ["-o", "lstart=", "-p", "\(pid)"])
        // `ps` pads a single-digit day ("Aug  6"). Both `ProcessListReader` and
        // `detail(for:)` normalise by splitting on whitespace and rejoining with one
        // space, so the identity must be built the same way to be comparable.
        let lstart = read.stdout
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AppProcess.fixture(
            pid: pid,
            parentPID: 1,
            cpu: 0,
            memoryMB: 0,
            command: "sh",
            elapsedTime: "00:01",
            startTime: lstart,
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}
