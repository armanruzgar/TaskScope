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
        AppProcess(
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
        let inventory = SequenceInventory([
            [row(70, net: (100, 0), disk: (0, 0))],
            [row(70, net: (400, 30), disk: (5_242_880, 0))]
        ])
        let clock = TestClock(start)
        let manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: UIRecordingSignaler(), lifecycle: UILifecycle(),
            settleAfterProcessChange: {}, now: { clock.now }
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

/// The User column and the detail sheet's new rows.
@MainActor
final class ProcessDetailRowsTests: XCTestCase {
    func testWindowRowsShowTheOwnerAndRatesAndThePopoverDoesNot() throws {
        var process = Batch10.process(51)
        process.uid = 0
        process.netInRateKBps = 12.5
        process.netOutRateKBps = 0.25
        func row(_ expanded: Bool) -> ProcessRow {
            ProcessRow(process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
                       isHighlightedCPU: false, isHighlightedMEM: false, showsExpandedMetrics: expanded,
                       stopAction: {}, toggleSelection: {})
        }
        let window = try row(true).inspect()
        XCTAssertNoThrow(try window.find(text: "root"))
        XCTAssertNoThrow(try window.find(text: "12.5 / 0.2"))
        XCTAssertNoThrow(try window.find(text: "—"), "no disk rate yet")
        XCTAssertTrue(try window.find(ViewType.VStack.self).accessibilityValue().string().contains("user root"))
        XCTAssertTrue(try window.find(ViewType.VStack.self).accessibilityValue().string().contains("disk unavailable"))
        XCTAssertThrowsError(try row(false).inspect().find(text: "root"))

        process.diskReadBytes = 10
        process.diskWriteBytes = 0
        XCTAssertTrue(try row(true).inspect().find(ViewType.VStack.self).accessibilityValue().string()
            .contains("disk rate shown after the next refresh"))
    }

    func testDetailSheetShowsEveryNewRowSelectably() throws {
        let process = Batch10.process(51)
        var detail = ProcessDetail(pid: 51, parentPID: 7, user: "me", startTime: "Wed Oct 7 17:04:47 2026", command: "Example")
        detail.executablePath = .available("/Applications/Example.app/Contents/MacOS/Example")
        detail.parent = .running(name: "launchd")
        detail.threadCount = .available(9)
        detail.openFiles = .available(ProcessOpenFiles(
            descriptorCount: 31,
            listeningPorts: [ListeningPort(transport: .tcp, port: 8080), ListeningPort(transport: .udp, port: 5353)]
        ))
        detail.codeSignature = .signed(identifier: "com.example.app", teamID: "ABCDE12345", isPlatformBinary: false, isAdHoc: false)
        detail.commandLine = .loaded("Example --flag")
        let sheet = ProcessDetailSheet(
            process: process, detail: detail, failed: false,
            now: Date(timeIntervalSince1970: 1_791_392_687 + 90_061), onClose: {}
        )
        let inspected = try sheet.inspect()
        for (label, value) in [
            ("Parent", "launchd (7)"), ("Elapsed", "1 day, 01:01:01"),
            ("Executable", "/Applications/Example.app/Contents/MacOS/Example"),
            ("Code Signature", "com.example.app, Team ID ABCDE12345"), ("Threads", "9"),
            ("Open Files", "31"), ("Listening Ports", "TCP 8080; UDP 5353"), ("Command Line", "Example --flag")
        ] {
            XCTAssertNoThrow(try inspected.find(text: label), label)
            XCTAssertNoThrow(try inspected.find(text: value), value)
        }
        XCTAssertTrue(try inspected.vStack().textSelectability(), "every value can be selected")

        detail.threadCount = .unavailable("macOS shows this only for your own processes.")
        detail.parent = .exited
        let refused = try ProcessDetailSheet(process: process, detail: detail, failed: false, onClose: {}).inspect()
        XCTAssertNoThrow(try refused.find(text: "macOS shows this only for your own processes."))
        XCTAssertNoThrow(try refused.find(text: "PID 7, no longer running"))
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

/// Answers each read with the next inventory, then repeats the last.
private actor SequenceInventory: ProcessInventoryProviding {
    private var inventories: [[AppProcess]]

    init(_ inventories: [[AppProcess]]) {
        self.inventories = inventories
    }

    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        let next = inventories.count > 1 ? inventories.removeFirst() : inventories[0]
        return .success(next)
    }
}
