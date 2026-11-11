import Darwin
import SwiftUI
import XCTest
@testable import TaskScope

func batch05Process(_ pid: Int32) -> AppProcess {
    AppProcess.fixture(
        pid: pid, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 1,
        command: "Example", elapsedTime: "00:01", startTime: "Wed Oct 7 17:04:47 2026",
        netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
    )
}
