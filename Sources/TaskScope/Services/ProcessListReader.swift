import Darwin
import Foundation

enum ProcessInventoryError: Error, Equatable, LocalizedError, Sendable {
    case commandFailed(String)
    case parseFailed
    /// The read was cancelled by its caller (a poll restart, a view teardown).
    /// It says nothing about the inventory and is never recorded as a load
    /// failure.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "The process list command failed." : detail
        case .parseFailed:
            return "The process list could not be parsed."
        case .cancelled:
            return "The process list read was cancelled."
        }
    }
}

protocol ProcessInventoryProviding: Sendable {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError>
}

struct SystemProcessInventory: ProcessInventoryProviding {
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        await ProcessListReader.currentProcessList(fetchExtendedStats: fetchExtendedStats)
    }
}

enum ProcessListReader {
    // `comm` supplies a useful display path when available. It remains argv-backed,
    // so lifecycle and destructive matching must use the separately resolved kernel
    // executable path rather than trusting this value.
    //
    // Column layout (12 whitespace-separated tokens; `lstart` is 5):
    //   pid ppid uid pcpu rss lstart(5) etime comm
    // ShellCommandRunner pins numeric/time formatting to C and the time zone to
    // UTC, while allowing UTF-8 process names.
    static let processListCommand = "/bin/ps -awwwxo pid=,ppid=,uid=,pcpu=,rss=,lstart=,etime=,comm="
    static let networkStatsCommand = "/usr/bin/nettop -P -L 1 -n -x -J bytes_in,bytes_out"

    /// Every command and kernel read goes through a parameter whose default is
    /// the real one, so tests can script `ps` and `nettop` output, the process
    /// table, failures and cancellations.
    ///
    /// `ps` stays: it is the only unprivileged source of RSS and %CPU for other
    /// users' processes. One in-process read of the kernel's process table,
    /// taken after the per-row libproc reads, then vouches for each row's
    /// identity, where a second `ps` used to.
    static func currentProcessList(
        fetchExtendedStats: Bool,
        run: @Sendable (String) async -> ShellCommandResult = { await ShellCommandRunner.run($0) },
        executablePath: @Sendable (Int32) -> String? = { executablePath(for: $0) },
        startUptime: @Sendable (Int32) -> UInt64? = { startUptimeNanoseconds(for: $0) },
        processTable: @Sendable () -> KernelProcessTable.TableRead = { KernelProcessTable.allEntries() },
        ownerName: @Sendable (uid_t) -> String? = { ProcessOwnerNames.name(for: $0) },
        diskIO: @Sendable (Int32) -> (read: Double, written: Double)? = { diskIOBytes(for: $0) },
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) async -> Result<[AppProcess], ProcessInventoryError> {
        let result = await run(processListCommand)
        if let cancellation = cancellation(of: result) {
            return .failure(cancellation)
        }
        guard result.succeeded else {
            let detail = result.stderr.isEmpty ? "ps \(result.failureDescription)." : result.stderr
            return .failure(.commandFailed(detail))
        }

        var parsed: [AppProcess]
        switch parseProcessListOutput(result.stdout) {
        case .success(let processes):
            parsed = processes
        case .failure(let error):
            return .failure(error)
        }

        let resolvedPaths = Dictionary(
            parsed.compactMap { process in
                executablePath(process.pid).map { (process.pid, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Read before the process table, like the paths, so identity
        // validation also vouches for these start times.
        let currentUID = getuid()
        let monotonicStarts = Dictionary(
            parsed.compactMap { process -> (Int32, UInt64)? in
                guard process.uid == currentUID else { return nil }
                return startUptime(process.pid).map { (process.pid, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        if Task.isCancelled {
            return .failure(.cancelled)
        }
        let validatedStartTimeMap: [Int32: String]
        switch processTable() {
        case .entries(let table):
            validatedStartTimeMap = validatedStartTimes(from: table)
        case .failed(let code):
            return .failure(.commandFailed("The process table could not be read (\(String(cString: strerror(code))))."))
        }
        // Process churn between `ps` and the table read is normal (`ps` itself
        // has exited by then). Keep only rows whose PID still has the row's
        // start time and has not exited; a cleanly missing PID is simply no
        // longer present.
        parsed = validatedProcesses(parsed, using: validatedStartTimeMap)
        // This process must survive both reads. A table without it must not
        // turn a broken read into "nothing running".
        guard parsed.contains(where: { $0.pid == currentPID }) else {
            return .failure(.parseFailed)
        }
        attachExecutablePaths(
            to: &parsed,
            resolvedPaths: resolvedPaths,
            validatedStartTimes: validatedStartTimeMap
        )
        attachMonotonicStarts(
            to: &parsed,
            startTimes: monotonicStarts,
            currentUID: currentUID,
            validatedStartTimes: validatedStartTimeMap
        )

        // Exit is decided from the table's process state, never from `comm`,
        // which is argv-backed: a live process can call itself `<defunct>`.
        // Every row left has a running process. Owner names are looked up
        // here, once per user id, so the list never resolves one while it
        // draws.
        for index in parsed.indices {
            parsed[index].isZombie = false
            parsed[index].ownerName = parsed[index].uid.flatMap(ownerName)
        }

        if fetchExtendedStats {
            let networkResult = await run(networkStatsCommand)
            let netStats = networkResult.succeeded ? parseNetworkStats(networkResult.stdout) : nil
            if Task.isCancelled {
                return .failure(.cancelled)
            }
            for index in parsed.indices {
                parsed[index].netInKB = netStats?[parsed[index].pid]?.0
                parsed[index].netOutKB = netStats?[parsed[index].pid]?.1
                let disk = diskIO(parsed[index].pid)
                parsed[index].diskReadBytes = disk?.read
                parsed[index].diskWriteBytes = disk?.written
            }
        }

        return .success(parsed)
    }

    /// A cancelled command (or a cancelled calling task) is reported as
    /// `.cancelled` so callers never record it as an inventory fault.
    static func cancellation(of result: ShellCommandResult) -> ProcessInventoryError? {
        if Task.isCancelled || result.exitCode == ShellCommandRunner.cancelledExitCode {
            return .cancelled
        }
        return nil
    }

    /// Rows that cannot be parsed, or that name a pid TaskScope must never
    /// signal, are dropped while the rest of the inventory is kept. Output with
    /// no usable rows, or a repeated pid (an inconsistent snapshot), fails the
    /// whole read.
    static func parseProcessListOutput(
        _ output: String
    ) -> Result<[AppProcess], ProcessInventoryError> {
        var processes: [AppProcess] = []
        var seenPIDs: Set<Int32> = []
        for line in output.split(separator: "\n") {
            guard let process = parseProcessLine(line) else {
                continue
            }
            guard seenPIDs.insert(process.pid).inserted else {
                return .failure(.parseFailed)
            }
            processes.append(process)
        }
        guard !processes.isEmpty else {
            return .failure(.parseFailed)
        }
        return .success(processes)
    }

    /// Parses one `processListCommand` row. Exactly 11 tokens is a row whose
    /// `comm` is empty; anything else that does not fit the 12-token shape is
    /// rejected so the caller can drop that row.
    static func parseProcessLine(_ line: Substring) -> AppProcess? {
        let parts = line.split(
            separator: " ",
            maxSplits: 11,
            omittingEmptySubsequences: true
        )
        guard parts.count == 11 || parts.count == 12,
              let pid = Int32(parts[0]),
              ProcessSignalGuard.isSignalablePID(pid),
              let ppid = Int32(parts[1]),
              let uid = uid_t(parts[2]),
              let cpu = decimal(parts[3]),
              let rssKB = decimal(parts[4]) else {
            return nil
        }

        return AppProcess(
            pid: pid,
            parentPID: ppid,
            uid: uid,
            cpu: cpu,
            memoryMB: rssKB / 1024.0,
            command: parts.count == 12
                ? String(parts[11]).trimmingCharacters(in: .whitespacesAndNewlines)
                : "",
            elapsedTime: String(parts[10]),
            startTime: parts[5...9].joined(separator: " "),
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }

    /// Accepts "0.5" and, defensively, "0,5": the command runs under LC_NUMERIC=C,
    /// but a comma decimal must still parse rather than drop the row.
    private static func decimal(_ token: Substring) -> Double? {
        Double(token) ?? Double(token.replacingOccurrences(of: ",", with: "."))
    }

    static func attachExecutablePaths(
        to processes: inout [AppProcess],
        resolvedPaths: [Int32: String],
        validatedStartTimes: [Int32: String]
    ) {
        for index in processes.indices {
            let process = processes[index]
            guard validatedStartTimes[process.pid] == process.startTime,
                  let path = resolvedPaths[process.pid],
                  path.hasPrefix("/") else {
                processes[index].executablePath = nil
                continue
            }
            processes[index].executablePath = URL(fileURLWithPath: path)
                .standardizedFileURL.path
        }
    }

    /// Current-user rows carry the kernel's start time so a wall-clock change
    /// cannot advance a runtime rule. A failed read or a changed identity
    /// marks the row unavailable rather than unread.
    static func attachMonotonicStarts(
        to processes: inout [AppProcess],
        startTimes: [Int32: UInt64],
        currentUID: uid_t,
        validatedStartTimes: [Int32: String]
    ) {
        for index in processes.indices where processes[index].uid == currentUID {
            let process = processes[index]
            guard validatedStartTimes[process.pid] == process.startTime,
                  let start = startTimes[process.pid] else {
                processes[index].monotonicStart = .unavailable
                continue
            }
            processes[index].monotonicStart = .uptimeNanoseconds(start)
        }
    }

    /// Each running process's start time, as the inventory's `ps lstart`
    /// text (the conversion the Activity Monitor handoff uses too). A zombie
    /// has exited, so it vouches for no row.
    static func validatedStartTimes(from table: [Int32: KernelProcessEntry]) -> [Int32: String] {
        var startTimes: [Int32: String] = [:]
        startTimes.reserveCapacity(table.count)
        for (pid, entry) in table where !entry.isZombie {
            startTimes[pid] = entry.startTimeText
        }
        return startTimes
    }

    static func validatedProcesses(
        _ processes: [AppProcess],
        using startTimes: [Int32: String]
    ) -> [AppProcess] {
        processes.filter { startTimes[$0.pid] == $0.startTime }
    }

    static func executablePath(for pid: Int32) -> String? {
        // Swift cannot import the arithmetic C macro
        // `PROC_PIDPATHINFO_MAXSIZE` (`4 * MAXPATHLEN`) directly.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Cumulative disk I/O from the kernel's resource-usage record. `ps`'s
    /// `inblock`/`oublock` columns print `-` for every row on current macOS, so
    /// they were never a source of data. The kernel refuses this call for
    /// processes the caller may not inspect; those rows stay nil.
    static func diskIOBytes(for pid: Int32) -> (read: Double, written: Double)? {
        guard let info = resourceUsage(for: pid) else { return nil }
        return (Double(info.ri_diskio_bytesread), Double(info.ri_diskio_byteswritten))
    }

    /// The kernel's uptime clock when the process started, in nanoseconds.
    /// Unlike the wall-clock start `ps` reports, setting the system clock
    /// cannot move it. Nil when the kernel refuses the read.
    static func startUptimeNanoseconds(for pid: Int32) -> UInt64? {
        guard let info = resourceUsage(for: pid), info.ri_proc_start_abstime > 0 else { return nil }
        return UptimeSample.nanoseconds(fromMachTime: info.ri_proc_start_abstime)
    }

    private static func resourceUsage(for pid: Int32) -> rusage_info_v4? {
        // `rusage_info_t` is `void *`; the C API is declared as taking a pointer
        // to it but writes the struct at the pointed-to address itself, exactly
        // as its callers pass `(rusage_info_t *)&info`.
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { infoPointer -> Int32 in
            infoPointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, buffer)
            }
        }
        return status == 0 ? info : nil
    }

    /// Parses `networkStatsCommand` CSV rows, `name.pid,bytes_in,bytes_out,`,
    /// into KB received and sent per PID. The counts are the last two fields
    /// and the PID follows the last dot, so names containing dots or commas
    /// still parse. Nil when no row does.
    static func parseNetworkStats(_ output: String) -> [Int32: (Double, Double)]? {
        var stats: [Int32: (Double, Double)] = [:]
        for line in output.split(separator: "\n") {
            var parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            guard parts.count >= 3 else { continue }
            let namePid = parts.dropLast(2).joined(separator: ",")
            guard let dotIndex = namePid.lastIndex(of: "."),
                  let pid = Int32(namePid[namePid.index(after: dotIndex)...]),
                  let inBytes = Double(parts[parts.count - 2]),
                  let outBytes = Double(parts[parts.count - 1]) else { continue }
            stats[pid] = (inBytes / 1024.0, outBytes / 1024.0)
        }
        return stats.isEmpty ? nil : stats
    }
}
