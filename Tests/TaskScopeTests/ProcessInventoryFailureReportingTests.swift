import Darwin
import XCTest
@testable import TaskScope

/// Proof tests for the "inventory read failure is reported as a claim about the
/// target processes" defects (P5: `terminate`, P6: `batchTerminate`).
///
/// Both tests drive the same seam the existing `ProcessManagerTests` use: a fake
/// `ProcessInventoryProviding` whose first `load` succeeds (so a selection can be
/// built) and whose subsequent loads return `.failure` — i.e. `ps` exited
/// non-zero / hit the ShellCommandRunner timeout / `/bin/zsh` could not spawn.
@MainActor
final class ProcessInventoryFailureReportingTests: XCTestCase {
    // MARK: - P5

    func testTerminateWithUnreadableInventoryMustNotWipeSelectionOrClaimIdentityChanged() async {
        let target = process(pid: 40, name: "Target")
        let bystanderA = process(pid: 41, name: "BystanderA")
        let bystanderB = process(pid: 42, name: "BystanderB")
        let inventory = ScriptedInventory(
            [
                .success([target, bystanderA, bystanderB]),
                .failure(.commandFailed("ps timed out"))
            ]
        , repeatsLast: true)
        let signaler = FakeSignaler(alive: [40, 41, 42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.loadProcessList()
        manager.select(manager.displayProcesses())
        XCTAssertEqual(manager.selectedPids, [40, 41, 42], "precondition: three processes selected")

        let result = await manager.terminate(target)

        // (a) Control — the read failed, so nothing may be signalled.
        XCTAssertTrue(
            signaler.sent.isEmpty,
            "no signal may be sent when the verification read failed"
        )

        // (b) The bystanders were never checked against anything, so their
        //     selection must survive an inventory read failure.
        XCTAssertEqual(
            manager.selectedPids.intersection([41, 42]),
            [41, 42],
            "an unreadable inventory must not wipe the selection of unrelated processes"
        )

        // (c) The user must not be told the target's identity changed: it was
        //     never compared against anything.
        XCTAssertEqual(
            manager.message,
            "Could not verify Target; nothing was stopped.",
            "an unreadable inventory must not be reported as an identity change"
        )

        // (d) A failed read must raise the load-failure indicator.
        XCTAssertEqual(
            manager.processLoadError,
            "ps timed out",
            "an unreadable inventory must surface as processLoadError"
        )

        // (e) An unreadable inventory is retryable; it proves neither exit nor
        //     a changed identity.
        XCTAssertEqual(
            result,
            .rejected,
            "a read failure must be reported to callers as an unverified target"
        )
    }

    // MARK: - P6

    func testBatchStopWithUnreadableInventoryMustNotReportEveryTargetAsNoLongerMatched() async {
        let first = process(pid: 40, name: "First")
        let second = process(pid: 41, name: "Second")
        let third = process(pid: 42, name: "Third")
        let inventory = ScriptedInventory(
            [
                .success([first, second, third]),
                .failure(.commandFailed("ps timed out"))
            ]
        , repeatsLast: true)
        let signaler = FakeSignaler(alive: [40, 41, 42])
        let manager = makeManager(inventory: inventory, signaler: signaler)

        await manager.loadProcessList()
        manager.select(manager.displayProcesses())
        let targets = manager.selectionSnapshot()
        XCTAssertEqual(targets.count, 3, "precondition: three targets requested")

        await manager.batchTerminate(targets)

        // Controls — nothing signalled, and the summary line is honest.
        XCTAssertTrue(
            signaler.sent.isEmpty,
            "no signal may be sent when the pre-flight read failed"
        )
        XCTAssertEqual(
            manager.message,
            "Could not verify selected processes.",
            "summary line correctly reports the read failure"
        )

        // Every captured target remains unverified when nothing was checked.
        let labels = manager.batchActionReport?.targets.map(\.state.label) ?? []
        XCTAssertEqual(
            labels,
            Array(repeating: ProcessTargetActionState.unverified.label, count: targets.count),
            "every target must remain unverified when the inventory read failed"
        )
    }

    // MARK: - Fixtures

    private func makeManager(
        inventory: any ProcessInventoryProviding,
        signaler: FakeSignaler = FakeSignaler(),
        lifecycle: any ProcessLifecycleServicing = FakeLifecycle()
    ) -> ProcessManager {
        let manager = ProcessManager(
            processInventory: inventory,
            verificationInventory: inventory,
            processSignaler: signaler,
            lifecycle: lifecycle,
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        return manager
    }

    private func process(
        pid: Int32,
        startTime: String = "Sat Jul 26 11:20:17 2026",
        cpu: Double = 0,
        memory: Double = 0,
        name: String
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 1,
            cpu: cpu,
            memoryMB: memory,
            command: name,
            elapsedTime: "00:10",
            startTime: startTime,
            netInKB: 0,
            netOutKB: 0,
            diskReadBytes: 0,
            diskWriteBytes: 0
        )
    }
}
