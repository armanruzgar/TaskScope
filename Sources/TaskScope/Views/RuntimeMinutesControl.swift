import SwiftUI

/// The runtime threshold of an auto-stop rule: a typed number of minutes plus
/// stepper arrows for small adjustments. A typed value outside the allowed
/// range is clamped to it when it is committed (Return or leaving the field).
struct RuntimeMinutesControl: View {
    static let range = 1...AutoStopRulesStore.maximumRuntimeMinutes

    @Binding var minutes: Int

    var body: some View {
        LabeledContent("Runtime minutes") {
            HStack(spacing: 6) {
                TextField("Runtime minutes", value: clampedMinutes, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                Stepper("Adjust runtime minutes", value: $minutes, in: Self.range)
                    .labelsHidden()
                Text(Self.rangeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Type \(Self.range.lowerBound) to \(Self.range.upperBound) minutes (\(Self.range.upperBound / 60) hours), or use the arrows.")
    }

    static let rangeDescription = "\(range.lowerBound)–\(range.upperBound)"

    static func clamped(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private var clampedMinutes: Binding<Int> {
        Binding(get: { minutes }, set: { minutes = Self.clamped($0) })
    }
}
