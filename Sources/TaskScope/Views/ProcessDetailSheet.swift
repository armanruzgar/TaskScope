import Foundation
import SwiftUI

struct ProcessDetailSheet: View {
    var process: AppProcess
    var detail: ProcessDetail?
    var failed: Bool
    var failure: ProcessDetailResult? = nil
    var onRetry: () -> Void = {}
    var metricsAreLive = false
    /// The moment Elapsed is measured to; the sheet redraws with the list.
    var now: Date = Date()
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
                VStack(alignment: .leading, spacing: 8) {
                    row("Name", process.name)
                    row("PID", String(detail.pid))
                    row("Parent", detail.parentDescription)
                    row("User", detail.user)
                    row("Started", detail.displayStartTime())
                    row("Elapsed", detail.elapsedDescription(now: now))
                    row("Executable", detail.executablePath)
                    row("Command", detail.command)
                    LabeledContent("Command Line") {
                        commandLineValue(detail.commandLine)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    row("Code Signature", detail.codeSignature.description)
                    row("Threads", detail.threadCount.map { String($0) })
                    row("Open Files", detail.openFiles.map { String($0.descriptorCount) })
                    row("Listening Ports", detail.openFiles.map { ProcessDetail.portsDescription($0.listeningPorts) })
                    row("CPU %", String(format: "%.1f", process.cpu))
                    row("Memory (MB)", String(format: "%.1f", process.memoryMB))
                }
                Text(metricsAreLive
                     ? "CPU and memory follow the process list."
                     : "CPU and memory as of the request; the process is no longer in the list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if failed {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: String(process.pid))
                Text(failure?.message ?? "Process no longer exists or detail could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .readFailed = failure {
                    Button("Retry", action: onRetry)
                }
            } else {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: String(process.pid))
                ProgressView()
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A value, or "Unavailable" with the reason under it.
    @ViewBuilder
    private func row(_ label: String, _ value: ProcessDetailValue<String>) -> some View {
        switch value {
        case .available(let text):
            row(label, text)
        case .unavailable(let reason):
            LabeledContent(label) {
                unavailable(reason)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func unavailable(_ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Unavailable")
            if let reason {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The command line, or why it is missing. It is shown only here.
    @ViewBuilder
    private func commandLineValue(_ result: CommandLineReadResult) -> some View {
        if let commandLine = result.commandLine {
            Text(verbatim: commandLine)
                .textSelection(.enabled)
        } else {
            unavailable(result.message)
        }
    }
}
