import Foundation
import XCTest
@testable import TaskScope

/// A process detail reader for tests: a read answers with the result scripted
/// for the process's PID and fails the test when none is scripted, so a test
/// never reads a real process. Command lines answer as scripted, or as
/// unavailable.
final class ScriptedDetailReader: ProcessDetailReading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int32: [ProcessDetailResult]]
    private var commandLines: [Int32: CommandLineReadResult]
    private var readLog: [Int32] = []
    private let file: StaticString
    private let line: UInt

    /// `results[pid]` answers that PID's reads in order; the last one repeats.
    init(
        _ results: [Int32: [ProcessDetailResult]] = [:],
        commandLines: [Int32: CommandLineReadResult] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        self.results = results
        self.commandLines = commandLines
        self.file = file
        self.line = line
    }

    /// The PID of each detail read, in order.
    var readPIDs: [Int32] { lock.withLock { readLog } }

    func readResult(for process: AppProcess) async -> ProcessDetailResult {
        let answer = lock.withLock { () -> ProcessDetailResult? in
            readLog.append(process.pid)
            guard var queue = results[process.pid], let first = queue.first else { return nil }
            if queue.count > 1 { queue.removeFirst(); results[process.pid] = queue }
            return first
        }
        guard let answer else {
            XCTFail("Detail read for PID \(process.pid) was not scripted", file: file, line: line)
            return .readFailed("The test did not script this detail read.")
        }
        return answer
    }

    func readDetail(for process: AppProcess) async -> ProcessDetail? {
        await readResult(for: process).detail
    }

    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult {
        lock.withLock { commandLines[identity.pid] } ?? .unavailable("The test did not script a command line.")
    }
}
