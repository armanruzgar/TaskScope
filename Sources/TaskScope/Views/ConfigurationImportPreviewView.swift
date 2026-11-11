import SwiftUI

/// The configuration import preview: every section the backup holds, what
/// each store's validation made of it, and a switch per section. Nothing runs
/// until Import, and the rules it adds are turned off.
struct ConfigurationImportPreviewView: View {
    @ObservedObject var actions: ConfigurationBackupActions
    var onCancel: () -> Void
    var onImport: () -> Void

    var body: some View {
        if let preview = actions.preview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configuration Import Preview")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Preview only: no app, process, launch agent or privileged operation runs during import. Imported Auto-Stop rules are turned off until you review them, and Keep Off is never imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(preview.sections) { section in
                        Section {
                            if preview.included.contains(section) {
                                rows(for: section, in: preview)
                            }
                        } header: {
                            Toggle(isOn: Binding(
                                get: { actions.preview?.included.contains(section) ?? false },
                                set: { actions.setIncluded(section, $0) }
                            )) {
                                Text("\(section.title): \(Self.summary(of: section, in: preview))")
                            }
                            .accessibilityLabel("Import \(section.phrase)")
                        }
                    }
                    if !preview.archive.unknownSections.isEmpty {
                        Text("Not understood by this build and left out: \(preview.archive.unknownSections.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Import", action: onImport)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!preview.hasImportableContent)
                }
            }
            .padding(20)
            .frame(width: SettingsView.importPreviewSheetSize.width, height: SettingsView.importPreviewSheetSize.height)
        } else {
            Text("No import preview is available.")
                .padding()
        }
    }

    static func summary(of section: ConfigurationArchive.Section, in preview: ConfigurationBackupActions.Preview) -> String {
        switch section {
        case .presets:
            let items = preview.presets?.items.count ?? 0
            return "\(preview.importableCount(section)) of \(items) ready"
        case .autoStopRules:
            let items = preview.rules?.count ?? 0
            return "\(preview.importableCount(section)) of \(items) ready, imported turned off"
        case .savedSelections:
            if preview.selectionsProblem != nil { return "unavailable" }
            let items = preview.selections?.count ?? 0
            return "\(preview.importableCount(section)) of \(items) ready"
        case .settings:
            if preview.settingsProblem != nil { return "unavailable" }
            let changes = preview.settingsChanges?.count ?? 0
            return changes == 0 ? "no changes" : (changes == 1 ? "1 change" : "\(changes) changes")
        case .hotkey:
            return preview.hotkeyProblem == nil ? "ready" : "refused"
        }
    }

    @ViewBuilder
    private func rows(for section: ConfigurationArchive.Section, in preview: ConfigurationBackupActions.Preview) -> some View {
        switch section {
        case .presets:
            ForEach(preview.presets?.items ?? []) { item in
                PresetImportPreviewRow(item: item)
            }
        case .autoStopRules:
            ForEach(preview.rules ?? []) { item in
                RuleImportPreviewRow(item: item)
            }
        case .savedSelections:
            if let problem = preview.selectionsProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            ForEach(preview.selections ?? []) { item in
                SelectionImportPreviewRow(item: item)
            }
        case .settings:
            if let problem = preview.settingsProblem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if preview.settingsChanges?.isEmpty != false {
                Text("Every setting in the backup already matches.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(preview.settingsChanges ?? []) { change in
                Text("\(change.name): \(change.current) → \(change.imported)")
                    .font(.caption)
            }
            Text("Keep Off is not part of a backup and stays as it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .hotkey:
            if let hotkey = preview.hotkey {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcut: \(hotkey.displayString), \(hotkey.isEnabled ? "on" : "off")")
                    if let problem = preview.hotkeyProblem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
        }
    }
}

/// One Auto-Stop rule of an import preview, with what it would match and do.
struct RuleImportPreviewRow: View {
    var item: AutoStopRulesStore.ImportItem

    var body: some View {
        let rule = item.importedRule ?? item.rule
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.processName)
                    .fontWeight(.semibold)
                Spacer()
                Text(item.isAccepted ? "Ready, turned off" : "Rejected")
                    .font(.caption)
                    .foregroundStyle(item.isAccepted ? Color.green : Color.red)
            }
            if let path = rule.executablePath {
                Text("Executable path: \(path)")
            } else {
                Text("Name only: matches any process named \(rule.processName)")
            }
            Text("Action: \(rule.action.label)")
            Text("Conditions: \(rule.conditionSummary(showingCommandLineText: true))")
            if let reason = item.rejectionReason {
                Text(reason).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}

/// One saved selection of an import preview.
struct SelectionImportPreviewRow: View {
    var item: SavedSelectionsStore.ImportItem

    var body: some View {
        let selection = item.importedSelection ?? item.selection
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(selection.name)
                    .fontWeight(.semibold)
                Spacer()
                Text(item.isAccepted ? "Ready" : "Rejected")
                    .font(.caption)
                    .foregroundStyle(item.isAccepted ? Color.green : Color.red)
            }
            ForEach(Array(selection.processes.enumerated()), id: \.offset) { _, process in
                Text(process.executablePath ?? process.command)
            }
            if let reason = item.rejectionReason {
                Text(reason).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}
