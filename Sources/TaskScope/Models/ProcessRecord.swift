import Foundation

/// Where a row's process start sits on the kernel's uptime clock.
enum MonotonicStart: Equatable, Sendable {
    /// The row's source does not read kernel start times. The live inventory
    /// reads them for the current user's processes only.
    case notRead
    /// The kernel did not report a start time, or the row's identity changed
    /// while it was read.
    case unavailable
    case uptimeNanoseconds(UInt64)
}

struct AppProcess: Identifiable, Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32
    /// Effective user id reported by `ps`, or nil when the row did not carry it.
    /// A protected process name is treated as the protected *system* daemon only
    /// when this is 0; an unknown uid is never promoted to root.
    var uid: uid_t?
    /// The owner's account name, which the User column shows and sorts by.
    /// The live inventory fills it in when it reads the list; the list never
    /// looks a name up while it draws, so a row built from fixed data shows
    /// only the name it was given.
    var ownerName: String?
    var cpu: Double
    var memoryMB: Double
    var command: String {
        didSet { name = Self.name(from: command) }
    }
    /// Display name derived from `command` (see `name(from:)`), computed once
    /// per row rather than on every sort comparison and filter pass.
    private(set) var name: String
    /// Kernel-resolved executable vnode path. Never derived from argv/`ps comm`.
    var executablePath: String? {
        didSet { identityExecutablePath = Self.standardizedPath(executablePath) }
    }
    /// `executablePath` as identities compare it, standardized once when the
    /// path is set: identities are built for the whole inventory on the main
    /// actor, and standardizing touches the file system.
    private var identityExecutablePath: String?
    /// Whether the kernel reported the process as a zombie (exited, awaiting
    /// its parent's `waitpid`) when the inventory was read; nil when that state
    /// was not read.
    var isZombie: Bool?
    /// Whether the kernel reported the process as stopped by a signal (`ps`
    /// state `T`, for example after Pause) when the inventory was read; nil
    /// when that state was not read. Not part of the identity.
    var isStopped: Bool?
    var elapsedTime: String
    var startTime: String
    /// Runtime rules require this for live rows: `elapsedTime` is wall-clock
    /// arithmetic that a clock change can inflate.
    var monotonicStart: MonotonicStart
    var netInKB: Double?
    var netOutKB: Double?
    /// Cumulative disk bytes read/written by the process, from
    /// `proc_pid_rusage`. Nil when the kernel does not report them for this
    /// process (typically another user's), never fabricated as zero.
    var diskReadBytes: Double?
    var diskWriteBytes: Double?
    /// Per-second rates from this read's counters and an earlier read's, set
    /// by the process list; nil until a process has two samples, and when its
    /// counters are unavailable. See `ProcessIORateTracker`.
    var netInRateKBps: Double?
    var netOutRateKBps: Double?
    var diskReadRateBytesPerSecond: Double?
    var diskWriteRateBytesPerSecond: Double?

    init(
        pid: Int32,
        parentPID: Int32,
        uid: uid_t? = nil,
        ownerName: String? = nil,
        cpu: Double,
        memoryMB: Double,
        command: String,
        executablePath: String? = nil,
        elapsedTime: String,
        startTime: String = "",
        monotonicStart: MonotonicStart = .notRead,
        isZombie: Bool? = nil,
        netInKB: Double?,
        netOutKB: Double?,
        diskReadBytes: Double?,
        diskWriteBytes: Double?
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.ownerName = ownerName
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.command = command
        self.name = Self.name(from: command)
        self.executablePath = executablePath
        self.identityExecutablePath = Self.standardizedPath(executablePath)
        self.isZombie = isZombie
        self.elapsedTime = elapsedTime
        self.startTime = startTime
        self.monotonicStart = monotonicStart
        self.netInKB = netInKB
        self.netOutKB = netOutKB
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
    }

    /// An exited, unreaped process must not be signalled. The kernel's process
    /// state decides: `ps comm` is argv-backed, so a live process can call
    /// itself `<defunct>`. Only a row whose state was not read falls back to
    /// that text with no resolvable executable. A missing path alone is not
    /// exit evidence: live processes can also have unreadable paths.
    var hasExited: Bool {
        isZombie ?? (executablePath == nil && command.trimmingCharacters(in: .whitespacesAndNewlines) == "<defunct>")
    }

    var id: Int32 {
        pid
    }

    /// The Network column's value: kilobytes per second received plus sent;
    /// nil until the process has a rate.
    var networkSortValue: Double? {
        guard let netInRateKBps, let netOutRateKBps else { return nil }
        return netInRateKBps + netOutRateKBps
    }

    /// The Disk column's value: bytes per second read plus written; nil until
    /// the process has a rate.
    var diskSortValue: Double? {
        guard let diskReadRateBytesPerSecond, let diskWriteRateBytesPerSecond else { return nil }
        return diskReadRateBytesPerSecond + diskWriteRateBytesPerSecond
    }

    /// `command` is the argv-backed `ps comm` value. An absolute path names its
    /// last component. Anything else may be a title the process wrote over
    /// argv[0] (`sshd-session: me@ttys001`, `ssh: /path/to/socket [mux]`), where
    /// a '/' is free text rather than a path separator, so the name is the
    /// leading token up to the first whitespace or ':'. A leading token that is
    /// itself a relative path (`./build/tool`) names its last component. A
    /// command with no '/' at all keeps its whole text, as it always has.
    static func name(from command: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return "" }
        if trimmedCommand.hasPrefix("/") {
            let lastPathComponent = (trimmedCommand as NSString).lastPathComponent
            return lastPathComponent.isEmpty || lastPathComponent == "/" ? trimmedCommand : lastPathComponent
        }
        guard trimmedCommand.contains("/") else { return trimmedCommand }
        let token = trimmedCommand.prefix { !$0.isWhitespace && $0 != ":" }
        guard !token.isEmpty else { return trimmedCommand }
        guard token.contains("/") else { return String(token) }
        let lastPathComponent = (String(token) as NSString).lastPathComponent
        return lastPathComponent.isEmpty || lastPathComponent == "/" ? String(token) : lastPathComponent
    }

    /// The executable path with the home directory abbreviated. Only an exact
    /// match or a `home/` prefix is replaced, so `/Users/alicedata/...` is not
    /// rewritten for user `alice`.
    var displayCommand: String {
        let path = executablePath ?? command
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var identity: ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTime: startTime,
            command: command,
            executablePath: identityExecutablePath
        )
    }

    private static func standardizedPath(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL.path }
    }

    /// Runtime reported by `ps etime`, whose shape is `[[dd-]hh:]mm:ss`. It is
    /// the current wall clock minus the wall-clock start, so a forward clock
    /// step overstates it; see `monotonicStart`.
    var runtimeSeconds: TimeInterval? {
        let normalizedElapsedTime = elapsedTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedElapsedTime.isEmpty else { return nil }
        let dayAndClock = normalizedElapsedTime.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard dayAndClock.count == 1 || dayAndClock.count == 2 else { return nil }
        let dayCount: Int
        let clock: Substring
        if dayAndClock.count == 2 {
            guard !dayAndClock[0].isEmpty,
                  !dayAndClock[1].isEmpty,
                  let parsedDays = Int(dayAndClock[0]) else { return nil }
            dayCount = parsedDays
            clock = dayAndClock[1]
        } else {
            dayCount = 0
            clock = dayAndClock[0]
        }

        let rawComponents = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard rawComponents.count == 2 || rawComponents.count == 3 else { return nil }
        var components: [Int] = []
        for component in rawComponents {
            guard let value = Int(component), value >= 0 else { return nil }
            components.append(value)
        }
        let hours = components.count == 3 ? components[0] : 0
        let minutes = components[components.count - 2]
        let seconds = components[components.count - 1]
        guard dayCount >= 0,
              (dayAndClock.count == 1 || hours < 24),
              minutes < 60,
              seconds < 60 else { return nil }
        let (daySeconds, dayOverflow) = dayCount.multipliedReportingOverflow(by: 86_400)
        let (hourSeconds, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600)
        let (minuteSeconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60)
        guard !dayOverflow, !hourOverflow, !minuteOverflow else { return nil }
        let (dayAndHourSeconds, firstAdditionOverflow) = daySeconds.addingReportingOverflow(hourSeconds)
        let (throughMinutes, secondAdditionOverflow) = dayAndHourSeconds.addingReportingOverflow(minuteSeconds)
        let (totalSeconds, finalAdditionOverflow) = throughMinutes.addingReportingOverflow(seconds)
        guard !firstAdditionOverflow, !secondAdditionOverflow, !finalAdditionOverflow else { return nil }
        return TimeInterval(totalSeconds)
    }
}

struct ProcessDetail: Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32
    var user: String
    var startTime: String
    var command: String
    /// The command line, read only for the detail sheet the user asked for,
    /// with the row's identity checked around the read. It can contain
    /// secrets, so it is never logged, persisted or exported.
    var commandLine: CommandLineReadResult = .unavailable("The command line was not read.")
    /// Read from the kernel, with the row's identity checked before and after.
    var executablePath: ProcessDetailValue<String> = .unavailable(Self.notRead)
    var parent: ProcessParent = .unavailable(Self.notRead)
    var threadCount: ProcessDetailValue<Int> = .unavailable(Self.notRead)
    var openFiles: ProcessDetailValue<ProcessOpenFiles> = .unavailable(Self.notRead)
    var codeSignature: ProcessCodeSignature = .unavailable(Self.notRead)

    static let notRead = "It was not read."

    /// `ps lstart` runs in UTC (see ShellCommandRunner) so identities survive
    /// time-zone changes; show it in the viewer's time zone.
    func displayStartTime(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let date = Self.parsedStartTime(startTime) else { return "\(startTime) UTC" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    /// The instant a UTC `ps lstart` value names, or nil when it does not parse.
    static func parsedStartTime(_ lstart: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return parser.date(from: lstart)
    }
}
