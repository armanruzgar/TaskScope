import Darwin
import Foundation
@testable import TaskScope

extension AppProcess {
    /// A process row for tests (L07-8): the one place tests build `AppProcess`,
    /// so a new field means one change here. Defaults match the model's own
    /// initializer (no owner, no executable path, no start time, no network or
    /// disk readings); the readings it requires default to zero, and a row
    /// built from `name` alone runs `/Applications/<name>.app/Contents/MacOS/<name>`.
    static func fixture(
        pid: Int32,
        parentPID: Int32 = 1,
        name: String = "Example",
        uid: uid_t? = nil,
        ownerName: String? = nil,
        cpu: Double = 0,
        memoryMB: Double = 0,
        command: String? = nil,
        executablePath: String? = nil,
        elapsedTime: String = "00:01",
        startTime: String = "",
        monotonicStart: MonotonicStart = .notRead,
        isZombie: Bool? = nil,
        netInKB: Double? = nil,
        netOutKB: Double? = nil,
        diskReadBytes: Double? = nil,
        diskWriteBytes: Double? = nil
    ) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: parentPID,
            uid: uid,
            ownerName: ownerName,
            cpu: cpu,
            memoryMB: memoryMB,
            command: command ?? "/Applications/\(name).app/Contents/MacOS/\(name)",
            executablePath: executablePath,
            elapsedTime: elapsedTime,
            startTime: startTime,
            monotonicStart: monotonicStart,
            isZombie: isZombie,
            netInKB: netInKB,
            netOutKB: netOutKB,
            diskReadBytes: diskReadBytes,
            diskWriteBytes: diskWriteBytes
        )
    }
}
