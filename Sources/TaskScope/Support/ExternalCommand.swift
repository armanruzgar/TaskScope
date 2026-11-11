/// One program and its arguments, run by `ShellCommandRunner` without a shell.
///
/// Nothing parses these strings: `posix_spawn` receives `executable` followed
/// by `arguments` as the argument vector, so a value with spaces, quotes, `$`,
/// `;`, `*` or a line break reaches the program as one unchanged argument and
/// cannot become another command. The program path is never looked up in
/// `PATH`; the runner refuses one that is not absolute.
struct ExternalCommand: Hashable, Sendable, CustomStringConvertible {
    /// Absolute path of the program, which is also its `argv[0]`.
    var executable: String
    /// Everything after `argv[0]`, passed through unchanged.
    var arguments: [String]

    init(_ executable: String, _ arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    /// `/bin/launchctl` with the given arguments.
    static func launchctl(_ arguments: String...) -> ExternalCommand {
        ExternalCommand("/bin/launchctl", arguments)
    }

    /// Shows macOS's administrator prompt with `prompt`, then runs `script` as
    /// root with `/bin/sh` (AppleScript's `do shell script`). The AppleScript is
    /// osascript's single `-e` argument, so no shell reads it on the way: the
    /// only quoting left is the script's own, inside one AppleScript string
    /// literal, and the script must quote every value it names.
    static func administratorScript(_ script: String, prompt: String) -> ExternalCommand {
        let appleScript = "do shell script \(ShellCommandRunner.appleScriptString(script))"
            + " with administrator privileges with prompt \(ShellCommandRunner.appleScriptString(prompt))"
        return ExternalCommand("/usr/bin/osascript", ["-e", appleScript])
    }

    /// The complete argument vector, `argv[0]` first.
    var argumentVector: [String] {
        [executable] + arguments
    }

    /// A readable rendering for results, logs and test failures: each word a
    /// shell would read unchanged stays bare, and every other word is
    /// single-quoted, so the text names the same argument vector. It is never
    /// run.
    var description: String {
        argumentVector.map(Self.displayWord).joined(separator: " ")
    }

    /// Why the runner must not start this argument vector, or nil when it can.
    /// A path that is not absolute would be resolved against the current
    /// directory, and a NUL character would silently cut its argument short,
    /// so the program would see a different argument than the caller built.
    static func startProblem(argumentVector: [String]) -> String? {
        guard let program = argumentVector.first, program.hasPrefix("/") else {
            return "its program path is not absolute"
        }
        guard !argumentVector.contains(where: { $0.utf8.contains(0) }) else {
            return "an argument contains a NUL character"
        }
        return nil
    }

    private static func displayWord(_ word: String) -> String {
        let isPlain = !word.isEmpty && !word.hasPrefix("=") && word.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (plainPunctuation.contains(scalar) || scalar.properties.isAlphabetic
                || ("0"..."9").contains(scalar))
        }
        return isPlain ? word : ShellCommandRunner.shellQuoted(word)
    }

    private static let plainPunctuation: Set<Unicode.Scalar> = ["_", "@", "%", "+", "=", ":", ",", ".", "/", "-"]
}
