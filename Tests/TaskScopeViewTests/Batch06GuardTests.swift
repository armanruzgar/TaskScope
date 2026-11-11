import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// A05-10: guards that no test pinned before.
@MainActor
final class Batch06GuardTests: XCTestCase {
    func testUnobservedAndEditedPresetsHaveUnknownAvailability() {
        let preset = WatchedAppPreset.globalProtect
        let snapshot = WatchedAppSnapshot(preset: preset, runningNames: [])
        var edited = preset
        edited.mainProcessName = "EditedMain"
        for availability in [WatchedStatusAvailability.current, .stale, .unknown] {
            XCTAssertEqual(availability.forPresets([preset], snapshots: []), .unknown)
            XCTAssertEqual(availability.forPresets([edited], snapshots: [snapshot]), .unknown)
            XCTAssertEqual(availability.forPresets([preset], snapshots: [snapshot]), availability)
        }
    }

    func testSearchTrimsSurroundingWhitespaceAndNewlines() {
        let process = batch06Process(pid: 10, name: "Safari")
        for text in [" Safari ", "\nSafari\t", " \n\t"] {
            var query = batch06Query()
            query.searchText = text
            XCTAssertTrue(query.matches(process), text)
        }
    }

    func testUnbalancedEndDoesNotConsumeTheNextSamplingConsumer() async {
        let inventory = ScriptedInventory([.success([])], repeatsLast: true)
        let sleeper = Batch06Sleeper()
        let history = ProcessHistory(inventory: inventory, sleep: { await sleeper.sleep(interval: $0) })
        history.endSampling()
        history.endSampling()
        history.beginSampling(cadence: 60)
        for _ in 0..<1000 where history.samples.isEmpty { await Task.yield() }
        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.state, .sampling)
        history.endSampling()
        await sleeper.resumePendingRequests(returning: false)
    }

    func testRootCannotHaveACurrentUserGlobalProtectLaunchAgent() {
        let path = "/Applications/GlobalProtect.app/Contents/MacOS/PanGPS"
        for uid: uid_t in [0, 501] {
            var agent = batch06Process(pid: 10, name: "PanGPS")
            agent.uid = uid
            agent.executablePath = path
            let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: uid)
                .snapshot(for: .globalProtect, in: [agent])
            XCTAssertEqual(snapshot.hasCurrentUserLaunchAgent, uid != 0)
        }
    }

    func testRestartCancelsThePreviousPollingLoop() async {
        let sleeper = Batch06Sleeper()
        let controller = ProcessPollingController { await sleeper.sleep(interval: $0) }
        var oldActions = 0
        var newActions = 0
        controller.restart(interval: 10) { oldActions += 1 }
        await sleeper.waitForRequestCount(1)
        controller.restart(interval: 20) { newActions += 1 }
        await sleeper.waitForRequestCount(2)
        await sleeper.resumeRequest(at: 0, returning: true)
        await sleeper.resumeRequest(at: 1, returning: true)
        await sleeper.waitForRequestCount(3)
        for _ in 0..<100 { await Task.yield() }
        controller.stop()
        // Drain every pending request even under a broken restart implementation.
        await sleeper.resumePendingRequests(returning: false)
        XCTAssertEqual(oldActions, 0)
        XCTAssertEqual(newActions, 1)
    }

    func testSparklineAccessibilityDescribesEmptyAndLatestSamples() throws {
        let timestamp = Date(timeIntervalSince1970: 100)
        let samples = [
            ProcessHistory.Sample(timestamp: timestamp, observedProcessCPU: 10, observedProcessMemoryMB: 100, processCount: 1),
            ProcessHistory.Sample(timestamp: timestamp, observedProcessCPU: 25.5, observedProcessMemoryMB: 200, processCount: 2)
        ]
        for values in [[], samples] {
            let chart = SparklineView(samples: values, keyPath: \.observedProcessCPU, color: .blue, label: "CPU", unit: "percent")
            let stack = try chart.inspect().find(ViewType.VStack.self)
            XCTAssertEqual(try stack.accessibilityLabel().string(), "CPU")
            let latest = 25.5.formatted(.number.precision(.fractionLength(1)))
            XCTAssertEqual(try stack.accessibilityValue().string(), values.isEmpty ? "No samples" : "Latest \(latest) percent, peak \(latest) percent, 2 samples")
        }
    }
}
