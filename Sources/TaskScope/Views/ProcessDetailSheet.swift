import Foundation
import SwiftUI

struct ProcessDetailSheet: View {
    var process: AppProcess
    var detail: ProcessDetail?
    var failed: Bool
    var failure: ProcessDetailResult? = nil
    var onRetry: () -> Void = {}
    var metricsAreLive = false
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Process Detail")
                    .font(.headline)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            if let detail {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: "\(detail.pid)")
                LabeledContent("Parent PID", value: "\(detail.parentPID)")
                LabeledContent("User", value: detail.user)
                LabeledContent("Started", value: detail.displayStartTime())
                LabeledContent("Command", value: detail.command)
                LabeledContent("Command Line") {
                    commandLineValue(detail.commandLine)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("CPU %", value: String(format: "%.1f", process.cpu))
                LabeledContent("Memory (MB)", value: String(format: "%.1f", process.memoryMB))
                Text(metricsAreLive
                     ? "CPU and memory follow the process list."
                     : "CPU and memory as of the request; the process is no longer in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if failed {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: "\(process.pid)")
                Text(failure?.message ?? "Process no longer exists or detail could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .readFailed = failure {
                    Button("Retry", action: onRetry)
                }
            } else {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: "\(process.pid)")
                ProgressView()
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(width: 420)
    }

    /// The command line, or why it is missing. It is shown only here.
    @ViewBuilder
    private func commandLineValue(_ result: CommandLineReadResult) -> some View {
        if let commandLine = result.commandLine {
            Text(verbatim: commandLine)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unavailable")
                if let reason = result.message {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
