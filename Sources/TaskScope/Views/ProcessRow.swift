import SwiftUI

/// Column widths shared by the list's header and its rows, so every title
/// sits over its values.
enum ProcessListColumns {
    static let pid: CGFloat = 60
    static let parentPID: CGFloat = 60
    static let user: CGFloat = 76
    static let network: CGFloat = 96
    static let disk: CGFloat = 96
    static let cpu: CGFloat = 54
    static let memory: CGFloat = 64
    static let stopButton: CGFloat = 28
}

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
    /// The search matched only the process's command line, which the row
    /// does not show.
    var matchedByCommandLine: Bool = false
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

                    if process.isStopped == true {
                        Text("Paused")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .help("Stopped by a signal (state T). Choose Resume to let it run again.")
                    }
                }

                HStack(spacing: 3) {
                    if matchedByCommandLine {
                        Image(systemName: "text.magnifyingglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("The search matches this process's command line")
                    }
                    Text(process.displayCommand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    .frame(width: ProcessListColumns.pid, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(verbatim: String(process.parentPID))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: ProcessListColumns.parentPID, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(verbatim: process.ownerName ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: ProcessListColumns.user, alignment: .leading)
                    .help(process.ownerName ?? "Owner unknown")
                    .accessibilityHidden(true)

                // A busy process's pair can be wider than the column; shrink it
                // rather than wrap it onto a second line.
                Text(metricPair(process.netInRateKBps, process.netOutRateKBps, decimals: 1))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: ProcessListColumns.network, alignment: .trailing)
                    .accessibilityHidden(true)

                Text(metricPair(
                    process.diskReadRateBytesPerSecond.map { $0 / 1_048_576 },
                    process.diskWriteRateBytesPerSecond.map { $0 / 1_048_576 },
                    decimals: 1
                ))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: ProcessListColumns.disk, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            metricValue(
                Text(process.cpu, format: .number.precision(.fractionLength(1))),
                isHighlighted: isHighlightedCPU
            )
            .frame(width: ProcessListColumns.cpu, alignment: .trailing)
            .accessibilityHidden(true)

            metricValue(
                Text(process.memoryMB, format: .number.precision(.fractionLength(0))),
                isHighlighted: isHighlightedMEM
            )
            .frame(width: ProcessListColumns.memory, alignment: .trailing)
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
            .frame(width: ProcessListColumns.stopButton)
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

    /// A rate pair for VoiceOver. Without a rate, it says whether one is
    /// coming (the counters were read once) or the counters are unavailable.
    private func accessibilityRates(
        _ name: String, _ firstValue: Double?, _ secondValue: Double?, hasCounters: Bool,
        unit: String, first: String, second: String
    ) -> String {
        guard let firstValue, let secondValue else {
            return hasCounters ? "\(name) rate shown after the next refresh" : "\(name) unavailable"
        }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        return "\(name) \(first) \(firstValue.formatted(format)), \(second) \(secondValue.formatted(format)) \(unit)"
    }

    private func metricPair(_ first: Double?, _ second: Double?, decimals: Int) -> String {
        guard let first, let second else { return "—" }
        return String(format: "%.*f / %.*f", decimals, first, decimals, second)
    }

    private var accessibilitySummary: String {
        var values = ["CPU \(process.cpu.formatted(.number.precision(.fractionLength(1)))) percent"]
        values.append("memory \(process.memoryMB.formatted(.number.precision(.fractionLength(0)))) megabytes")
        if showsExpandedMetrics {
            // The window's PPID, USER, NET and DISK cells are hidden from
            // VoiceOver as separate elements, so the row's summary reads them.
            values.append("parent PID \(String(process.parentPID))")
            values.append("user \(process.ownerName ?? "unknown")")
            values.append(accessibilityRates(
                "network", process.netInRateKBps, process.netOutRateKBps,
                hasCounters: process.netInKB != nil && process.netOutKB != nil,
                unit: "kilobytes per second", first: "received", second: "sent"
            ))
            values.append(accessibilityRates(
                "disk",
                process.diskReadRateBytesPerSecond.map { $0 / 1_048_576 },
                process.diskWriteRateBytesPerSecond.map { $0 / 1_048_576 },
                hasCounters: process.diskReadBytes != nil && process.diskWriteBytes != nil,
                unit: "megabytes per second", first: "read", second: "written"
            ))
        }
        if process.isStopped == true { values.append("paused") }
        if isHighlightedCPU { values.append("high CPU") }
        if isHighlightedMEM { values.append("high memory") }
        if matchedByCommandLine { values.append("matches the search in its command line") }
        if let treeLevel { values.append("level \(treeLevel)") }
        if isContextOnly { values.append("shown for hierarchy, does not match the search or filter") }
        return values.joined(separator: ", ")
    }
}
