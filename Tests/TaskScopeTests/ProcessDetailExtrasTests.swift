import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-18: the extra Process Detail rows, each with an unavailable state, read
/// between identity checks and never through a child process.
final class ProcessDetailExtrasTests: XCTestCase {
    private let start = "Wed Oct 7 17:04:47 2026"
    private let startSeconds = 1_791_392_687

    private func row(pid: Int32 = 42, path: String? = "/usr/bin/python3") -> AppProcess {
        AppProcess(
            pid: pid, parentPID: 7, uid: getuid(), cpu: 0, memoryMB: 1,
            command: "python3", executablePath: path, elapsedTime: "00:01", startTime: start,
            netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }

    private func entry(_ pid: Int32, seconds: Int? = nil, micro: Int = 0, zombie: Bool = false, command: String = "proc") -> KernelProcessTable.Lookup {
        .found(KernelProcessEntry(pid: pid, parentPID: 1, uid: getuid(), startSeconds: seconds ?? startSeconds,
                                  startMicroseconds: micro, isZombie: zombie, command: command))
    }

    private func reads(
        entries: [Int32: [KernelProcessTable.Lookup]],
        paths: [Int32: String] = [42: "/usr/bin/python3", 7: "/bin/zsh"],
        threads: ProcessDetailValue<Int> = .available(4),
        openFiles: ProcessDetailValue<ProcessOpenFiles> = .available(ProcessOpenFiles(
            descriptorCount: 12,
            listeningPorts: [ListeningPort(transport: .tcp, port: 8080), ListeningPort(transport: .udp, port: 5353)]
        )),
        signature: ProcessCodeSignature = .signed(identifier: "com.example.tool", teamID: "ABCDE12345", isPlatformBinary: false, isAdHoc: false)
    ) -> (ProcessDetailKernelReads, ScriptedEntries) {
        let script = ScriptedEntries(entries)
        var reads = ProcessDetailKernelReads()
        reads.entry = { script.next($0) }
        reads.executablePath = { paths[$0] }
        reads.threadCount = { _ in threads }
        reads.openFiles = { _ in openFiles }
        reads.codeSignature = { _ in signature }
        return (reads, script)
    }

    func testExtraRowsAreReadBetweenIdentityChecks() {
        let (kernel, script) = reads(entries: [42: [entry(42)], 7: [entry(7, seconds: startSeconds - 60, command: "zsh")]])
        let reader = SystemProcessDetailReader(kernelReads: kernel)
        guard case .read(let details) = reader.readKernelDetails(for: row().identity, parentPID: 7) else {
            return XCTFail("the details must be read")
        }
        XCTAssertEqual(details.executablePath, .available("/usr/bin/python3"))
        XCTAssertEqual(details.parent, .running(name: "zsh"))
        XCTAssertEqual(details.threadCount, .available(4))
        XCTAssertEqual(details.openFiles.value?.descriptorCount, 12)
        XCTAssertEqual(details.codeSignature.description, .available("com.example.tool, Team ID ABCDE12345"))
        XCTAssertEqual(script.reads(of: 42), 2, "before and after")
    }

    func testAChangedOrExitedProcessYieldsNoExtraRows() {
        let reused = reads(entries: [42: [entry(42), entry(42, seconds: startSeconds + 30)], 7: [entry(7)]]).0
        XCTAssertEqual(SystemProcessDetailReader(kernelReads: reused).readKernelDetails(for: row().identity, parentPID: 7), .identityChanged)
        let exited = reads(entries: [42: [entry(42), .notFound], 7: [entry(7)]]).0
        XCTAssertEqual(SystemProcessDetailReader(kernelReads: exited).readKernelDetails(for: row().identity, parentPID: 7), .gone)
        let zombie = reads(entries: [42: [entry(42, zombie: true)], 7: [entry(7)]]).0
        XCTAssertEqual(SystemProcessDetailReader(kernelReads: zombie).readKernelDetails(for: row().identity, parentPID: 7), .gone)
        let otherStart = reads(entries: [42: [entry(42, seconds: startSeconds - 1)], 7: [entry(7)]]).0
        XCTAssertEqual(SystemProcessDetailReader(kernelReads: otherStart).readKernelDetails(for: row().identity, parentPID: 7), .identityChanged)
        let execed = reads(entries: [42: [entry(42)], 7: [entry(7)]], paths: [42: "/usr/bin/ruby"]).0
        XCTAssertEqual(SystemProcessDetailReader(kernelReads: execed).readKernelDetails(for: row().identity, parentPID: 7), .identityChanged)
    }

    func testEveryExtraRowHasAnUnavailableState() {
        let refused = ProcessDetailValue<Int>.unavailable(ProcessKernelDetails.reason(forErrno: EPERM))
        let (kernel, _) = reads(
            entries: [42: [entry(42)], 7: [.notFound]],
            paths: [:],
            threads: refused,
            openFiles: .unavailable(ProcessKernelDetails.reason(forErrno: EPERM)),
            signature: .unavailable("macOS did not return it.")
        )
        guard case .read(let details) = SystemProcessDetailReader(kernelReads: kernel).readKernelDetails(for: row(path: nil).identity, parentPID: 7) else {
            return XCTFail("a refused read still shows the sheet")
        }
        XCTAssertEqual(details.executablePath, .unavailable("macOS did not report it."))
        XCTAssertEqual(details.parent, .exited)
        XCTAssertEqual(details.threadCount, .unavailable("macOS shows this only for your own processes."))
        XCTAssertEqual(details.openFiles, .unavailable("macOS shows this only for your own processes."))
        XCTAssertEqual(details.codeSignature.description, .unavailable("macOS did not return it."))
        XCTAssertEqual(ProcessKernelDetails.reason(forErrno: ESRCH), "The process has exited.")

        let failedTable = reads(entries: [42: [.failed(errno: ENOMEM)]]).0
        guard case .read(let unread) = SystemProcessDetailReader(kernelReads: failedTable).readKernelDetails(for: row().identity, parentPID: 7) else {
            return XCTFail("the ps fields are still shown")
        }
        XCTAssertNil(unread.threadCount.value, "nothing is shown without an identity check")
        XCTAssertNil(unread.executablePath.value)
    }

    /// A parent PID that now belongs to a younger process is not the parent.
    func testParentIsNamedOnlyWhileItStillOwnsTheParentPID() {
        let younger = reads(entries: [42: [entry(42)], 7: [entry(7, seconds: startSeconds + 5, command: "imposter")]]).0
        guard case .read(let details) = SystemProcessDetailReader(kernelReads: younger).readKernelDetails(for: row().identity, parentPID: 7) else {
            return XCTFail("details expected")
        }
        XCTAssertEqual(details.parent, .exited)
        let sameSecondEarlier = reads(entries: [42: [entry(42)], 7: [entry(7, micro: 0, command: "zsh")]], paths: [42: "/usr/bin/python3"]).0
        guard case .read(let same) = SystemProcessDetailReader(kernelReads: sameSecondEarlier).readKernelDetails(for: row().identity, parentPID: 7) else {
            return XCTFail("details expected")
        }
        XCTAssertEqual(same.parent, .running(name: "zsh"), "without a path the kernel's short name is used")
        let none = reads(entries: [42: [entry(42)]]).0
        guard case .read(let orphan) = SystemProcessDetailReader(kernelReads: none).readKernelDetails(for: row().identity, parentPID: 0) else {
            return XCTFail("details expected")
        }
        XCTAssertEqual(orphan.parent, .unavailable("This process has no parent process."))
    }

    func testElapsedPortsAndSignatureTexts() {
        var detail = ProcessDetail(pid: 42, parentPID: 1, user: "me", startTime: start, command: "python3")
        let started = Date(timeIntervalSince1970: TimeInterval(startSeconds))
        XCTAssertEqual(detail.elapsedDescription(now: started.addingTimeInterval(3_725)), .available("01:02:05"))
        XCTAssertEqual(detail.elapsedDescription(now: started.addingTimeInterval(86_400 + 61)), .available("1 day, 00:01:01"))
        XCTAssertEqual(detail.elapsedDescription(now: started.addingTimeInterval(3 * 86_400)), .available("3 days, 00:00:00"))
        XCTAssertEqual(detail.elapsedDescription(now: started.addingTimeInterval(-5)), .available("00:00:00"))
        detail.startTime = "unexpected"
        XCTAssertEqual(detail.elapsedDescription(now: started), .unavailable("The start time could not be read."))

        XCTAssertEqual(ProcessDetail.portsDescription([]), "None")
        XCTAssertEqual(ProcessDetail.portsDescription([
            ListeningPort(transport: .udp, port: 5353), ListeningPort(transport: .tcp, port: 8443), ListeningPort(transport: .tcp, port: 80)
        ].sorted()), "TCP 80, 8443; UDP 5353")

        XCTAssertEqual(ProcessCodeSignature.signed(identifier: "com.apple.xpc.launchd", teamID: nil, isPlatformBinary: true, isAdHoc: false).description,
                       .available("com.apple.xpc.launchd, Apple"))
        XCTAssertEqual(ProcessCodeSignature.signed(identifier: "a.out", teamID: nil, isPlatformBinary: false, isAdHoc: true).description,
                       .available("a.out, ad hoc (no Team ID)"))
        XCTAssertEqual(ProcessCodeSignature.unsigned.description, .available("Unsigned"))
    }

    // MARK: Real reads

    /// This test's own process, and a listener it opens: the real reads see
    /// the thread, the descriptor and the port, with no child process.
    func testRealReadsOfThisProcessSeeItsListener() throws {
        let (socket, port) = try openListener()
        defer { close(socket) }
        XCTAssertGreaterThanOrEqual(ProcessKernelDetails.threadCount(pid: getpid()).value ?? 0, 1)
        let files = try XCTUnwrap(ProcessKernelDetails.openFiles(pid: getpid()).value)
        XCTAssertGreaterThan(files.descriptorCount, 0)
        XCTAssertTrue(files.listeningPorts.contains(ListeningPort(transport: .tcp, port: port)), "\(files.listeningPorts)")
        guard case .signed(let identifier, _, _, _) = ProcessKernelDetails.codeSignature(pid: getpid()) else {
            return XCTFail("the test runner is signed, at least ad hoc")
        }
        XCTAssertFalse(identifier.isEmpty)
    }

    /// Root's launchd: the kernel refuses this user its threads and files,
    /// which the sheet reports as unavailable; its signature is readable.
    func testRealReadsOfAnotherUsersProcessSayWhatIsUnavailable() throws {
        guard case .found(let launchd) = KernelProcessTable.entry(for: 1), launchd.uid != geteuid() else {
            throw XCTSkip("launchd is not another user's process here")
        }
        XCTAssertEqual(ProcessKernelDetails.threadCount(pid: 1), .unavailable("macOS shows this only for your own processes."))
        XCTAssertEqual(ProcessKernelDetails.openFiles(pid: 1), .unavailable("macOS shows this only for your own processes."))
        guard case .signed(let identifier, let teamID, let platform, _) = ProcessKernelDetails.codeSignature(pid: 1) else {
            return XCTFail("launchd is signed")
        }
        XCTAssertEqual(identifier, "com.apple.xpc.launchd")
        XCTAssertNil(teamID)
        XCTAssertTrue(platform)
    }

    private func openListener() throws -> (Int32, Int) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        return (descriptor, Int(UInt16(bigEndian: actual.sin_port)))
    }
}

private final class ScriptedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Int32: [KernelProcessTable.Lookup]]
    private var counts: [Int32: Int] = [:]

    init(_ script: [Int32: [KernelProcessTable.Lookup]]) {
        self.script = script
    }

    func next(_ pid: Int32) -> KernelProcessTable.Lookup {
        lock.withLock {
            counts[pid, default: 0] += 1
            guard var answers = script[pid], !answers.isEmpty else { return .notFound }
            let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
            script[pid] = answers
            return answer
        }
    }

    func reads(of pid: Int32) -> Int {
        lock.withLock { counts[pid, default: 0] }
    }
}
