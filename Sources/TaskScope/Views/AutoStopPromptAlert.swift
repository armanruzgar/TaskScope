import SwiftUI

struct AutoStopPromptAlert: View {
    let prompt: AutoStopPrompt?
    let rules: AutoStopRulesStore

    /// Says which of the rule's conditions the process met, with the values
    /// it has now.
    static func message(for prompt: AutoStopPrompt) -> String {
        let rule = prompt.rule
        let process = prompt.process
        var clauses: [String] = []
        if rule.checksRuntime {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day, .hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            let runtime = process.runtimeSeconds.flatMap { formatter.string(from: $0) } ?? "an unknown duration"
            clauses.append("has run for \(runtime), beyond the \(rule.runtimeMinutes)-minute rule")
        }
        if rule.hasSampledConditions {
            let thresholds = [
                rule.cpuPercentAtLeast.map { "\($0)% CPU" },
                rule.memoryMBAtLeast.map { "\(AutoStopRule.megabytes($0)) of memory" },
            ].compactMap { $0 }
            let current = [
                rule.cpuPercentAtLeast.map { _ in "\(Int(process.cpu.rounded()))% CPU" },
                rule.memoryMBAtLeast.map { _ in AutoStopRule.megabytes(Int(process.memoryMB.rounded())) },
            ].compactMap { $0 }
            let span = rule.sustainedChecks == 1 ? "" : " for \(rule.sustainedChecks) checks in a row"
            clauses.append(
                "has used at least \(thresholds.joined(separator: " and "))\(span) (now \(current.joined(separator: " and ")))"
            )
        }
        if rule.commandLineContains != nil {
            clauses.append("its command line contains the rule's text")
        }
        let condition = clauses.count > 1
            ? clauses.dropLast().joined(separator: ", ") + ", and " + (clauses.last ?? "")
            : clauses.first ?? "matched this rule"
        return "\(process.name) (PID \(process.pid)) \(condition). Stop it now? Dismiss stops reminders for this process until it restarts."
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(
                prompt.map { "Auto-Stop: \($0.process.name)" } ?? "Auto-Stop",
                isPresented: Binding(
                    get: { prompt != nil },
                    set: { isPresented in
                        // A button may already have consumed this prompt. Never
                        // dismiss the next queue entry during alert write-back.
                        if !isPresented, let prompt { rules.dismissPrompt(prompt) }
                    }
                ),
                presenting: prompt
            ) { prompt in
                Button("Stop Now", role: .destructive) {
                    rules.stopPrompt(prompt)
                }
                Button("Dismiss", role: .cancel) {
                    rules.dismissPrompt(prompt)
                }
            } message: { prompt in
                Text(Self.message(for: prompt))
            }
    }
}
