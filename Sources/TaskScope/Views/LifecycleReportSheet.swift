import AppKit
import SwiftUI

struct LifecycleReportSheet: View {
    let report: LifecycleReport
    var copyReport: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    let onClose: () -> Void

    var summary: String { "\(report.jobs.filter(\.succeeded).count) succeeded, \(report.jobs.filter { !$0.succeeded }.count) failed" }
    var reportText: String {
        ([report.title, summary] + report.jobs.map { "\($0.label): \($0.state.displayName) — \($0.detail)" }).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(summary).font(.caption)

            List(Array(report.jobs.enumerated()), id: \.offset) { _, job in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.label)
                            .fontWeight(.medium)
                        Spacer()
                        Text(job.state.displayName)
                            .foregroundStyle(job.succeeded ? Color.secondary : Color.red)
                    }
                    Text(job.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }

            HStack {
                Button("Copy Report") { copyReport(reportText) }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 480, minHeight: 320, idealHeight: 360)
    }
}
