import SwiftUI

struct TaskScopeFooterView: View {
    var isWorking: Bool
    var message: String
    var workingMessage: String? = nil
    var expandsMessage: Bool = false
    var summary: String?
    var quitDisabled = false
    var quitAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // `isWorking` is true for actions and explicit refreshes, not for
            // the silent reads polling makes, and the last result stays
            // visible beside the spinner instead of a generic placeholder.
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            // Results and recovery instructions can be several sentences; wrap
            // them rather than cut them to one line behind a hover tooltip.
            Text(isWorking ? (workingMessage ?? message) : message)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)

            Spacer()

            if let summary {
                Text(summary)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("CPU and resident memory summed over the displayed matching rows (up to the display limit), not the whole inventory. In tree view, ancestors shown only for context are not counted and collapsed matches are.")
                    .accessibilityLabel(summary.replacingOccurrences(of: "Σ shown", with: "Total for shown processes:"))
            }

            Button {
                quitAction()
            } label: {
                Image(systemName: "power.circle")
            }
            .buttonStyle(.borderless)
            .disabled(quitDisabled)
            .help(quitDisabled ? "Wait for the current action before quitting" : "Quit TaskScope")
            .accessibilityLabel("Quit TaskScope")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
