import AppKit
import SwiftUI

struct ProcessBatchActionReportSheet: View {
    let report: ProcessBatchActionReport
    var copyReport: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    let onClose: () -> Void

    var summary: String {
        "\(report.targets.filter { $0.state == .stopped }.count) stopped, \(report.targets.filter { $0.state == .requestedStillRunning }.count) still running, \(report.targets.filter { $0.state != .stopped && $0.state != .requestedStillRunning }.count) not stopped"
    }
    var reportText: String {
        ([report.title, summary] + report.targets.map { "\($0.name) (PID \($0.identity.pid)): \($0.state.label)" + ($0.detail.map { " — \($0)" } ?? "") }).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(report.title)
                .font(.title2.weight(.semibold))

            Text(summary).font(.caption)

            List(report.targets) { target in
                ProcessBatchActionReportRow(target: target)
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
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// One target of a batch result: its name, its PID as ps prints it (never with
/// digit grouping), and what happened to it.
struct ProcessBatchActionReportRow: View {
    let target: ProcessTargetActionResult

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(target.name)
                    .lineLimit(1)
                Text(verbatim: "PID \(String(target.identity.pid))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(target.state.label)
                    .foregroundStyle(target.state == .stopped ? Color.green : Color.orange)
                if let detail = target.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
