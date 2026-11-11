import Darwin
import Foundation

/// The outcome of reading one process's command line.
///
/// A command line can contain secrets such as tokens. It is read only when the
/// user asks for it (Show Detail, Copy Command Line) or when a rule needs it,
/// and it is never stored, logged, or put into diagnostics, reports, exports
/// or notifications.
enum CommandLineReadResult: Equatable, Sendable {
    /// The arguments joined by single spaces, as `ps -o args=` prints them.
    case loaded(String)
    /// No process with the identity's PID is running any more, or it has
    /// exited and only awaits its parent.
    case gone
    /// The PID now belongs to a different process, or the process now runs a
    /// different executable.
    case identityChanged
    /// The command line could not be read; the text says why, as a sentence.
    case unavailable(String)

    var commandLine: String? {
        if case .loaded(let text) = self { return text }
        return nil
    }

    /// Why there is no command line, or nil when there is one.
    var message: String? {
        switch self {
        case .loaded: nil
        case .gone: "This process is no longer running."
        case .identityChanged: "This PID now belongs to a different process."
        case .unavailable(let reason): UIMessage.sentence(reason)
        }
    }
}

/// Reads the command line of the process an identity names, and only that
/// process: a PID that was reused, or a process that exited or ran a different
/// executable, is reported instead of read.
protocol ProcessCommandLineReading: Sendable {
    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult
}

struct SystemProcessCommandLineReader: ProcessCommandLineReading {
    /// For processes the kernel will not show this user (other users'), the
    /// setuid `ps` still prints the arguments, with the start time beside them.
    static func psCommand(for pid: Int32) -> ExternalCommand {
        ExternalCommand("/bin/ps", ["-ww", "-o", "pid=,lstart=,args=", "-p", "\(pid)"])
    }

    /// Every kernel read and command goes through a property whose default is
    /// the real one, so tests can script them.
    var processEntry: @Sendable (Int32) -> KernelProcessTable.Lookup = { KernelProcessTable.entry(for: $0) }
    var kernelArguments: @Sendable (Int32) -> KernelProcessArguments.Read = { KernelProcessArguments.read(pid: $0) }
    var executablePath: @Sendable (Int32) -> String? = { ProcessListReader.executablePath(for: $0) }
    var run: @Sendable (ExternalCommand) async -> ShellCommandResult = { await ShellCommandRunner.run($0) }

    /// The process must have the identity's start time, and its executable
    /// path where both are known, before the arguments are read and again
    /// after, so arguments read in between cannot belong to a later occupant
    /// of the PID or to a program the process ran since.
    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult {
        guard identity.pid > 0 else { return .gone }
        guard !identity.startTime.isEmpty else {
            return .unavailable("The process's start time is unknown, so TaskScope cannot check that the PID still belongs to it.")
        }
        if let mismatch = verify(identity) { return mismatch }

        let text: String
        switch kernelArguments(identity.pid) {
        case .arguments(let arguments):
            guard !arguments.isEmpty else {
                return .unavailable("macOS reported no arguments for this process.")
            }
            text = arguments.joined(separator: " ")
        case .refused:
            // EINVAL here usually means another user's process. The kernel
            // refuses an exited one the same way; the check below tells them apart.
            switch await commandLineFromPS(identity) {
            case .loaded(let psText): text = psText
            case let failure: return failure
            }
        }
        if let mismatch = verify(identity) { return mismatch }
        return .loaded(text)
    }

    /// Nil when the PID still names the identity's process.
    private func verify(_ identity: ProcessIdentity) -> CommandLineReadResult? {
        switch processEntry(identity.pid) {
        case .notFound:
            return .gone
        case .failed(let code):
            return .unavailable("The process table could not be read (\(String(cString: strerror(code)))).")
        case .found(let entry):
            if entry.isZombie { return .gone }
            guard entry.startTimeText == identity.startTime else { return .identityChanged }
        }
        if let expectedPath = identity.executablePath,
           let path = executablePath(identity.pid),
           !Self.samePath(kernelPath: path, identityPath: expectedPath) {
            return .identityChanged
        }
        return nil
    }

    /// Identities hold standardized paths, which drop a leading /private,
    /// while proc_pidpath reports the /private form, so compare like with like.
    private static func samePath(kernelPath: String, identityPath: String) -> Bool {
        URL(fileURLWithPath: kernelPath).standardizedFileURL.path
            == URL(fileURLWithPath: identityPath).standardizedFileURL.path
    }

    private func commandLineFromPS(_ identity: ProcessIdentity) async -> CommandLineReadResult {
        let result = await run(Self.psCommand(for: identity.pid))
        if Task.isCancelled || result.exitCode == ShellCommandRunner.cancelledExitCode {
            return .unavailable("The read was cancelled.")
        }
        guard result.succeeded else {
            // `ps -p` exits 1 with no output when no such process exists.
            if result.stdout.isEmpty, result.exitCode == 1, result.terminatedBySignal == nil {
                return .gone
            }
            return .unavailable(result.stderr.isEmpty ? "ps \(result.failureDescription)." : result.stderr)
        }
        guard !result.stdout.isEmpty else { return .gone }
        let line = result.stdout
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        // `pid lstart(5) args`: the arguments are the raw remainder, so runs of
        // spaces inside them survive.
        guard let (fields, remainder) = PSColumns.leadingFields(in: line, count: 6),
              Int32(fields[0]) == identity.pid else {
            return .unavailable("The command line could not be parsed.")
        }
        guard fields[1...5].joined(separator: " ") == identity.startTime else { return .identityChanged }
        guard !remainder.isEmpty else { return .unavailable("ps printed no command line for this process.") }
        return .loaded(remainder)
    }
}

/// `sysctl(KERN_PROCARGS2)`: the arguments a process was started with, as it
/// holds them now. The kernel shows them only for the caller's own processes.
enum KernelProcessArguments {
    enum Read: Equatable, Sendable {
        case arguments([String])
        /// The kernel refused: another user's process (`EINVAL` for an
        /// unprivileged caller), or a process that is no longer running.
        case refused(errno: Int32)
    }

    /// The kernel's limit on the argument and environment area, `kern.argmax`.
    static let maximumArgumentBytes: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }()

    static func read(pid: Int32) -> Read {
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: maximumArgumentBytes,
            alignment: MemoryLayout<Int32>.alignment
        )
        defer { buffer.deallocate() }
        return read(pid: pid, into: buffer)
    }

    /// Reads into a caller's buffer of at least `maximumArgumentBytes`, so a
    /// pass over many processes can reuse one.
    static func read(pid: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Read {
        switch fill(buffer, pid: pid) {
        case .success(let bytes): .arguments(parse(bytes))
        case .failure(let failure): .refused(errno: failure.code)
        }
    }

    /// The command line as search compares it: the arguments joined by single
    /// spaces, with A-Z folded to lowercase, and never decoded into text. Nil
    /// when the kernel refuses or there are no arguments.
    static func foldedCommandLine(pid: Int32, into buffer: UnsafeMutableRawBufferPointer) -> [UInt8]? {
        guard case .success(let bytes) = fill(buffer, pid: pid) else { return nil }
        let ranges = argumentRanges(bytes)
        guard !ranges.isEmpty else { return nil }
        var line: [UInt8] = []
        line.reserveCapacity(ranges.reduce(ranges.count) { $0 + $1.count })
        for (offset, range) in ranges.enumerated() {
            if offset > 0 { line.append(0x20) }
            for byte in bytes[range] {
                line.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
            }
        }
        return line
    }

    private struct Refusal: Error {
        var code: Int32
    }

    private static func fill(_ buffer: UnsafeMutableRawBufferPointer, pid: Int32) -> Result<UnsafeRawBufferPointer, Refusal> {
        guard pid > 0 else { return .failure(Refusal(code: ESRCH)) }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = buffer.count
        guard sysctl(&mib, 3, buffer.baseAddress, &length, nil, 0) == 0 else {
            return .failure(Refusal(code: errno))
        }
        return .success(UnsafeRawBufferPointer(rebasing: buffer[..<min(length, buffer.count)]))
    }

    static func parse(_ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBytes { parse($0) }
    }

    static func parse(_ bytes: UnsafeRawBufferPointer) -> [String] {
        argumentRanges(bytes).map { String(decoding: UnsafeRawBufferPointer(rebasing: bytes[$0]), as: UTF8.self) }
    }

    /// Where each argument lies. The layout is `argc` (a C int), the
    /// executable path the kernel saved at exec, NUL padding, then `argc`
    /// NUL-terminated arguments, then the environment, which is never read. A
    /// process can rewrite its arguments in place; what it holds now is what
    /// `ps` shows too.
    static func argumentRanges(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count >= countSize else { return [] }
        let count = Int(bytes.loadUnaligned(as: Int32.self))
        guard count > 0 else { return [] }
        var index = countSize
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var ranges: [Range<Int>] = []
        while ranges.count < count, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            ranges.append(start..<index)
            index += 1
        }
        return ranges
    }
}

/// Column splitting for `ps` output whose last column is free text.
enum PSColumns {
    /// Splits off `count` whitespace-separated fields and returns the untouched
    /// remainder (leading separator run removed, internal spaces preserved).
    static func leadingFields(in line: String, count: Int) -> ([String], String)? {
        var tokens: [String] = []
        var current = ""
        var index = line.startIndex
        while index < line.endIndex, tokens.count < count {
            let character = line[index]
            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        if tokens.count < count, !current.isEmpty {
            tokens.append(current)
            current = ""
        }
        guard tokens.count == count else { return nil }
        var remainderStart = index
        while remainderStart < line.endIndex,
              line[remainderStart] == " " || line[remainderStart] == "\t" {
            remainderStart = line.index(after: remainderStart)
        }
        let remainder = String(line[remainderStart...])
            .trimmingCharacters(in: .newlines)
        return (tokens, remainder)
    }
}
