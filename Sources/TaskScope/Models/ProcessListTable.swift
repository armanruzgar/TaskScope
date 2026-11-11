import Foundation

/// The rows and columns on screen as text: tab-separated for Copy Visible
/// Rows and CSV for Export Visible Rows. It has the list's own columns and
/// never a command line.
struct ProcessListTable: Equatable {
    enum Column: CaseIterable, Sendable {
        case name
        case pid
        case path
        case parentPID
        case user
        case networkIn
        case networkOut
        case diskRead
        case diskWrite
        case cpu
        case memory

        var title: String {
            switch self {
            case .name: "Name"
            case .pid: "PID"
            case .path: "Executable"
            case .parentPID: "PPID"
            case .user: "User"
            case .networkIn: "Net In KB/s"
            case .networkOut: "Net Out KB/s"
            case .diskRead: "Disk Read MB/s"
            case .diskWrite: "Disk Write MB/s"
            case .cpu: "CPU %"
            case .memory: "Memory MB"
            }
        }

        var isText: Bool {
            self == .name || self == .path || self == .user
        }

        /// The value as the list shows it, with a period for decimals and no
        /// digit grouping; empty when the list shows a dash.
        func value(for process: AppProcess) -> String {
            switch self {
            case .name: process.name
            case .pid: String(process.pid)
            case .path: process.executablePath ?? process.command
            case .parentPID: String(process.parentPID)
            case .user: process.ownerName ?? ""
            case .networkIn: Self.decimal(process.netInRateKBps, places: 1)
            case .networkOut: Self.decimal(process.netOutRateKBps, places: 1)
            case .diskRead: Self.decimal(process.diskReadRateBytesPerSecond.map { $0 / 1_048_576 }, places: 1)
            case .diskWrite: Self.decimal(process.diskWriteRateBytesPerSecond.map { $0 / 1_048_576 }, places: 1)
            case .cpu: Self.decimal(process.cpu, places: 1)
            case .memory: Self.decimal(process.memoryMB, places: 0)
            }
        }

        private static func decimal(_ value: Double?, places: Int) -> String {
            guard let value else { return "" }
            return String(format: "%.*f", places, value)
        }
    }

    var columns: [Column]
    var rows: [AppProcess]

    /// The columns each presentation shows: the menu-bar popover has the name
    /// (with the PID and path under it), CPU and memory; the window adds PPID,
    /// user, network and disk.
    static func columns(expandedWindow: Bool) -> [Column] {
        expandedWindow
            ? [.name, .pid, .path, .parentPID, .user, .networkIn, .networkOut, .diskRead, .diskWrite, .cpu, .memory]
            : [.name, .pid, .path, .cpu, .memory]
    }

    /// One line per row after the column titles. Tabs and line breaks inside
    /// a value become spaces.
    var tabSeparated: String {
        lines { String($0.map { $0 == "\t" || $0.isNewline ? " " : $0 }) }
            .map { $0.joined(separator: "\t") }
            .joined(separator: "\n") + "\n"
    }

    /// RFC 4180: CRLF line ends, and a value with a comma, quote or line break
    /// is quoted with its quotes doubled.
    var commaSeparated: String {
        lines { text in
            guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        .map { $0.joined(separator: ",") }
        .joined(separator: "\r\n") + "\r\n"
    }

    private func lines(_ field: (String) -> String) -> [[String]] {
        [columns.map { field($0.title) }]
            + rows.map { process in
                columns.map { column in
                    let value = column.value(for: process)
                    return field(column.isText ? Self.spreadsheetSafe(value) : value)
                }
            }
    }

    /// A process can be named `=HYPERLINK(...)`, and a login shell is named
    /// `-zsh`: a spreadsheet would run the first and break the second, so text
    /// starting with one of = + - @ is kept as text with a leading apostrophe.
    static func spreadsheetSafe(_ value: String) -> String {
        guard let first = value.first, "=+-@".contains(first) else { return value }
        return "'" + value
    }
}
