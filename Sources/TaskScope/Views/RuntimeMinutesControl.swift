import SwiftUI

/// The runtime threshold of an auto-stop rule: a typed number of minutes plus
/// stepper arrows for small adjustments. A typed value outside the allowed
/// range is clamped to it when it is committed (Return or leaving the field).
/// With `isChecked`, a checkbox switches the run-time condition on and off; the
/// minutes are kept while it is off.
struct RuntimeMinutesControl: View {
    static let range = 1...AutoStopRulesStore.maximumRuntimeMinutes

    @Binding var minutes: Int
    var isChecked: Binding<Bool>?

    init(minutes: Binding<Int>, isChecked: Binding<Bool>? = nil) {
        _minutes = minutes
        self.isChecked = isChecked
    }

    var body: some View {
        LabeledContent("Runtime minutes") {
            HStack(spacing: 6) {
                if let isChecked {
                    Toggle("Check run time", isOn: isChecked)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                TextField("Runtime minutes", value: clampedMinutes, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .disabled(!isOn)
                Stepper("Adjust runtime minutes", value: $minutes, in: Self.range)
                    .labelsHidden()
                    .disabled(!isOn)
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

    private var isOn: Bool {
        isChecked?.wrappedValue ?? true
    }

    private var clampedMinutes: Binding<Int> {
        Binding(get: { minutes }, set: { minutes = Self.clamped($0) })
    }
}
