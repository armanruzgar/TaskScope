import Foundation

enum ProcessDetailResult: Equatable, Sendable {
    case loaded(ProcessDetail)
    case gone
    case identityChanged
    case readFailed(String)

    var detail: ProcessDetail? {
        if case .loaded(let detail) = self { return detail }
        return nil
    }
    var message: String? {
        switch self {
        case .loaded: nil
        case .gone: "This process is no longer running."
        case .identityChanged: "This PID now belongs to a different process."
        case .readFailed(let error): "Could not read process detail: \(UIMessage.sentence(error))"
        }
    }
}

/// The reads made for one process on the user's request: Show Detail, and
/// the command line that Copy Command Line copies.
protocol ProcessDetailReading: ProcessCommandLineReading {
    func readResult(for process: AppProcess) async -> ProcessDetailResult
    func readDetail(for process: AppProcess) async -> ProcessDetail?
}

extension ProcessDetailReading {
    func readResult(for process: AppProcess) async -> ProcessDetailResult {
        if let detail = await readDetail(for: process) { return .loaded(detail) }
        return .readFailed("The detail reader returned no data.")
    }
}

struct SystemProcessDetailReader: ProcessDetailReading {
    static let detailColumnCount = 8

    var commandLineReader: any ProcessCommandLineReading = SystemProcessCommandLineReader()
    var kernelReads = ProcessDetailKernelReads()

    func commandLine(for identity: ProcessIdentity) async -> CommandLineReadResult {
        await commandLineReader.commandLine(for: identity)
    }

    func readDetail(for process: AppProcess) async -> ProcessDetail? {
        await readResult(for: process).detail
    }

    func readDetail(
        for process: AppProcess,
        run: @Sendable (String) async -> ShellCommandResult
    ) async -> ProcessDetail? {
        await readResult(for: process, run: run).detail
    }

    func readResult(for process: AppProcess) async -> ProcessDetailResult {
        await readResult(for: process, run: { await ShellCommandRunner.run($0) })
    }

    /// Tells an exited process, a PID now used by another process and a read
    /// that failed apart, so the sheet can say which and offer Retry only
    /// where retrying can help.
    func readResult(
        for process: AppProcess,
        run: @Sendable (String) async -> ShellCommandResult
    ) async -> ProcessDetailResult {
        let result = await run(
            "/bin/ps -o pid=,ppid=,user=,lstart=,comm= -p \(process.pid)"
        )
        guard result.succeeded else {
            // `ps -p` exits 1 with no output when no such process exists.
            let isGone = result.stdout.isEmpty && result.exitCode == 1 && result.terminatedBySignal == nil
            return isGone
                ? .gone
                : .readFailed(result.stderr.isEmpty ? "ps could not complete." : result.stderr)
        }
        guard !result.stdout.isEmpty else { return .gone }

        let line = result.stdout
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard var detail = Self.parseDetailLine(line, expectedStartTime: nil),
              detail.pid == process.pid else {
            return .readFailed("The process detail could not be parsed.")
        }
        // A PID can be reused between rendering the row and requesting details.
        guard detail.startTime == process.identity.startTime else { return .identityChanged }
        switch readKernelDetails(for: process.identity, parentPID: detail.parentPID) {
        case .gone:
            return .gone
        case .identityChanged:
            return .identityChanged
        case .read(let kernel):
            detail.executablePath = kernel.executablePath
            detail.parent = kernel.parent
            detail.threadCount = kernel.threadCount
            detail.openFiles = kernel.openFiles
            detail.codeSignature = kernel.codeSignature
        }
        // The command line is read only for the detail sheet the user asked
        // for, and kept only there: it can contain secrets. The reader checks
        // the row's identity again around its own read.
        detail.commandLine = await commandLineReader.commandLine(for: process.identity)
        return .loaded(detail)
    }

    /// The extra rows' kernel reads, between two checks that the PID still
    /// has the row's start time (and executable path, when both are known),
    /// so no value can come from a later occupant of the PID.
    enum KernelDetailsRead: Equatable {
        case read(KernelDetails)
        case gone
        case identityChanged
    }

    struct KernelDetails: Equatable {
        var executablePath: ProcessDetailValue<String>
        var parent: ProcessParent
        var threadCount: ProcessDetailValue<Int>
        var openFiles: ProcessDetailValue<ProcessOpenFiles>
        var codeSignature: ProcessCodeSignature

        static func unavailable(_ reason: String) -> KernelDetails {
            KernelDetails(
                executablePath: .unavailable(reason), parent: .unavailable(reason),
                threadCount: .unavailable(reason), openFiles: .unavailable(reason),
                codeSignature: .unavailable(reason)
            )
        }
    }

    func readKernelDetails(for identity: ProcessIdentity, parentPID: Int32) -> KernelDetailsRead {
        let before: KernelProcessEntry
        switch kernelReads.entry(identity.pid) {
        case .notFound:
            return .gone
        case .failed(let code):
            return .read(.unavailable("The process table could not be read (\(String(cString: strerror(code))))."))
        case .found(let entry):
            guard !entry.isZombie else { return .gone }
            guard entry.startTimeText == identity.startTime else { return .identityChanged }
            before = entry
        }
        let path = kernelReads.executablePath(identity.pid)
        if let path, let expected = identity.executablePath, !Self.samePath(path, expected) {
            return .identityChanged
        }
        let details = KernelDetails(
            executablePath: path.map { .available($0) } ?? .unavailable("macOS did not report it."),
            parent: parent(parentPID, of: before),
            threadCount: kernelReads.threadCount(identity.pid),
            openFiles: kernelReads.openFiles(identity.pid),
            codeSignature: kernelReads.codeSignature(identity.pid)
        )
        switch kernelReads.entry(identity.pid) {
        case .found(let after) where !after.isZombie && after.startTimeText == identity.startTime:
            if let path, let pathAfter = kernelReads.executablePath(identity.pid), !Self.samePath(path, pathAfter) {
                return .identityChanged
            }
            return .read(details)
        case .found(let after) where after.isZombie:
            return .gone
        case .notFound:
            return .gone
        case .found:
            return .identityChanged
        case .failed(let code):
            return .read(.unavailable("The process table could not be read (\(String(cString: strerror(code))))."))
        }
    }

    /// The parent PID names the parent only while it still belongs to a
    /// process that started no later than this one.
    private func parent(_ parentPID: Int32, of child: KernelProcessEntry) -> ProcessParent {
        guard parentPID > 0 else { return .unavailable("This process has no parent process.") }
        switch kernelReads.entry(parentPID) {
        case .notFound:
            return .exited
        case .failed(let code):
            return .unavailable("It could not be read (\(String(cString: strerror(code)))).")
        case .found(let parent):
            let startedFirst = (parent.startSeconds, parent.startMicroseconds) <= (child.startSeconds, child.startMicroseconds)
            guard !parent.isZombie, startedFirst else { return .exited }
            let name = kernelReads.executablePath(parentPID).map { ($0 as NSString).lastPathComponent }
            return .running(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? parent.command)
        }
    }

    private static func samePath(_ kernelPath: String, _ identityPath: String) -> Bool {
        URL(fileURLWithPath: kernelPath).standardizedFileURL.path
            == URL(fileURLWithPath: identityPath).standardizedFileURL.path
    }

    /// `pid ppid user lstart(5) comm`. The command is the raw text after the
    /// eighth whitespace-separated field so internal runs of spaces survive
    /// instead of being collapsed by a re-join.
    static func parseDetailLine(_ line: String, expectedStartTime: String?) -> ProcessDetail? {
        guard let (tokens, remainder) = PSColumns.leadingFields(in: line, count: detailColumnCount),
              let pid = Int32(tokens[0]),
              let parentPID = Int32(tokens[1]) else {
            return nil
        }

        let startTime = tokens[3..<8].joined(separator: " ")
        // A PID can be reused between rendering the row and requesting details.
        // Both identities use `ps lstart`, so reject data from a new occupant.
        guard expectedStartTime == nil || startTime == expectedStartTime else { return nil }

        return ProcessDetail(
            pid: pid,
            parentPID: parentPID,
            user: tokens[2],
            startTime: startTime,
            command: remainder
        )
    }
}
