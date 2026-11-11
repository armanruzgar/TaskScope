import Foundation
import SwiftUI

struct ProcessDetailSheet: View {
    var process: AppProcess
    var detail: ProcessDetail?
    var failed: Bool
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
                LabeledContent("Arguments") {
                    Text(detail.arguments ?? "Unavailable")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("CPU %", value: String(format: "%.1f", process.cpu))
                LabeledContent("Memory (MB)", value: String(format: "%.1f", process.memoryMB))
            } else if failed {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: "\(process.pid)")
                Text("Process no longer exists or detail could not be loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Name", value: process.name)
                LabeledContent("PID", value: "\(process.pid)")
                ProgressView()
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
