import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-18: Net and Disk are per-second rates from consecutive refreshes, the
/// window has a User column, and the detail sheet shows the new rows.
final class ProcessIORateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func row(
        _ pid: Int32,
        startTime: String = "Wed Oct 7 17:04:47 2026",
        net: (Double, Double)? = nil,
        disk: (Double, Double)? = nil
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1,
            command: "worker", elapsedTime: "00:01", startTime: startTime,
            netInKB: net?.0, netOutKB: net?.1, diskReadBytes: disk?.0, diskWriteBytes: disk?.1
        )
    }

    func testRatesNeedTwoSamplesAndAverageOverTheInterval() throws {
        var tracker = ProcessIORateTracker()
        let first = tracker.apply(to: [row(1, net: (100, 50), disk: (1_000, 0))], at: start)
        XCTAssertNil(first[0].netInRateKBps, "the first sample shows a dash")
        XCTAssertNil(first[0].diskReadRateBytesPerSecond)
        XCTAssertEqual(first[0].netInKB, 100, "the counters are kept")

        let second = tracker.apply(to: [row(1, net: (300, 70), disk: (11_000, 500))], at: start.addingTimeInterval(10))
        XCTAssertEqual(second[0].netInRateKBps, 20)
        XCTAssertEqual(second[0].netOutRateKBps, 2)
        XCTAssertEqual(second[0].diskReadRateBytesPerSecond, 1_000)
        XCTAssertEqual(second[0].diskWriteRateBytesPerSecond, 50)
        XCTAssertEqual(second[0].networkSortValue, 22)
        XCTAssertEqual(second[0].diskSortValue, 1_050)
    }

    /// A read shared from the cache, or one right after another, must not
    /// divide by almost nothing: the previous rates stay.
    func testSamplesTooCloseTogetherKeepThePreviousRates() {
        var tracker = ProcessIORateTracker()
        _ = tracker.apply(to: [row(1, net: (0, 0))], at: start)
        _ = tracker.apply(to: [row(1, net: (100, 0))], at: start.addingTimeInterval(10))
        let close = tracker.apply(to: [row(1, net: (100, 0))], at: start.addingTimeInterval(10.2))
        XCTAssertEqual(close[0].netInRateKBps, 10)
        let later = tracker.apply(to: [row(1, net: (400, 0))], at: start.addingTimeInterval(20))
        XCTAssertEqual(later[0].netInRateKBps, 30, "measured from the last sample that was used")
    }

    func testANewProcessOnAReusedPIDAndBackwardCountersStartOver() {
        var tracker = ProcessIORateTracker()
        _ = tracker.apply(to: [row(1, net: (1_000, 0))], at: start)
        let reused = tracker.apply(to: [row(1, startTime: "Thu Oct 8 09:00:00 2026", net: (10, 0))], at: start.addingTimeInterval(10))
        XCTAssertNil(reused[0].netInRateKBps, "another process, so a first sample")
        let backwards = tracker.apply(to: [row(1, startTime: "Thu Oct 8 09:00:00 2026", net: (5, 0))], at: start.addingTimeInterval(20))
        XCTAssertNil(backwards[0].netInRateKBps)
        let clockBack = tracker.apply(to: [row(1, startTime: "Thu Oct 8 09:00:00 2026", net: (50, 0))], at: start.addingTimeInterval(5))
        XCTAssertNil(clockBack[0].netInRateKBps, "the clock went back")
        let resumed = tracker.apply(to: [row(1, startTime: "Thu Oct 8 09:00:00 2026", net: (150, 0))], at: start.addingTimeInterval(15))
        XCTAssertEqual(resumed[0].netInRateKBps, 10)
    }

    /// A read without counters (the popover's) shows no rate but keeps the
    /// baseline for the next read that has them.
    func testReadsWithoutCountersKeepTheBaseline() {
        var tracker = ProcessIORateTracker()
        _ = tracker.apply(to: [row(1, disk: (0, 0))], at: start)
        let basic = tracker.apply(to: [row(1)], at: start.addingTimeInterval(10))
        XCTAssertNil(basic[0].diskReadRateBytesPerSecond)
        let extended = tracker.apply(to: [row(1, disk: (2_000, 0))], at: start.addingTimeInterval(20))
        XCTAssertEqual(extended[0].diskReadRateBytesPerSecond, 100)
    }

    /// The list applies the tracker to every inventory it shows.
    @MainActor
    func testTheListShowsRatesFromItsSecondRead() async {
        let inventory = ScriptedInventory([
            .success([row(70, net: (100, 0), disk: (0, 0))]),
            .success([row(70, net: (400, 30), disk: (5_242_880, 0))])
        ], repeatsLast: true)
        let clock = TestClock(start)
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: FakeSignaler(), lifecycle: FakeLifecycle.forViewTests(),
            settleAfterProcessChange: {}, now: { clock.now },
            dependencies: .inert
        )
        manager.enableNotifications = false
        await manager.loadProcessList(showMessage: false)
        XCTAssertNil(manager.inventorySnapshot.first?.netInRateKBps)
        clock.now = start.addingTimeInterval(10)
        await manager.loadProcessList(showMessage: false)
        XCTAssertEqual(manager.inventorySnapshot.first?.netInRateKBps, 30)
        XCTAssertEqual(manager.inventorySnapshot.first?.netOutRateKBps, 3)
        XCTAssertEqual(manager.inventorySnapshot.first?.diskReadRateBytesPerSecond, 524_288)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
