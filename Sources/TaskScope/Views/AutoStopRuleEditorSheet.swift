import SwiftUI

struct AutoStopRuleEditorSheet: View {
    @State private var draft: AutoStopRule
    @State private var conditions: AutoStopConditionsDraft
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
        _conditions = State(initialValue: AutoStopConditionsDraft(rule: rule))
        self.validationError = validationError
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Auto-Stop Rule")
                .font(.title2)
                .fontWeight(.semibold)

            // A Form gives each field a visible label; a bare TextField only
            // shows its title as a placeholder, which an edit never sees.
            Form {
                TextField("Process name", text: $draft.processName)

                TextField(
                    "Executable path",
                    text: Binding(
                        get: { draft.executablePath ?? "" },
                        set: { draft.executablePath = $0 }
                    ),
                    prompt: Text("Required for Auto Stop")
                )

                Section("Conditions (all must hold)") {
                    RuntimeMinutesControl(minutes: $conditions.runtimeMinutes, isChecked: $conditions.checksRuntime)
                    AutoStopSampledConditionFields(conditions: $conditions)
                    AutoStopCommandLineField(conditions: $conditions)
                }

                Picker("Action", selection: $draft.action) {
                    ForEach(AutoStopRule.Action.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }

                Toggle("Enabled", isOn: $draft.isEnabled)
            }
            .formStyle(.grouped)

            if let warning = AutoStopRuleValidation.pathWarning(draft.executablePath) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }

            if !conditions.hasCondition {
                Text(AutoStopConditionsDraft.missingConditionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = conditions.commandLineProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button("Save") { onSave(conditions.applied(to: draft)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draft.processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !conditions.canSave
                    )
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
    }
}
