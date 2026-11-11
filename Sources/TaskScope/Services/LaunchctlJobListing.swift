import Foundation

/// The one reader of `launchctl print <domain>/<label>` output.
///
/// launchctl prints XPC data and UUID values as nothing and without a newline,
/// so a dictionary's closing brace can end a value line and brace counting
/// loses its place. The job's own attributes are the lines indented by
/// exactly one tab; the listing is complete when it opens with `<target> = {`
/// and closes with a lone `}`. The output is not API, so anything else is
/// treated as unknown, never as absent or idle.
enum LaunchctlJobListing {
    static func isComplete(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").filter { !$0.isEmpty }
        return lines.first?.hasSuffix(" = {") == true && lines.last == "}"
    }

    /// The job's own pid. Nested pids and keys such as `pid-local endpoints`
    /// are not the job's pid.
    static func pid(_ output: String) -> Int32? {
        guard isComplete(output) else { return nil }
        let lines = attributeLines(output, key: "pid")
        guard lines.count == 1, let line = lines.first,
              line.range(of: #"^\tpid = [0-9]+$"#, options: .regularExpression) != nil,
              let value = Int32(line.dropFirst("\tpid = ".count)), value > 1 else { return nil }
        return value
    }

    /// A complete listing of a loaded job with exactly one non-running state
    /// and no pid line describes a job without a running process.
    static func hasNoRunningPID(_ output: String) -> Bool {
        guard isComplete(output), attributeLines(output, key: "pid").isEmpty else { return false }
        let states = attributeLines(output, key: "state")
        guard states.count == 1, let state = states.first else { return false }
        let value = state.dropFirst("\tstate = ".count)
        return !value.isEmpty && value != "running"
    }

    /// launchd's answer for a service it does not have: exit 113 and the
    /// not-found text naming this label. A bare 113, another label, a signal,
    /// or a timeout says nothing about the job.
    static func confirmsAbsence(_ result: ShellCommandResult, label: String) -> Bool {
        result.terminatedBySignal == nil && result.exitCode == 113
            && (result.stdout + "\n" + result.stderr).contains("Could not find service \"\(label)\" in domain")
    }

    static func plistLabel(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any] else { return nil }
        return normalizedLabel(dictionary["Label"] as? String)
    }

    static func normalizedLabel(_ value: String?) -> String? {
        guard let label = value?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return label
    }

    private static func attributeLines(_ output: String, key: String) -> [Substring] {
        output.split(separator: "\n").filter { $0.hasPrefix("\t\(key) = ") }
    }
}
