import AppKit
import UniformTypeIdentifiers

/// The Watched Apps tab's import, export and preset-editor handlers, kept out of
/// the view so they can be tested. File access is injectable: tests never
/// present a panel or touch the user's files.
@MainActor
final class PresetSettingsActions: ObservableObject {
    @Published var editorError: String?
    @Published var exportError: String?
    @Published var importError: String?
    /// The outcome of the last committed import, shown as neutral text.
    @Published var importSummary: String?
    @Published var preview: WatchedAppsStore.ImportPreview?
    /// Set when the loaded file is a configuration backup with more than
    /// presets, which this import leaves out.
    private(set) var otherSectionsNote: String?

    var fileSize: (URL) throws -> Int = { url in
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    var readFile: (URL) throws -> Data = { url in
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }
    var saveArchive: @MainActor (Data) throws -> Void = { data in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TaskScope-presets.json"
        if panel.runModal() == .OK, let url = panel.url {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Forgets the previous import's outcome when a new one starts.
    func beginImport() {
        clearImportFeedback()
        preview = nil
        otherSectionsNote = nil
    }

    /// A later change to the preset list makes the last import's outcome stale.
    func clearImportFeedback() {
        importError = nil
        importSummary = nil
    }

    func loadImport(from url: URL, into store: WatchedAppsStore) {
        beginImport()
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            // Checked before reading so an oversized file is never loaded.
            guard try fileSize(url) <= WatchedAppsStore.maximumPresetArchiveBytes else {
                throw WatchedAppsStore.PresetArchiveError.exceedsMaximumSize
            }
            let data = try readFile(url)
            let decoded: [WatchedAppPreset]
            if ConfigurationArchive.isConfigurationBackup(data) {
                // A configuration backup: this import takes its presets only.
                let archive = try ConfigurationArchive.decode(data)
                guard let presets = archive.presets else {
                    throw ConfigurationArchive.ArchiveError.noPresets
                }
                decoded = presets
                if archive.sections != [.presets] || !archive.unknownSections.isEmpty {
                    otherSectionsNote = "The rest of the configuration backup was not imported; use Import Configuration… in Settings > General."
                }
            } else {
                decoded = try WatchedAppsStore.decodePresetArchive(data)
            }
            preview = store.previewImport(decoded)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? "Could not read presets from file."
        }
    }

    func commitImport(into store: WatchedAppsStore) {
        guard let preview else { return }
        let result = store.importPresets(preview.items.map(\.preset))
        self.preview = nil
        let rejected = result.rejectedCount == 0
            ? ""
            : " \(result.rejectedCount) \(result.rejectedCount == 1 ? "was" : "were") rejected by validation."
        if result.importedCount == 0 {
            importSummary = nil
            importError = "No presets were imported." + rejected
        } else {
            importError = nil
            importSummary = "Imported \(result.importedCount) preset\(result.importedCount == 1 ? "" : "s")." + rejected
                + (otherSectionsNote.map { " " + $0 } ?? "")
        }
        otherSectionsNote = nil
    }

    func export(from store: WatchedAppsStore) {
        // In corrupt mode the in-memory list is the empty array the store fell
        // back to, not the user's presets: exporting it would write a valid-looking
        // but empty backup precisely when the banner asks for one.
        guard store.canExportPresets else {
            exportError = "Preset data is unreadable, so there is nothing to export. "
                + "Recover the backup noted above before resetting."
            return
        }
        do {
            try saveArchive(store.encodedPresetArchive())
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Adds a new preset or updates the one being edited. Returns true when the
    /// editor may close.
    @discardableResult
    func saveEditor(_ form: WatchedPresetFormState, into store: WatchedAppsStore) -> Bool {
        let existing = form.editingPresetID.flatMap { id in
            store.presets.first { $0.id == id }
        }
        let preset: WatchedAppPreset
        switch form.makePreset(existing: existing) {
        case .success(let value):
            preset = value
        case .failure(let error):
            editorError = error.message
            return false
        }
        let saved = existing == nil ? store.add(preset) : store.update(preset)
        guard saved else {
            editorError = store.validationError ?? "The preset could not be saved."
            return false
        }
        editorError = nil
        clearImportFeedback()
        return true
    }
}
