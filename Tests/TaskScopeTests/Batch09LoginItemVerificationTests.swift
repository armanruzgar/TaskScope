import UserNotifications
import XCTest
@testable import TaskScope

/// LoginItemManager's delayed verification refresh, with an injected delay.
@MainActor
final class Batch09LoginItemVerificationTests: XCTestCase {
    // T05-12 (a): a state macOS settles after the call reaches the UI once the
    // verification delay has passed.
    func testVerificationRefreshPublishesAStateThatSettlesLater() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .requiresApproval)
        let gate = Batch09DelayGate()
        let manager = LoginItemManager(service: service, verificationDelay: { try await gate.wait() })

        manager.setEnabled(true)
        XCTAssertEqual(manager.state, .enabled, "the immediate refresh sees the registration")
        service.settle()
        XCTAssertEqual(manager.state, .enabled)

        try await waitUntil { await gate.waiting == 1 }
        await gate.open()
        try await waitUntil { manager.state == .requiresApproval }
        XCTAssertEqual(manager.message, "Launch at Login requires approval in System Settings.")
    }

    // T05-12 (b): a newer change cancels the pending verification, so only one
    // late refresh happens.
    func testANewerChangeCancelsThePendingVerification() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .enabled)
        let probe = Batch09CancellationProbe()
        let manager = LoginItemManager(service: service, verificationDelay: {
            if await probe.begin() == 1 {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    await probe.markCancelled()
                    throw error
                }
            }
        })

        manager.setEnabled(true)
        try await waitUntil { await probe.calls == 1 }
        let readsBeforeSecondChange = service.stateReads
        manager.setEnabled(true)
        let readsAfterSecondChange = service.stateReads

        try await waitUntil { await probe.cancelled }
        try await waitUntil { service.stateReads == readsAfterSecondChange + 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.stateReads, readsAfterSecondChange + 1, "exactly one late refresh")
        XCTAssertGreaterThan(readsAfterSecondChange, readsBeforeSecondChange)
    }

    // T05-12 (c): releasing the manager cancels its pending verification.
    func testReleasingTheManagerCancelsThePendingVerification() async throws {
        let service = Batch09SettlingLoginService(state: .notRegistered, settlesTo: .enabled)
        let probe = Batch09CancellationProbe()
        var manager: LoginItemManager? = LoginItemManager(service: service, verificationDelay: {
            _ = await probe.begin()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                await probe.markCancelled()
                throw error
            }
        })
        manager?.setEnabled(true)
        try await waitUntil { await probe.calls == 1 }

        manager = nil

        try await waitUntil { await probe.cancelled }
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not met in time", file: file, line: line)
    }
}

private final class Batch09SettlingLoginService: LoginItemServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemState
    private var reads = 0
    private let settled: LoginItemState
    init(state: LoginItemState, settlesTo settled: LoginItemState) {
        current = state
        self.settled = settled
    }
    var stateReads: Int { lock.withLock { reads } }
    var state: LoginItemState {
        lock.withLock {
            reads += 1
            return current
        }
    }
    func settle() { lock.withLock { current = settled } }
    func register() throws { lock.withLock { current = .enabled } }
    func unregister() throws { lock.withLock { current = .notRegistered } }
    func openSystemSettings() {}
}

private actor Batch09DelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { continuations.count }
    func wait() async throws {
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private actor Batch09CancellationProbe {
    private(set) var calls = 0
    private(set) var cancelled = false
    func begin() -> Int {
        calls += 1
        return calls
    }
    func markCancelled() { cancelled = true }
}
