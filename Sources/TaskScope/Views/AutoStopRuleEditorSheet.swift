import SwiftUI

struct AutoStopRuleEditorSheet: View {
    @State private var draft: AutoStopRule
    /// The store's rejection for the last save attempt, rendered inside the
    /// sheet where the user can see it.
    let validationError: String?
    let onSave: (AutoStopRule) -> Void
    let onCancel: () -> Void

    init(
        rule: AutoStopRule,
        validationError: String? = nil,
        onSave: @escaping (AutoStopRule) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: rule)
        self.validationError = validationError
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Auto-Stop Rule")
                .font(.title2)
                .fontWeight(.semibold)

            TextField("Process name", text: $draft.processName)
                .textFieldStyle(.roundedBorder)

            TextField(
                "Executable path (required for Auto Stop)",
                text: Binding(
                    get: { draft.executablePath ?? "" },
                    set: { draft.executablePath = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            Stepper(
                value: $draft.runtimeMinutes,
                in: 1...AutoStopRulesStore.maximumRuntimeMinutes
            ) {
                Text("Runtime: \(draft.runtimeMinutes) minute\(draft.runtimeMinutes == 1 ? "" : "s")")
            }

            Picker("Action", selection: $draft.action) {
                ForEach(AutoStopRule.Action.allCases) { action in
                    Text(action.label).tag(action)
                }
            }

            Toggle("Enabled", isOn: $draft.isEnabled)

            if let warning = AutoStopRuleValidation.pathWarning(draft.executablePath) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Could not save rule: \(validationError)")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
