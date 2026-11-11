import Darwin
import Foundation

enum AutoStopRuleValidation {
    static let maximumRuntimeMinutes = 1_440
    /// `ps` reports 100% per fully used core, so a busy process can exceed 100.
    static let cpuPercentRange = 1...10_000
    static let memoryMBRange = 1...1_048_576
    /// At the 10-second engine cadence, up to an hour.
    static let sustainedChecksRange = 1...360
    static let maximumCommandLineTextLength = 1_000

    struct Failure: Error, Equatable {
        var message: String
    }

    /// The form both stored rule paths and inventory paths are compared in:
    /// symlinks resolved through `realpath(3)` when the file exists, so a rule
    /// written as `/opt/homebrew/bin/node` matches the Cellar binary the kernel
    /// reports as the executable. A path that does not exist keeps Foundation's
    /// best-effort resolution.
    static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let standardizedLHS = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let standardizedRHS = URL(fileURLWithPath: rhs).standardizedFileURL.path
        return standardizedLHS == standardizedRHS
            || canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func validate(_ rule: AutoStopRule) -> Result<AutoStopRule, Failure> {
        var normalized = rule
        normalized.processName = rule.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = rule.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPath, !trimmedPath.isEmpty, !trimmedPath.hasPrefix("/") {
            return .failure(Failure(message: "Executable path must be absolute."))
        }
        normalized.executablePath = trimmedPath.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard !normalized.processName.isEmpty else {
            return .failure(Failure(message: "Process name is required."))
        }
        guard (1...maximumRuntimeMinutes).contains(normalized.runtimeMinutes) else {
            return .failure(Failure(
                message: "Runtime must be between 1 and \(maximumRuntimeMinutes) minutes."
            ))
        }
        // A rule from a newer build may test only a condition this build does
        // not know; it is kept disabled and read-only, not refused.
        guard normalized.checksRuntime || normalized.hasSampledConditions || normalized.hasUnknownFields else {
            return .failure(Failure(message: "Choose at least one condition: run time, CPU, or memory."))
        }
        if let cpu = normalized.cpuPercentAtLeast, !cpuPercentRange.contains(cpu) {
            return .failure(Failure(
                message: "CPU must be between \(cpuPercentRange.lowerBound)% and \(cpuPercentRange.upperBound.formatted(.number))%."
            ))
        }
        if let memory = normalized.memoryMBAtLeast, !memoryMBRange.contains(memory) {
            return .failure(Failure(
                message: "Memory must be between \(memoryMBRange.lowerBound) and \(AutoStopRule.megabytes(memoryMBRange.upperBound))."
            ))
        }
        if normalized.hasSampledConditions {
            guard sustainedChecksRange.contains(normalized.sustainedChecks) else {
                return .failure(Failure(
                    message: "Checks in a row must be between \(sustainedChecksRange.lowerBound) and \(sustainedChecksRange.upperBound)."
                ))
            }
        } else {
            // Unused without a CPU or memory condition, and not stored then.
            normalized.sustainedChecks = AutoStopRule.defaultSustainedChecks
        }
        if let text = normalized.commandLineContains {
            // Kept exactly as typed: it is plain text, and a leading or
            // trailing space can be part of what it must match.
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(Failure(message: "Enter the text the command line must contain."))
            }
            guard !text.contains(where: \.isNewline) else {
                return .failure(Failure(message: "The command line text must be on one line."))
            }
            guard text.count <= maximumCommandLineTextLength else {
                return .failure(Failure(
                    message: "The command line text can be at most \(maximumCommandLineTextLength.formatted(.number)) characters."
                ))
            }
        }
        if normalized.action == .kill,
           normalized.isEnabled,
           normalized.executablePath == nil {
            return .failure(Failure(
                message: "Auto Stop requires a trusted executable path. Use Prompt or Log Only for name-only rules."
            ))
        }
        return .success(normalized)
    }

    /// Extra checks for a rule the user adds or edits: a process name is never a
    /// path, and an executable path is never a directory, because the engine
    /// could never match either. They are deliberately not part of `validate`,
    /// so stored rules are not sent to recovery at load, and an edit that keeps
    /// a stored rule's name and path (switching it off, for example) still saves.
    static func validateForEditing(
        _ rule: AutoStopRule,
        replacing stored: AutoStopRule? = nil
    ) -> Result<AutoStopRule, Failure> {
        validate(rule).flatMap { normalized in
            if let stored,
               stored.processName == normalized.processName,
               stored.executablePath == normalized.executablePath {
                return .success(normalized)
            }
            guard !normalized.processName.contains("/") else {
                return .failure(Failure(message: "Enter the process name (for example node); put a path in Executable path."))
            }
            if let path = normalized.executablePath, isDirectory(path) {
                let suggestion = Bundle(path: path)?.executableURL.map { " Use \($0.path)." } ?? " Choose the executable file inside the directory."
                return .failure(Failure(message: "Executable path points to a directory." + suggestion))
            }
            return .success(normalized)
        }
    }

    /// A non-blocking note for an executable path that cannot match anything
    /// yet. A missing file is not refused, because a rule may target a binary
    /// that is installed later.
    static func pathWarning(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else { return nil }
        if isDirectory(path) {
            return "Executable path points to a directory, so this rule never matches."
        }
        guard !FileManager.default.fileExists(atPath: path) else { return nil }
        return "Executable path does not exist. This rule will match only after the executable is installed at that path."
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func validateStored(
        _ candidates: [AutoStopRule]
    ) -> (rules: [AutoStopRule], rejectedCount: Int) {
        var accepted: [AutoStopRule] = []
        var seenIDs: Set<UUID> = []
        var rejectedCount = 0

        for candidate in candidates {
            var safelyMigrated = candidate
            // Older destructive rules were name-only. Preserve them for review but
            // disable them until the user supplies an executable path.
            if safelyMigrated.action == .kill, safelyMigrated.executablePath == nil {
                safelyMigrated.isEnabled = false
            }
            // Every mutation addresses rules by id, so a repeated id is rejected
            // like a repeated name. Names are compared exactly as `add`, `update`
            // and the engine compare them.
            guard case .success(let normalized) = validate(safelyMigrated),
                  !seenIDs.contains(normalized.id),
                  !accepted.contains(where: {
                      $0.processName.caseInsensitiveCompare(normalized.processName) == .orderedSame
                  }) else {
                rejectedCount += 1
                continue
            }
            seenIDs.insert(normalized.id)
            accepted.append(normalized)
        }
        return (accepted, rejectedCount)
    }
}
