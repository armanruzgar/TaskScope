import Darwin
import Foundation

/// Account names for the user ids the process list shows, as `ps -o user=`
/// prints them. Each id is looked up once; an id with no account shows as
/// its number.
enum ProcessOwnerNames {
    private static let cache = Cache()

    static func name(for uid: uid_t) -> String {
        cache.name(for: uid)
    }

    static func lookUp(_ uid: uid_t) -> String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var capacity = max(1_024, sysconf(Int32(_SC_GETPW_R_SIZE_MAX)))
        while capacity <= 1 << 20 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let status = getpwuid_r(uid, &entry, &buffer, buffer.count, &result)
            if status == ERANGE {
                capacity *= 2
                continue
            }
            guard status == 0, result != nil, let name = entry.pw_name else { break }
            let text = String(cString: name)
            return text.isEmpty ? String(uid) : text
        }
        return String(uid)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [uid_t: String] = [:]

        func name(for uid: uid_t) -> String {
            if let cached = lock.withLock({ names[uid] }) { return cached }
            let resolved = ProcessOwnerNames.lookUp(uid)
            lock.withLock { names[uid] = resolved }
            return resolved
        }
    }
}
