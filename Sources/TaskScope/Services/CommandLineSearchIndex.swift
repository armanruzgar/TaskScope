import Darwin
import Foundation

/// The command lines of the current user's listed processes, for search only.
///
/// The list reads them in-process, with no child process, only while the
/// search field has text, and once per inventory; they live only as long as
/// that inventory's list and are never shown, stored, logged or exported.
/// Other users' processes are left out: macOS shows their arguments only to
/// `ps`, which would add a child process to every refresh. Arguments are
/// joined by single spaces and A–Z is folded to lowercase, so a search can
/// span arguments and ignores case.
struct CommandLineSearchIndex: Sendable {
    private var folded: [Int32: [UInt8]]

    init(folded: [Int32: [UInt8]] = [:]) {
        self.folded = folded
    }

    var count: Int { folded.count }

    /// Search text folded the same way, compared as bytes.
    struct Query: Hashable, Sendable {
        let bytes: [UInt8]

        init(_ text: String) {
            bytes = CommandLineSearchIndex.fold(Array(text.utf8))
        }
    }

    func contains(_ query: Query, in pid: Int32) -> Bool {
        guard !query.bytes.isEmpty, let line = folded[pid], line.count >= query.bytes.count else { return false }
        return line.withUnsafeBytes { haystack in
            query.bytes.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    static func fold(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
    }

    /// Reads the index for `inventory`. Only the current user's rows are read,
    /// and a row is kept only if the process table, read after the arguments,
    /// still shows its PID running with the row's start time.
    static func read(
        for inventory: [AppProcess],
        currentUID: uid_t = getuid(),
        arguments: (Int32, UnsafeMutableRawBufferPointer) -> [UInt8]? = { KernelProcessArguments.foldedCommandLine(pid: $0, into: $1) },
        table: () -> KernelProcessTable.TableRead = { KernelProcessTable.allEntries() }
    ) -> CommandLineSearchIndex {
        let own = inventory.filter { $0.uid == currentUID && !$0.startTime.isEmpty }
        guard !own.isEmpty else { return CommandLineSearchIndex() }
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: KernelProcessArguments.maximumArgumentBytes,
            alignment: MemoryLayout<Int32>.alignment
        )
        defer { buffer.deallocate() }
        var read: [Int32: [UInt8]] = [:]
        read.reserveCapacity(own.count)
        for process in own {
            if let line = arguments(process.pid, buffer), !line.isEmpty {
                read[process.pid] = line
            }
        }
        guard !read.isEmpty, case .entries(let entries) = table() else { return CommandLineSearchIndex() }
        for process in own where read[process.pid] != nil {
            guard let entry = entries[process.pid], !entry.isZombie, entry.startTimeText == process.startTime else {
                read[process.pid] = nil
                continue
            }
        }
        return CommandLineSearchIndex(folded: read)
    }
}
