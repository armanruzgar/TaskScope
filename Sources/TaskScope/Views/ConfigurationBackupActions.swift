import AppKit
import UniformTypeIdentifiers

/// The configuration backup's export, import preview and import, kept out of
/// the views so they can be tested. File access is injectable: tests never
/// present a panel or touch the user's files.
@MainActor
final class ConfigurationBackupActions: ObservableObject {
    /// The stores a backup reads and an import writes.
    struct Stores {
        var watchedApps: WatchedAppsStore
        var autoStopRules: AutoStopRulesStore
        var savedSelections: SavedSelectionsStore?
        var settings: SettingsStore
        var hotkey: HotkeyManager
    }

    /// What an import would do, section by section, until it is committed or
    /// cancelled. Each section was checked by its store's own validation.
    struct Preview {
        var archive: ConfigurationArchive
        var presets: WatchedAppsStore.ImportPreview?
        var rules: [AutoStopRulesStore.ImportItem]?
        var selections: [SavedSelectionsStore.ImportItem]?
        var selectionsProblem: String?
        var settingsChanges: [SettingsStore.BackupChange]?
        var settingsProblem: String?
        var hotkey: HotkeyManager.Backup?
        var hotkeyProblem: String?
        /// The sections the user keeps in the import; all of them at first.
        var included: Set<ConfigurationArchive.Section>

        var sections: [ConfigurationArchive.Section] { archive.sections }

        /// How many entries of a section an import would add or apply.
        func importableCount(_ section: ConfigurationArchive.Section) -> Int {
            switch section {
            case .presets: presets?.importableCount ?? 0
            case .autoStopRules: rules?.filter(\.isAccepted).count ?? 0
            case .savedSelections: selectionsProblem == nil ? selections?.filter(\.isAccepted).count ?? 0 : 0
            case .settings: settingsProblem == nil && settingsChanges?.isEmpty == false ? 1 : 0
            case .hotkey: hotkey != nil && hotkeyProblem == nil ? 1 : 0
            }
        }

        var hasImportableContent: Bool {
            included.contains { importableCount($0) > 0 }
        }
    }

    @Published var exportNote: String?
    @Published var exportError: String?
    @Published var importSummary: String?
    @Published var importError: String?
    @Published var preview: Preview?

    var fileSize: (URL) throws -> Int = { url in
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    var readFile: (URL) throws -> Data = { url in
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }
    var saveArchive: @MainActor (Data) throws -> Void = { data in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "TaskScope-configuration.json"
        if panel.runModal() == .OK, let url = panel.url {
            try data.write(to: url, options: .atomic)
        }
    }

    /// Writes every section that can be read. A section whose stored data is
    /// in recovery is left out and named, rather than exported as the
    /// fallback in memory.
    func export(from stores: Stores) {
        exportNote = nil
        do {
            var missing: [String] = []
            let presets = try stores.watchedApps.exportedPresetsJSON()
            if presets == nil { missing.append(ConfigurationArchive.Section.presets.phrase) }
            let rules = try stores.autoStopRules.exportedRulesJSON()
            if rules == nil { missing.append(ConfigurationArchive.Section.autoStopRules.phrase) }
            let selections = try stores.savedSelections?.exportedSelectionsJSON()
            if stores.savedSelections != nil, selections == nil {
                missing.append(ConfigurationArchive.Section.savedSelections.phrase)
            }
            let settings = stores.settings.isReadOnlyAfterCorruption ? nil : stores.settings.backup
            if settings == nil { missing.append("settings") }
            let hotkey = stores.hotkey.backup
            if hotkey == nil { missing.append("the hotkey") }
            let data = try ConfigurationArchive.encode(
                presets: presets, autoStopRules: rules, savedSelections: selections,
                settings: settings, hotkey: hotkey
            )
            try saveArchive(data)
            exportError = nil
            if !missing.isEmpty {
                exportNote = "The backup leaves out \(Self.list(missing)): their stored data is in recovery. Recover it first to include it."
            }
        } catch {
            exportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Forgets the previous import's outcome when a new one starts.
    func beginImport() {
        importError = nil
        importSummary = nil
        preview = nil
    }

    func loadImport(from url: URL, into stores: Stores) {
        beginImport()
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        do {
            // Checked before reading so an oversized file is never loaded.
            guard try fileSize(url) <= ConfigurationArchive.maximumBytes else {
                throw ConfigurationArchive.ArchiveError.exceedsMaximumSize
            }
            preview = Self.preview(of: try ConfigurationArchive.decode(readFile(url)), against: stores)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription
                ?? "Could not read the configuration from the file."
        }
    }

    static func preview(of archive: ConfigurationArchive, against stores: Stores) -> Preview {
        let selectionsProblem = archive.savedSelections != nil && stores.savedSelections == nil
            ? "Saved selections cannot be imported here." : nil
        return Preview(
            archive: archive,
            presets: archive.presets.map { stores.watchedApps.previewImport($0) },
            rules: archive.autoStopRules.map { stores.autoStopRules.previewImport($0) },
            selections: archive.savedSelections.flatMap { selections in
                stores.savedSelections.map { $0.previewImport(selections) }
            },
            selectionsProblem: selectionsProblem,
            settingsChanges: archive.settings.map { stores.settings.backupChanges($0) },
            settingsProblem: archive.settings != nil && stores.settings.isReadOnlyAfterCorruption
                ? "Settings are in recovery mode; reset them first." : nil,
            hotkey: archive.hotkey,
            hotkeyProblem: archive.hotkey.flatMap { stores.hotkey.backupProblem($0) },
            included: Set(archive.sections)
        )
    }

    func setIncluded(_ section: ConfigurationArchive.Section, _ isIncluded: Bool) {
        if isIncluded {
            preview?.included.insert(section)
        } else {
            preview?.included.remove(section)
        }
    }

    /// Applies the included sections through each store, which validates them
    /// again against the current data. Rules arrive turned off, and nothing
    /// here turns Keep Off or any other background enforcement on.
    func commitImport(into stores: Stores) {
        guard let preview else { return }
        self.preview = nil
        let archive = preview.archive
        var imported: [String] = []
        var refused: [String] = []
        var rulesImported = 0
        func count(_ number: Int, _ singular: String, _ plural: String) -> String {
            "\(number) \(number == 1 ? singular : plural)"
        }
        if preview.included.contains(.presets), let presets = archive.presets {
            let result = stores.watchedApps.importPresets(presets)
            if result.importedCount > 0 { imported.append(count(result.importedCount, "preset", "presets")) }
            if result.rejectedCount > 0 { refused.append(count(result.rejectedCount, "preset", "presets")) }
        }
        if preview.included.contains(.autoStopRules), let rules = archive.autoStopRules {
            let result = stores.autoStopRules.importRules(rules)
            rulesImported = result.imported
            if result.imported > 0 { imported.append(count(result.imported, "Auto-Stop rule", "Auto-Stop rules")) }
            if result.rejected > 0 { refused.append(count(result.rejected, "Auto-Stop rule", "Auto-Stop rules")) }
        }
        if preview.included.contains(.savedSelections), let selections = archive.savedSelections,
           let store = stores.savedSelections {
            let result = store.importSelections(selections)
            if result.imported > 0 { imported.append(count(result.imported, "saved selection", "saved selections")) }
            if result.rejected > 0 { refused.append(count(result.rejected, "saved selection", "saved selections")) }
        }
        // Settings that already match change nothing and are not reported.
        if preview.included.contains(.settings), let settings = archive.settings,
           !stores.settings.backupChanges(settings).isEmpty {
            if stores.settings.applyBackup(settings) {
                imported.append("settings")
            } else {
                refused.append("settings")
            }
        }
        if preview.included.contains(.hotkey), let hotkey = archive.hotkey {
            if stores.hotkey.applyBackup(hotkey) {
                imported.append("the hotkey")
            } else {
                refused.append("the hotkey")
            }
        }
        var summary = imported.isEmpty ? "Nothing was imported." : "Imported \(Self.list(imported))."
        if !refused.isEmpty {
            summary += " Not imported: \(Self.list(refused))."
        }
        if rulesImported > 0 {
            summary += " Imported Auto-Stop rules are turned off: review each one in Settings > Auto-Stop and turn on the ones you want."
        }
        if imported.isEmpty {
            importSummary = nil
            importError = summary
        } else {
            importError = nil
            importSummary = summary
        }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
