import SwiftUI

/// One history series: its latest value and its peak over the time window
/// beside a line drawn on a time axis that ends at the latest sample. The line
/// is scaled to that peak, which the label below it states. The caller shows
/// the window's span, which charts side by side share.
struct SparklineView: View {
    var samples: [ProcessHistory.Sample]
    var keyPath: KeyPath<ProcessHistory.Sample, Double>
    var color: Color
    var label: String
    /// The unit VoiceOver reads, for example "percent".
    var unit: String
    var samplingState: ProcessHistory.SamplingState = .sampling
    /// The time the axis covers, ending at the latest sample. Nil spaces the
    /// samples evenly instead.
    var window: TimeInterval? = nil
    /// How a value reads on screen, for example "883%".
    var format: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(1))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(latest.map(format) ?? "–")
                    .font(.caption2.monospacedDigit())
                    .fontWeight(.medium)
            }
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .frame(height: 20)
            Text(peak.map { "peak \(format($0))" } ?? "peak –")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilitySummary)
    }

    /// The samples the axis shows: the whole buffer, or with a window those
    /// within it of the latest sample.
    var visibleSamples: [ProcessHistory.Sample] {
        guard let window, let end = samples.last?.timestamp else { return samples }
        let start = end.addingTimeInterval(-window)
        return samples.filter { $0.timestamp >= start }
    }

    var latest: Double? { samples.last?[keyPath: keyPath] }

    var peak: Double? { visibleSamples.map { $0[keyPath: keyPath] }.max() }

    static func spanText(_ window: TimeInterval) -> String {
        let seconds = Int(window.rounded())
        if seconds < 120 { return "\(seconds) s" }
        let minutes = Int((window / 60).rounded())
        return "\(minutes) min"
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let shown = visibleSamples
        guard let peak, peak > 0, let end = shown.last?.timestamp else { return }
        func y(_ value: Double) -> CGFloat {
            size.height - CGFloat(value / peak) * size.height
        }
        if shown.count == 1 {
            let point = CGPoint(x: size.width - 2, y: y(shown[0][keyPath: keyPath]))
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                with: .color(color)
            )
            return
        }
        let start = window.map { end.addingTimeInterval(-$0) } ?? shown[0].timestamp
        let span = max(end.timeIntervalSince(start), 0.001)
        var path = Path()
        for (index, sample) in shown.enumerated() {
            let x = window == nil
                ? CGFloat(index) * size.width / CGFloat(shown.count - 1)
                : CGFloat(sample.timestamp.timeIntervalSince(start) / span) * size.width
            let point = CGPoint(x: x, y: y(sample[keyPath: keyPath]))
            if index == 0 || sample.startsNewSegment {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private var accessibilitySummary: String {
        guard let latest, let peak else {
            return samplingState == .sampling ? "No samples" : "No samples, \(samplingState.label)"
        }
        let number = { (value: Double) in value.formatted(.number.precision(.fractionLength(1))) }
        var parts = ["Latest \(number(latest)) \(unit)"]
        let scope = window.map { " in the last \(Self.spanText($0))" } ?? ""
        parts.append("peak \(number(peak)) \(unit)\(scope)")
        let count = visibleSamples.count
        parts.append("\(count) \(count == 1 ? "sample" : "samples")")
        // A paused or failed history otherwise reads exactly like a live one.
        if samplingState != .sampling { parts.append(samplingState.label) }
        return parts.joined(separator: ", ")
    }
}
