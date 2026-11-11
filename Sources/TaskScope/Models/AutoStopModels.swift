import Foundation

struct AutoStopRule: Codable, Identifiable, Equatable {
    static let defaultSustainedChecks = 3

    var id: UUID = UUID()
    var processName: String
    var executablePath: String?
    /// The run-time condition's threshold in minutes. It is kept, and stored,
    /// while that condition is off: switching it back on restores the value,
    /// and builds before the CPU and memory conditions require the field.
    var runtimeMinutes: Int
    /// Whether the process must have run for `runtimeMinutes` before the rule
    /// acts. A rule can instead (or also) test CPU or memory use.
    var checksRuntime = true
    /// CPU use as `ps` reports it, where 100 is one fully used core, that must
    /// hold for `sustainedChecks` engine checks in a row.
    var cpuPercentAtLeast: Int?
    /// Resident memory, in megabytes, that must hold for `sustainedChecks`
    /// engine checks in a row.
    var memoryMBAtLeast: Int?
    /// How many engine checks in a row the CPU and memory conditions must
    /// hold. `ps` reports CPU as a decaying average, so a single high sample
    /// is weak evidence.
    var sustainedChecks = AutoStopRule.defaultSustainedChecks
    /// Plain text, compared case-sensitively, that the process's command line
    /// must contain. It narrows which processes the rule is about; it is
    /// checked only for processes that already match the name, path and
    /// owner, and only whether it matched is kept: command lines are never
    /// stored or logged.
    var commandLineContains: String?
    var action: Action
    var isEnabled: Bool = true
    private(set) var hasUnknownFields = false

    enum Action: String, Codable, CaseIterable, Identifiable {
        case prompt
        case kill
        case silent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .prompt: "Prompt"
            case .kill: "Auto Stop"
            case .silent: "Log Only"
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, processName, executablePath, runtimeMinutes, action, isEnabled
        case checksRuntime, cpuPercentAtLeast, memoryMBAtLeast, sustainedChecks, commandLineContains
    }

    init(
        id: UUID = UUID(),
        processName: String,
        executablePath: String? = nil,
        runtimeMinutes: Int,
        checksRuntime: Bool = true,
        cpuPercentAtLeast: Int? = nil,
        memoryMBAtLeast: Int? = nil,
        sustainedChecks: Int = AutoStopRule.defaultSustainedChecks,
        commandLineContains: String? = nil,
        action: Action,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.processName = processName
        self.executablePath = executablePath
        self.runtimeMinutes = runtimeMinutes
        self.checksRuntime = checksRuntime
        self.cpuPercentAtLeast = cpuPercentAtLeast
        self.memoryMBAtLeast = memoryMBAtLeast
        self.sustainedChecks = sustainedChecks
        self.commandLineContains = commandLineContains
        self.action = action
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        processName = try container.decode(String.self, forKey: .processName)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        runtimeMinutes = try container.decode(Int.self, forKey: .runtimeMinutes)
        checksRuntime = try container.decodeIfPresent(Bool.self, forKey: .checksRuntime) ?? true
        cpuPercentAtLeast = try container.decodeIfPresent(Int.self, forKey: .cpuPercentAtLeast)
        memoryMBAtLeast = try container.decodeIfPresent(Int.self, forKey: .memoryMBAtLeast)
        sustainedChecks = try container.decodeIfPresent(Int.self, forKey: .sustainedChecks)
            ?? Self.defaultSustainedChecks
        commandLineContains = try container.decodeIfPresent(String.self, forKey: .commandLineContains)
        action = try container.decode(Action.self, forKey: .action)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let allKeys = try decoder.container(keyedBy: AnyRuleCodingKey.self).allKeys
        hasUnknownFields = !Set(allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue)))
        if hasUnknownFields { isEnabled = false }
    }

    /// A rule that tests only run time is written exactly as builds before the
    /// CPU and memory conditions wrote it, so those builds keep using it. A
    /// rule with another condition carries fields those builds do not know,
    /// and they keep it disabled and read-only.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(processName, forKey: .processName)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        try container.encode(runtimeMinutes, forKey: .runtimeMinutes)
        if !checksRuntime { try container.encode(false, forKey: .checksRuntime) }
        try container.encodeIfPresent(cpuPercentAtLeast, forKey: .cpuPercentAtLeast)
        try container.encodeIfPresent(memoryMBAtLeast, forKey: .memoryMBAtLeast)
        if hasSampledConditions { try container.encode(sustainedChecks, forKey: .sustainedChecks) }
        try container.encodeIfPresent(commandLineContains, forKey: .commandLineContains)
        try container.encode(action, forKey: .action)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

extension AutoStopRule {
    /// Whether the rule tests CPU or memory, which must hold for
    /// `sustainedChecks` engine checks in a row.
    var hasSampledConditions: Bool {
        cpuPercentAtLeast != nil || memoryMBAtLeast != nil
    }

    /// Whether run time is the rule's only condition, as for every rule made
    /// before the CPU, memory and command-line conditions.
    var isRuntimeOnly: Bool {
        checksRuntime && !hasSampledConditions && commandLineContains == nil
    }

    /// The least run time, in seconds, before the rule acts; nil when the rule
    /// does not test run time.
    var runtimeFloorSeconds: TimeInterval? {
        checksRuntime ? TimeInterval(runtimeMinutes) * 60 : nil
    }

    /// Whether `process`, as sampled by one engine check, meets every CPU and
    /// memory condition. True for a rule that has none.
    func sampledConditionsHold(for process: AppProcess) -> Bool {
        (cpuPercentAtLeast.map { process.cpu >= Double($0) } ?? true)
            && (memoryMBAtLeast.map { process.memoryMB >= Double($0) } ?? true)
    }

    /// The rule's conditions for its history and its prompt, for example
    /// "After 5 min" or "CPU ≥ 150% for 3 checks". A command-line condition
    /// is named without its text; see `conditionSummary(showingCommandLineText:)`.
    var conditionSummary: String {
        conditionSummary(showingCommandLineText: false)
    }

    /// The rule's conditions; with `showingCommandLineText`, the rule's own
    /// command-line text too, as the rules list and the editors show it.
    func conditionSummary(showingCommandLineText: Bool) -> String {
        var parts: [String] = []
        if checksRuntime { parts.append("After \(runtimeMinutes) min") }
        if hasSampledConditions {
            let sampled = [
                cpuPercentAtLeast.map { "CPU ≥ \($0)%" },
                memoryMBAtLeast.map { "memory ≥ \(Self.megabytes($0))" },
            ].compactMap { $0 }.joined(separator: " and ")
            let checks = sustainedChecks == 1 ? "1 check" : "\(sustainedChecks) checks"
            let clause = "\(sampled) for \(checks)"
            parts.append(parts.isEmpty ? clause.prefix(1).uppercased() + clause.dropFirst() : clause)
        }
        if let text = commandLineContains {
            parts.append(showingCommandLineText ? "command line contains “\(text)”" : "command line contains the rule's text")
        }
        return parts.joined(separator: ", ")
    }

    static func megabytes(_ value: Int) -> String {
        "\(value.formatted(.number)) MB"
    }
}

struct AutoStopPrompt: Identifiable, Equatable {
    var id: AutoStopOccurrence
    var rule: AutoStopRule
    var process: AppProcess
}

struct AutoStopOccurrence: Hashable {
    var ruleID: UUID
    var processIdentity: ProcessIdentity
}

struct AutoStopEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var processName: String
    var pid: Int32
    var ruleID: UUID
    var outcome: Outcome
    var detail: String
    /// The rule's conditions when it acted, worded as `AutoStopRule.conditionSummary`,
    /// for a rule that tests more than run time. Nil for run-time rules and for
    /// events from builds before the CPU and memory conditions.
    var conditions: String?

    enum Outcome: Codable, Hashable {
        case logged
        case stopped
        /// A stop signal was accepted; the exit is confirmed on a later tick.
        case stopRequested
        case failed
        case dismissed
        case processEnded
        /// A value written by another build. Preserved verbatim so the event
        /// survives a round trip and is never misreported as Logged.
        case unknown(String)

        var rawValue: String {
            switch self {
            case .logged: "logged"
            case .stopped: "stopped"
            case .stopRequested: "stopRequested"
            case .failed: "failed"
            case .dismissed: "dismissed"
            case .processEnded: "processEnded"
            case .unknown(let raw): raw
            }
        }

        init(rawValue: String) {
            switch rawValue {
            case "logged": self = .logged
            case "stopped": self = .stopped
            case "stopRequested": self = .stopRequested
            case "failed": self = .failed
            case "dismissed": self = .dismissed
            case "processEnded": self = .processEnded
            default: self = .unknown(rawValue)
            }
        }

        init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        var label: String {
            switch self {
            case .logged: "Logged"
            case .stopped: "Stopped"
            case .stopRequested: "Stop requested"
            case .failed: "Failed"
            case .dismissed: "Dismissed"
            case .processEnded: "Ended"
            case .unknown(let raw): "Unknown (\(raw))"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, processName, pid, ruleID, outcome, detail, conditions
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        processName: String,
        pid: Int32,
        ruleID: UUID,
        outcome: Outcome,
        detail: String,
        conditions: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.processName = processName
        self.pid = pid
        self.ruleID = ruleID
        self.outcome = outcome
        self.detail = detail
        self.conditions = conditions
    }

    /// Hand-written so a payload written by another build still decodes: the
    /// synthesized decoder ignores property defaults and hard-fails on any key it
    /// does not find, which would make one added field destroy the whole log.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(timeIntervalSince1970: 0)
        processName = try container.decodeIfPresent(String.self, forKey: .processName) ?? ""
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        outcome = ((try? container.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? nil)
            ?? .unknown("missing")
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        conditions = try? container.decodeIfPresent(String.self, forKey: .conditions)
    }
}

private struct AnyRuleCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
