import SwiftUI

/// Reviews every captured target of a batch Stop or Force Stop before anything
/// is signalled, including selected rows that are not on screen. A sheet with a
/// scrolling list rather than a confirmation dialog: a dialog's message grows
/// with the list, and a large selection would push its buttons off screen.
struct BatchStopReviewSheet: View {
    let pending: ProcessConfirmationState.PendingBatchTermination
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.title)
                .font(.title3.weight(.semibold))

            Text(pending.summary)

            List(pending.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: "PID \(String(row.pid))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(row.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.path)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(minHeight: 140, idealHeight: 220)

            Text(pending.signalNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Deliberately no Return shortcut: a destructive batch action
                // must be chosen with a click.
                Button(pending.confirmTitle, role: .destructive, action: onConfirm)
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 480, minHeight: 340)
    }
}
