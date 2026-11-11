import SwiftUI

struct SavedSelectionRecallSheet: View {
    let selection: SavedSelectionsStore.SavedSelection
    let result: SavedSelectionsStore.RecallResult
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recall “\(selection.name)”")
                .lineLimit(2)
                .truncationMode(.tail)
                .font(.title2)
                .fontWeight(.semibold)
            Text(result.summary)
                .foregroundStyle(result.matched.isEmpty ? .orange : .secondary)

            if !result.matched.isEmpty {
                GroupBox("Will select") {
                    itemList(result.matched.map {
                        "\($0.name) — PID \($0.pid)"
                            + (result.legacyNameMatches.contains($0.identity) ? Self.legacyMarker : "")
                    })
                }
            }
            if !result.unmatched.isEmpty {
                GroupBox("Not running") {
                    itemList(result.unmatched.map { Self.savedEntryLabel($0) })
                }
            }
            if !result.ambiguous.isEmpty {
                GroupBox("Ambiguous — not selected") {
                    itemList(result.ambiguous.map { Self.savedEntryLabel($0) })
                }
            }

            if hasLegacyEntries {
                Text("Entries marked “legacy name match” were saved without a kernel executable path and match by command or name only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if result.legacyUnsupported {
                Text("Legacy PID-only records are preserved for review but are not used because PIDs can be recycled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Selection", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(result.matched.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    static let legacyMarker = " · legacy name match"

    private static func savedEntryLabel(_ saved: SavedSelectionsStore.SavedProcess) -> String {
        saved.executableName + (saved.executablePath == nil ? legacyMarker : "")
    }

    private var hasLegacyEntries: Bool {
        !result.legacyNameMatches.isEmpty
            || (result.unmatched + result.ambiguous).contains { $0.executablePath == nil }
    }

    private func itemList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Labels repeat (several unmatched helpers share one name), so
            // identify rows by position rather than by text.
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RenameSavedSelectionSheet: View {
    let originalName: String
    @Binding var name: String
    let validationError: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Saved Selection")
                .font(.headline)
            TextField("Selection name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || name == originalName
                    )
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
