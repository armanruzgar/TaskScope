import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

func batch07Process(
    pid: Int32,
    command: String,
    executablePath: String?,
    startTime: String = ""
) -> AppProcess {
    AppProcess.fixture(
        pid: pid,
        parentPID: 1,
        cpu: 0,
        memoryMB: 0,
        command: command,
        executablePath: executablePath,
        elapsedTime: "00:10",
        startTime: startTime,
        netInKB: nil,
        netOutKB: nil,
        diskReadBytes: nil,
        diskWriteBytes: nil
    )
}

func batch07Preset(
    name: String,
    main: String? = nil,
    appPath: String? = nil
) -> WatchedAppPreset {
    WatchedAppPreset(
        displayName: name,
        mainProcessName: main ?? "\(name)Process",
        helperProcessNames: [],
        protectedProcessNames: [],
        appPath: appPath ?? "/Batch07Apps/\(name).app"
    )
}
