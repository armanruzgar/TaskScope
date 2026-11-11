import SwiftUI

struct ProcessBatchActionReportSheet: View {
    let report: ProcessBatchActionReport
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(report.title)
                .font(.title2.weight(.semibold))

            List(report.targets) { target in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.name)
                            .lineLimit(1)
                        Text("PID \(target.identity.pid)")
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

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }
}
