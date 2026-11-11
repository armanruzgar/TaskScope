import SwiftUI

struct SparklineView: View {
    var samples: [ProcessHistory.Sample]
    var keyPath: KeyPath<ProcessHistory.Sample, Double>
    var color: Color
    var label: String
    var unit: String

    var samplingState: ProcessHistory.SamplingState = .sampling

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Canvas { context, size in
                guard !samples.isEmpty else { return }
                let values = samples.map { $0[keyPath: keyPath] }
                guard let max = values.max(), max > 0 else { return }
                let stepX = values.count == 1 ? 0 : size.width / CGFloat(values.count - 1)
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = size.height - (CGFloat(value) / CGFloat(max)) * size.height
                    if index == 0 || samples[index].startsNewSegment {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                if values.count == 1 {
                    let point = CGPoint(x: size.width / 2, y: size.height / 2)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                        with: .color(color)
                    )
                } else {
                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                }
            }
            .frame(height: 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let latest = samples.last?[keyPath: keyPath] else {
            return "No samples"
        }
        let summary = "Latest \(latest.formatted(.number.precision(.fractionLength(1)))) \(unit), \(samples.count) \(samples.count == 1 ? "sample" : "samples")"
        // A paused or failed history otherwise reads exactly like a live one.
        return samplingState == .sampling ? summary : "\(summary), \(samplingState.label)"
    }
}
