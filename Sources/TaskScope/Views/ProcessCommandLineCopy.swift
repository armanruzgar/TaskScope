import AppKit

/// Copy Command Line: the row's command line reaches the clipboard only if its
/// PID still has the row's identity. The status message never contains it.
enum ProcessCommandLineCopy {
    /// Marks clipboard data as confidential, so clipboard-history tools that
    /// follow the nspasteboard.org convention do not keep it.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Reads the command line for `process` and writes it with `write`, or
    /// writes nothing when it cannot be read. Returns the status message.
    @MainActor
    static func perform(
        for process: AppProcess,
        read: (AppProcess) async -> CommandLineReadResult,
        write: (String) -> Void
    ) async -> String {
        let label = "\(process.name) (PID \(String(process.pid)))"
        let result = await read(process)
        guard let commandLine = result.commandLine else {
            return "Could not copy the command line of \(label). \(result.message ?? "It could not be read.")"
        }
        write(commandLine)
        return "Copied the command line of \(label)."
    }

    @MainActor
    static func writeToClipboard(_ commandLine: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(commandLine, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
    }
}
