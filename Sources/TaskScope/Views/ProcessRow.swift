import SwiftUI

struct ProcessRow: View {
    var process: AppProcess
    var isCurrentProcess: Bool
    var isSelected: Bool
    var isKeyboardSelected: Bool
    var isHighlightedCPU: Bool
    var isHighlightedMEM: Bool
    var showsExpandedMetrics: Bool = false
    var leadingInset: CGFloat = 0
    /// One-based depth in tree view; nil in the flat list.
    var treeLevel: Int? = nil
    /// A tree ancestor shown only for hierarchy context: it does not match the
    /// search or filter.
    var isContextOnly: Bool = false
    var stopAction: () -> Void
    var toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentProcess)
            .help(isCurrentProcess ? "TaskScope cannot select its own process" : "Toggle Selection")
            // Same-named helpers are common, so every control names its PID.
            .accessibilityLabel(
                isCurrentProcess
                    ? "TaskScope cannot be selected"
                    : (isSelected ? "Remove \(processDescription) from selection" : "Add \(processDescription) to selection")
            )
            .accessibilityHint(
                isCurrentProcess
                    ? "TaskScope protects its own process"
                    : "Changes the batch action selection"
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    // Identifiers are printed as ps prints them, never with
                    // locale digit grouping.
                    Text(verbatim: String(process.pid))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(process.displayCommand)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(processDescription)
            .accessibilityValue(accessibilitySummary)
            .accessibilityHint("Command: \(process.displayCommand)")
            .accessibilityAddTraits(isKeyboardSelected ? .isSelected : [])

            Spacer(minLength: 8)

            if showsExpandedMetrics {
                Text(verbatim: String(process.pid))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(verbatim: String(process.parentPID))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)

                // A busy process's pair can be wider than the column; shrink it
                // rather than wrap it onto a second line.
                Text(metricPair(process.netInKB, process.netOutKB, decimals: 1))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 96, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(metricPair(process.diskReadBytes.map { $0 / 1_048_576 }, process.diskWriteBytes.map { $0 / 1_048_576 }, decimals: 1))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 96, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            metricValue(
                Text(process.cpu, format: .number.precision(.fractionLength(1))),
                isHighlighted: isHighlightedCPU
            )
            .frame(width: 54, alignment: .trailing)
            .accessibilityHidden(true)

            metricValue(
                Text(process.memoryMB, format: .number.precision(.fractionLength(0))),
                isHighlighted: isHighlightedMEM
            )
            .frame(width: 64, alignment: .trailing)
            .accessibilityHidden(true)

            Button(role: .destructive) {
                stopAction()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isCurrentProcess)
            .help(isCurrentProcess ? "Use Quit TaskScope" : "Stop Process")
            .accessibilityLabel(isCurrentProcess ? "TaskScope cannot be stopped here" : "Stop \(processDescription)")
            .frame(width: 28)
        }
        .padding(.leading, 16 + leadingInset)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
        .opacity(isContextOnly ? 0.55 : 1)
        .background {
            if isKeyboardSelected {
                Color.accentColor.opacity(0.12)
            } else if isHighlightedCPU || isHighlightedMEM {
                Color.orange.opacity(0.08)
            }
        }
    }

    /// A value over its threshold is marked by weight and a glyph, not by colour
    /// alone, and keeps the primary text colour for contrast. The cue stays when
    /// the row's keyboard-focus tint replaces the highlight tint.
    @ViewBuilder
    private func metricValue(_ text: Text, isHighlighted: Bool) -> some View {
        HStack(spacing: 2) {
            if isHighlighted {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
            }
            text
                .monospacedDigit()
                .font(.caption)
                .fontWeight(isHighlighted ? .bold : .regular)
                .foregroundStyle(.primary)
        }
    }

    private var processDescription: String {
        "\(process.name), PID \(String(process.pid))"
    }

    private func metricPair(_ first: Double?, _ second: Double?, decimals: Int) -> String {
        guard let first, let second else { return "—" }
        return String(format: "%.*f / %.*f", decimals, first, decimals, second)
    }

    private var accessibilitySummary: String {
        var values = ["CPU \(process.cpu.formatted(.number.precision(.fractionLength(1)))) percent"]
        values.append("memory \(process.memoryMB.formatted(.number.precision(.fractionLength(0)))) megabytes")
        if isHighlightedCPU { values.append("high CPU") }
        if isHighlightedMEM { values.append("high memory") }
        if let treeLevel { values.append("level \(treeLevel)") }
        if isContextOnly { values.append("shown for hierarchy, does not match the search or filter") }
        return values.joined(separator: ", ")
    }
}
