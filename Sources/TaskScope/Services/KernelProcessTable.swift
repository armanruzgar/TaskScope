import Darwin

/// One process as the kernel's process table, `sysctl(KERN_PROC)`, reports it.
/// Unlike libproc's `PROC_PIDTBSDINFO`, the table is readable by an
/// unprivileged caller for every process, other users' included.
struct KernelProcessEntry: Equatable, Sendable {
    var pid: Int32
    var parentPID: Int32
    /// The effective user id.
    var uid: uid_t
    /// `p_starttime`, in seconds since the epoch, plus its microseconds.
    var startSeconds: Int
    var startMicroseconds: Int
    /// `p_stat == SZOMB`: the process has exited and only awaits its parent's
    /// `waitpid`.
    var isZombie: Bool

    init(
        pid: Int32,
        parentPID: Int32,
        uid: uid_t,
        startSeconds: Int,
        startMicroseconds: Int = 0,
        isZombie: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.isZombie = isZombie
    }

    init(_ info: kinfo_proc) {
        self.init(
            pid: info.kp_proc.p_pid,
            parentPID: info.kp_eproc.e_ppid,
            uid: info.kp_eproc.e_ucred.cr_uid,
            startSeconds: Int(info.kp_proc.p_starttime.tv_sec),
            startMicroseconds: Int(info.kp_proc.p_starttime.tv_usec),
            isZombie: info.kp_proc.p_stat == UInt8(SZOMB)
        )
    }

    /// The start time as the inventory's `ps lstart` text, so it compares
    /// directly with `ProcessIdentity.startTime`.
    var startTimeText: String {
        ProcessStartTime.psText(epochSeconds: startSeconds)
    }
}

enum KernelProcessTable {
    enum Lookup: Equatable, Sendable {
        case found(KernelProcessEntry)
        /// No process has that PID.
        case notFound
        /// The table could not be read; `errno` says why.
        case failed(errno: Int32)
    }

    /// The table entry for one PID.
    static func entry(for pid: Int32) -> Lookup {
        guard pid > 0 else { return .notFound }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return .failed(errno: errno) }
        // A PID that is not running returns success with no entry.
        guard size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return .notFound }
        return .found(KernelProcessEntry(info))
    }
}

/// The one conversion between a kernel start time and the inventory's
/// `ps lstart` text.
enum ProcessStartTime {
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `epochSeconds` as `ps lstart` prints it in TaskScope's child environment
    /// (C locale, UTC), with the day's padding collapsed as the inventory
    /// parser collapses it: `Sun Nov 1 09:05:03 2026`. This is the text
    /// `DateFormatter` produces with the `en_US_POSIX` locale, UTC and
    /// `"EEE MMM d HH:mm:ss yyyy"`, built without one so that a whole process
    /// table can be converted cheaply and from any thread.
    static func psText(epochSeconds: Int) -> String {
        var time = time_t(epochSeconds)
        var parts = tm()
        guard gmtime_r(&time, &parts) != nil,
              weekdays.indices.contains(Int(parts.tm_wday)),
              months.indices.contains(Int(parts.tm_mon)) else { return "" }
        let year = Int(parts.tm_year) + 1900
        let yearText = year >= 0 && year < 1000 ? padded(year, width: 4) : String(year)
        return "\(weekdays[Int(parts.tm_wday)]) \(months[Int(parts.tm_mon)]) \(parts.tm_mday) "
            + "\(padded(Int(parts.tm_hour), width: 2)):\(padded(Int(parts.tm_min), width: 2)):"
            + "\(padded(Int(parts.tm_sec), width: 2)) \(yearText)"
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
