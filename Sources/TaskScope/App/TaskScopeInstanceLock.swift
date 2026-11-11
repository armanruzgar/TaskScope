import Darwin
import Foundation

/// What the single-instance lock file says about the copy that holds it: one
/// line, `<pid> <start time> <running|quitting>`.
struct TaskScopeInstanceRecord: Equatable, Sendable {
    enum State: String, Sendable {
        case running
        /// The copy is quitting but still has an action to finish or stop, so
        /// it keeps the lock until then. A new launch waits for it instead of
        /// handing off to it.
        case quitting
    }

    var processID: pid_t
    /// The kernel's start time, which tells the holder apart from a later
    /// process that reuses its PID.
    var startTime: TimeInterval
    var state: State

    var encoded: String { "\(processID) \(startTime) \(state.rawValue)\n" }

    init(processID: pid_t, startTime: TimeInterval, state: State) {
        self.processID = processID
        self.startTime = startTime
        self.state = state
    }

    /// Accepts exactly what `encoded` writes and nothing else.
    init?(decoding text: String) {
        guard text.hasSuffix("\n") else { return nil }
        let fields = text.dropLast().split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let processID = pid_t(fields[0]), processID > 0,
              let startTime = TimeInterval(fields[1]), startTime.isFinite,
              let state = State(rawValue: String(fields[2])) else {
            return nil
        }
        self.init(processID: processID, startTime: startTime, state: state)
        guard encoded == text else { return nil }
    }
}

enum TaskScopeInstanceLockAttempt: Equatable, Sendable {
    /// This launch holds the lock now, and the file names it.
    case acquired
    /// Another process holds the lock: the record it wrote, or nil if the file
    /// holds none (the holder writes it right after locking).
    case held(TaskScopeInstanceRecord?)
    /// The lock file could not be created, opened or locked.
    case unavailable
}

/// The per-user single-instance lock (A01-8). The running TaskScope holds it
/// for its lifetime and lets it go while quitting, before the process exits;
/// the kernel drops it if the app crashes. Injected so launch admission and the
/// quit path can be tested without the real file.
@MainActor
struct TaskScopeInstanceLock {
    /// Tries once, without waiting. On success the file names `record`.
    var acquire: @MainActor (_ record: TaskScopeInstanceRecord) -> TaskScopeInstanceLockAttempt
    /// Rewrites the holder's record. Does nothing unless this process holds the lock.
    var update: @MainActor (_ record: TaskScopeInstanceRecord) -> Void
    /// Empties the record and lets the lock go. Does nothing unless this
    /// process holds the lock.
    var release: @MainActor () -> Void

    static let fileName = "Instance.lock"

    static func file(at url: URL) -> TaskScopeInstanceLock {
        let file = TaskScopeInstanceLockFile(url: url)
        return TaskScopeInstanceLock(
            acquire: { file.acquire(as: $0) },
            update: { file.update($0) },
            release: { file.release() }
        )
    }

    /// `~/Library/Application Support/<bundle id>/Instance.lock`: one lock per
    /// user and bundle identifier, so a staged copy with its own identifier
    /// never meets the installed app's lock. Nil without a valid identifier.
    static func fileURL(bundleIdentifier: String?, applicationSupport: URL?) -> URL? {
        guard let bundleIdentifier, let applicationSupport,
              isValidBundleIdentifier(bundleIdentifier) else {
            return nil
        }
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Only the characters a bundle identifier may contain (letters, digits,
    /// hyphens and periods), so it is always one ordinary path component.
    private static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && !identifier.hasPrefix(".") && identifier.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "." || $0 == "-"
        }
    }
}

/// The lock itself: an exclusive, non-blocking `flock(2)` on a file that is
/// never deleted. The lock belongs to the open file description, so the kernel
/// drops it when the holder exits or crashes, and the descriptor is
/// close-on-exec, so no command or app TaskScope starts can keep it alive.
final class TaskScopeInstanceLockFile {
    let url: URL
    /// The holder's descriptor; -1 while this object does not hold the lock.
    private var descriptor: Int32 = -1
    /// A record is one short line; anything longer is not one.
    private static let recordLimit = 128

    init(url: URL) {
        self.url = url
    }

    deinit {
        // What the kernel does when the holder dies: the lock goes, the record stays.
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    func acquire(as record: TaskScopeInstanceRecord) -> TaskScopeInstanceLockAttempt {
        if descriptor >= 0 {
            write(record)
            return .acquired
        }
        guard let candidate = openLockFile() else { return .unavailable }
        if flock(candidate, LOCK_EX | LOCK_NB) == 0 {
            descriptor = candidate
            write(record)
            return .acquired
        }
        let failure = errno
        defer { close(candidate) }
        return failure == EWOULDBLOCK ? .held(readRecord(candidate)) : .unavailable
    }

    func update(_ record: TaskScopeInstanceRecord) {
        guard descriptor >= 0 else { return }
        write(record)
    }

    func release() {
        guard descriptor >= 0 else { return }
        // Empty the file before unlocking, so a launch never takes this copy's
        // record for the next holder's.
        _ = ftruncate(descriptor, 0)
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// A regular file only: `O_NOFOLLOW` refuses a symbolic link at the path,
    /// and `O_NONBLOCK` keeps a FIFO there from blocking the launch.
    private func openLockFile() -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        let candidate = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard candidate >= 0 else { return nil }
        var status = stat()
        guard fstat(candidate, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(candidate)
            return nil
        }
        return candidate
    }

    private func write(_ record: TaskScopeInstanceRecord) {
        let bytes = Array(record.encoded.utf8)
        // A launch that reads between these calls finds no record and tries again.
        guard ftruncate(descriptor, 0) == 0 else { return }
        _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    private func readRecord(_ candidate: Int32) -> TaskScopeInstanceRecord? {
        var buffer = [UInt8](repeating: 0, count: Self.recordLimit)
        let count = buffer.withUnsafeMutableBytes { pread(candidate, $0.baseAddress, $0.count, 0) }
        guard count > 0, count < Self.recordLimit else { return nil }
        return TaskScopeInstanceRecord(decoding: String(decoding: buffer[..<count], as: UTF8.self))
    }
}
