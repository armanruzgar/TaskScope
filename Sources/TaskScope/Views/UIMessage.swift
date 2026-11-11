import Foundation

enum UIMessage {
    /// Error text from tools and the system (ps, stderr, strerror) as one
    /// sentence: trimmed, on one line, and ending with exactly one full stop,
    /// so it reads correctly when it is embedded in a longer message.
    static func sentence(_ text: String, fallback: String = "An unknown error occurred.") -> String {
        var line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while line.hasSuffix(".") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return fallback }
        if line.hasSuffix("?") || line.hasSuffix("!") { return line }
        return line + "."
    }
}
