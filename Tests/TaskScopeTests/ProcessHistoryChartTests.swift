import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-14 and A05-7: the header charts state their latest value, their peak
/// in the window and the window's span, say a sampling state other than Live,
/// and label the sums honestly.
@MainActor
final class ProcessHistoryChartTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func samples(_ values: [Double], every seconds: TimeInterval = 10, processes: Int = 3) -> [ProcessHistory.Sample] {
        values.enumerated().map { index, value in
            ProcessHistory.Sample(
                timestamp: start.addingTimeInterval(Double(index) * seconds),
                observedProcessCPU: value, observedProcessMemoryMB: value * 10, processCount: processes
            )
        }
    }

    private func chart(_ samples: [ProcessHistory.Sample], window: TimeInterval? = 600,
                       state: ProcessHistory.SamplingState = .sampling) -> SparklineView {
        SparklineView(
            samples: samples, keyPath: \.observedProcessCPU, color: .orange, label: "CPU SUM", unit: "percent",
            samplingState: state, window: window, format: TaskScopeHeaderView.percentText
        )
    }

    /// A steady 3% and a steady 300% drew the same line with nothing beside it.
    func testSteadyLowAndHighValuesNowReadDifferently() throws {
        let low = try chart(samples([3, 3, 3])).inspect()
        XCTAssertNoThrow(try low.find(text: "3.0%"))
        XCTAssertNoThrow(try low.find(text: "peak 3.0%"))
        let high = try chart(samples([300, 300, 300])).inspect()
        XCTAssertNoThrow(try high.find(text: "300%"))
        XCTAssertNoThrow(try high.find(text: "peak 300%"))
    }

    func testThePeakAndTheAxisCoverOnlyTheWindowOfTheLatestSample() throws {
        // A spike 70 s before the latest sample is outside a 60 s window.
        let series = samples([90, 10, 10, 10, 10, 10, 10, 12])
        let view = chart(series, window: 60)
        XCTAssertEqual(view.latest, 12)
        XCTAssertEqual(view.peak, 12)
        XCTAssertEqual(view.visibleSamples.count, 7)
        XCTAssertEqual(chart(series, window: nil).peak, 90, "without a window every sample counts")
        XCTAssertEqual(
            try view.inspect().vStack().accessibilityValue().string(),
            "Latest 12.0 percent, peak 12.0 percent in the last 60 s, 7 samples"
        )
        XCTAssertEqual(try chart([], window: 60).inspect().vStack().accessibilityValue().string(), "No samples")
        XCTAssertEqual(
            try chart([], window: 60, state: .paused).inspect().vStack().accessibilityValue().string(),
            "No samples, Paused"
        )
        XCTAssertNoThrow(try chart([]).inspect().find(text: "peak –"))
    }

    func testSpansValuesAndSumsAreWrittenOut() {
        XCTAssertEqual(SparklineView.spanText(90), "90 s")
        XCTAssertEqual(SparklineView.spanText(120), "2 min")
        XCTAssertEqual(SparklineView.spanText(600), "10 min")
        XCTAssertEqual(SparklineView.spanText(3600), "60 min")
        XCTAssertEqual(TaskScopeHeaderView.percentText(3.24), "3.2%")
        XCTAssertEqual(TaskScopeHeaderView.percentText(882.6), "883%")
        XCTAssertEqual(TaskScopeHeaderView.memoryText(512.4), "512 MB")
        XCTAssertEqual(TaskScopeHeaderView.memoryText(63_795.2), "62.3 GB")
    }

    func testTheHeaderLabelsTheSumsAndSaysAStateOtherThanLive() throws {
        func header(_ state: ProcessHistory.SamplingState) -> TaskScopeHeaderView {
            TaskScopeHeaderView(
                status: .idle, samples: samples([10, 20], processes: 1_221), samplingState: state,
                historyWindow: 120, showsMetrics: true, showsOpenWindowButton: false, refreshAction: {}
            )
        }
        let live = try header(.sampling).inspect()
        XCTAssertNoThrow(try live.find(text: "CPU SUM"))
        XCTAssertNoThrow(try live.find(text: "RSS SUM"))
        XCTAssertNoThrow(try live.find(text: "200 MB"))
        XCTAssertNoThrow(try live.find(text: "last 2 min"))
        XCTAssertThrowsError(try live.find(text: "History live"), "Live is not announced")
        let memory = try live.find(SparklineView.self) { try $0.actualView().label == "RSS SUM" }
        let help = try memory.help().string()
        XCTAssertTrue(help.contains("1,221 observed processes"), help)
        XCTAssertTrue(help.contains("can exceed the Mac's memory"), help)

        XCTAssertNoThrow(try header(.paused).inspect().find(text: "History paused"))
        let unavailable = try header(.unavailable("ps failed")).inspect().find(text: "History unavailable")
        XCTAssertEqual(try unavailable.help().string(), "History unavailable: ps failed")
    }
}
