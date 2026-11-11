import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

func batch06Query() -> ProcessListQuery {
    ProcessListQuery(searchText: "", filterMode: .all, watchedScopes: [], cpuHighlightThreshold: 30, memoryHighlightThresholdMB: 1024)
}

func batch06Process(
    pid: Int32, parent: Int32 = 1, name: String, cpu: Double = 0, memory: Double = 0
) -> AppProcess {
    AppProcess.fixture(
        pid: pid, parentPID: parent, uid: 501, cpu: cpu, memoryMB: memory,
        command: name, elapsedTime: "00:10", startTime: "start\(pid)",
        netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
    )
}

/// Each `sleep` call waits until the test resumes it by index.
actor Batch06Sleeper {
    private var intervals: [TimeInterval] = []
    private var requests: [CheckedContinuation<Bool, Never>?] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(interval: TimeInterval) async -> Bool {
        intervals.append(interval)
        let ready = countWaiters.filter { intervals.count >= $0.count }
        countWaiters.removeAll { intervals.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { requests.append($0) }
    }

    func waitForRequestCount(_ count: Int) async {
        guard intervals.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func requestCount() -> Int { intervals.count }

    func interval(at index: Int) -> TimeInterval { intervals[index] }

    func resumeRequest(at index: Int, returning value: Bool) {
        requests[index]?.resume(returning: value)
        requests[index] = nil
    }

    func resumePendingRequests(returning value: Bool) {
        for index in requests.indices {
            resumeRequest(at: index, returning: value)
        }
    }
}
