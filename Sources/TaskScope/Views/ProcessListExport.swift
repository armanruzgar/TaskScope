import AppKit
import UniformTypeIdentifiers

/// Where Copy Visible Rows and Export Visible Rows send the table.
@MainActor
enum ProcessListExport {
    /// Plain text, and the same text as tab-separated values so a spreadsheet
    /// pastes it as a table.
    static func writeToClipboard(_ table: ProcessListTable, pasteboard: NSPasteboard = .general) {
        let text = table.tabSeparated
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: .tabularText)
    }

    /// An app-modal save panel, like the menu-bar popover's confirmations, so
    /// it works from the popover as well as the window. Nil when cancelled.
    static func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Visible Rows"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApplication.shared.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func suggestedFileName(at date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "TaskScope Processes \(formatter.string(from: date)).csv"
    }

    static func rowCount(_ count: Int) -> String {
        count == 1 ? "1 row" : "\(count) rows"
    }
}
