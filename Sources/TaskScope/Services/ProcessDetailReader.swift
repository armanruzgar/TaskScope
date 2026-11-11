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

protocol ProcessDetailReading: Sendable {
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
        // The command line is read only for the detail sheet the user asked
        // for, and kept only there: it can contain secrets. The same start-time
        // check rejects a process that took over the PID in between.
        let arguments = await run("/bin/ps -ww -o pid=,lstart=,args= -p \(process.pid)")
        if arguments.succeeded,
           let (fields, remainder) = Self.leadingFields(in: arguments.stdout, count: 6),
           Int32(fields[0]) == process.pid,
           fields[1...5].joined(separator: " ") == detail.startTime {
            detail.arguments = remainder.isEmpty ? nil : remainder
        }
        return .loaded(detail)
    }

    /// `pid ppid user lstart(5) comm`. The command is the raw text after the
    /// eighth whitespace-separated field so internal runs of spaces survive
    /// instead of being collapsed by a re-join.
    static func parseDetailLine(_ line: String, expectedStartTime: String?) -> ProcessDetail? {
        guard let (tokens, remainder) = leadingFields(in: line, count: detailColumnCount),
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

    /// Splits off `count` whitespace-separated fields and returns the untouched
    /// remainder (leading separator run removed, internal spaces preserved).
    private static func leadingFields(in line: String, count: Int) -> ([String], String)? {
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
