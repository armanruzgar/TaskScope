import SwiftUI

/// The conditions a rule editor shows. A condition that is switched off keeps
/// its value here, so switching it back on restores what was typed.
struct AutoStopConditionsDraft: Equatable {
    static let defaultCPUPercent = 100
    static let defaultMemoryMB = 1_024

    var checksRuntime = true
    var runtimeMinutes = 5
    var checksCPU = false
    var cpuPercent = AutoStopConditionsDraft.defaultCPUPercent
    var checksMemory = false
    var memoryMB = AutoStopConditionsDraft.defaultMemoryMB
    var sustainedChecks = AutoStopRule.defaultSustainedChecks
    var checksCommandLine = false
    var commandLineText = ""

    init() {}

    init(rule: AutoStopRule) {
        checksRuntime = rule.checksRuntime
        runtimeMinutes = rule.runtimeMinutes
        checksCPU = rule.cpuPercentAtLeast != nil
        cpuPercent = rule.cpuPercentAtLeast ?? Self.defaultCPUPercent
        checksMemory = rule.memoryMBAtLeast != nil
        memoryMB = rule.memoryMBAtLeast ?? Self.defaultMemoryMB
        sustainedChecks = rule.sustainedChecks
        checksCommandLine = rule.commandLineContains != nil
        commandLineText = rule.commandLineContains ?? ""
    }

    /// A rule needs at least one of run time, CPU and memory.
    var hasCondition: Bool {
        checksRuntime || hasSampledConditions
    }

    var hasSampledConditions: Bool {
        checksCPU || checksMemory
    }

    /// Why the command-line condition cannot be saved as it is, or nil.
    var commandLineProblem: String? {
        guard checksCommandLine,
              commandLineText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "Enter the text the command line must contain."
    }

    /// Whether a rule with these conditions can be saved.
    var canSave: Bool {
        hasCondition && commandLineProblem == nil
    }

    func applied(to rule: AutoStopRule) -> AutoStopRule {
        var rule = rule
        rule.checksRuntime = checksRuntime
        rule.runtimeMinutes = runtimeMinutes
        rule.cpuPercentAtLeast = checksCPU ? cpuPercent : nil
        rule.memoryMBAtLeast = checksMemory ? memoryMB : nil
        rule.sustainedChecks = sustainedChecks
        rule.commandLineContains = checksCommandLine ? commandLineText : nil
        return rule
    }

    static let missingConditionMessage = "Choose at least one condition: run time, CPU, or memory."
}

/// The rule editors' "Command line contains" row: plain text, compared
/// case-sensitively, kept exactly as typed.
struct AutoStopCommandLineField: View {
    @Binding var conditions: AutoStopConditionsDraft

    var body: some View {
        LabeledContent("Command line contains") {
            HStack(spacing: 6) {
                Toggle("Check command line", isOn: $conditions.checksCommandLine)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                TextField("Command line text", text: $conditions.commandLineText, prompt: Text("for example server.js"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .disabled(!conditions.checksCommandLine)
            }
        }
        .help("Plain text, case-sensitive. Checked only for processes that match the name, path and owner; TaskScope keeps only whether it matched, never the command line.")
    }
}

/// The CPU, memory and checks-in-a-row rows of the rule editors. Typed values
/// outside the allowed range are clamped when committed, as for run time.
struct AutoStopSampledConditionFields: View {
    @Binding var conditions: AutoStopConditionsDraft

    var body: some View {
        LabeledContent("CPU at least") {
            HStack(spacing: 6) {
                Toggle("Check CPU", isOn: $conditions.checksCPU)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                number("CPU percent", \.cpuPercent, in: AutoStopRuleValidation.cpuPercentRange)
                    .disabled(!conditions.checksCPU)
                Text("% (100% is one full core)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabeledContent("Memory at least") {
            HStack(spacing: 6) {
                Toggle("Check memory", isOn: $conditions.checksMemory)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                number("Memory in megabytes", \.memoryMB, in: AutoStopRuleValidation.memoryMBRange)
                    .disabled(!conditions.checksMemory)
                Text("MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        LabeledContent("Checks in a row") {
            HStack(spacing: 6) {
                number("Checks in a row", \.sustainedChecks, in: AutoStopRuleValidation.sustainedChecksRange)
                Stepper(
                    "Adjust checks in a row",
                    value: $conditions.sustainedChecks,
                    in: AutoStopRuleValidation.sustainedChecksRange
                )
                .labelsHidden()
                Text(Self.spanDescription(checks: conditions.sustainedChecks))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!conditions.hasSampledConditions)
        .help("CPU and memory must stay at or above their values on this many checks in a row. TaskScope checks every 10 seconds.")
    }

    /// The time the checks span at the engine's 10-second cadence.
    static func spanDescription(checks: Int) -> String {
        let seconds = checks * 10
        guard seconds >= 60 else { return "about \(seconds) s" }
        let minutes = Double(seconds) / 60
        return minutes == minutes.rounded()
            ? "about \(Int(minutes)) min"
            : "about \(minutes.formatted(.number.precision(.fractionLength(1)))) min"
    }

    private func number(
        _ label: String,
        _ keyPath: WritableKeyPath<AutoStopConditionsDraft, Int>,
        in range: ClosedRange<Int>
    ) -> some View {
        TextField(
            label,
            value: Binding(
                get: { conditions[keyPath: keyPath] },
                set: { conditions[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, $0)) }
            ),
            format: .number.grouping(.never)
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 72)
    }
}
