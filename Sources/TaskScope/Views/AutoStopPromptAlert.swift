import SwiftUI

struct AutoStopPromptAlert: View {
    let prompt: AutoStopPrompt?
    let rules: AutoStopRulesStore

    static func message(for prompt: AutoStopPrompt) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        let runtime = prompt.process.runtimeSeconds.flatMap { formatter.string(from: $0) } ?? "an unknown duration"
        return "\(prompt.process.name) (PID \(prompt.process.pid)) has run for \(runtime), beyond the \(prompt.rule.runtimeMinutes)-minute rule. Stop it now? Dismiss stops reminders for this process until it restarts."
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
