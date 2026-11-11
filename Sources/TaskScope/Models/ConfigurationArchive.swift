import Foundation

/// A TaskScope configuration backup: watched-app presets, Auto-Stop rules,
/// saved selections, settings and the hotkey, each an optional section, behind
/// the preset archive's schema version scheme and 1 MB limit. It never holds
/// Keep Off state, recovery backups or event history. An imported archive is
/// untrusted configuration: every section goes through its store's validation.
struct ConfigurationArchive: Equatable, Sendable {
    /// Version 1 is the preset-only archive, which still imports, as does the
    /// bare preset array that came before it.
    nonisolated static let currentSchemaVersion = 2
    nonisolated static let maximumBytes = WatchedAppsStore.maximumPresetArchiveBytes
    /// Import validation runs on the main actor; these bound the work a 1 MB
    /// file can ask for, as the preset limit does for presets.
    nonisolated static let maximumRuleCount = 500
    nonisolated static let maximumSelectionCount = 500

    enum Section: String, CaseIterable, Identifiable, Sendable {
        case presets
        case autoStopRules
        case savedSelections
        case settings
        case hotkey

        var id: String { rawValue }

        var title: String {
            switch self {
            case .presets: "Watched-app presets"
            case .autoStopRules: "Auto-Stop rules"
            case .savedSelections: "Saved selections"
            case .settings: "Settings"
            case .hotkey: "Hotkey"
            }
        }

        /// The section's name inside a sentence.
        var phrase: String {
            switch self {
            case .presets: "watched-app presets"
            case .autoStopRules: "Auto-Stop rules"
            case .savedSelections: "saved selections"
            case .settings: "settings"
            case .hotkey: "hotkey"
            }
        }
    }

    enum ArchiveError: LocalizedError, Equatable {
        case exceedsMaximumSize
        case exceedsMaximumCount(Section, Int)
        case unsupportedSchemaVersion(Int)
        case unreadable
        case invalidSection(Section, String)
        case empty
        /// The Watched Apps import of a backup without presets.
        case noPresets

        var errorDescription: String? {
            switch self {
            case .exceedsMaximumSize:
                "Configuration backups must be 1 MB or smaller."
            case .exceedsMaximumCount(let section, let limit):
                "A configuration backup may contain at most \(limit) \(section.phrase)."
            case .unsupportedSchemaVersion(let version):
                "Configuration schema version \(version) is not supported by this TaskScope build."
            case .unreadable:
                "The file is not a recognized TaskScope configuration or preset archive."
            case .invalidSection(let section, let detail):
                "The \(section.phrase) in this backup could not be decoded: \(detail)"
            case .empty:
                "This configuration backup contains nothing this TaskScope build can import."
            case .noPresets:
                "This configuration backup holds no watched-app presets. Import it with Import Configuration… in Settings > General."
            }
        }
    }

    var presets: [WatchedAppPreset]?
    var autoStopRules: [AutoStopRule]?
    var savedSelections: [SavedSelectionsStore.SavedSelection]?
    var settings: SettingsStore.Backup?
    var hotkey: HotkeyManager.Backup?
    /// Top-level keys a newer build wrote, which this build leaves out.
    var unknownSections: [String] = []

    var sections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .presets: presets != nil
            case .autoStopRules: autoStopRules != nil
            case .savedSelections: savedSelections != nil
            case .settings: settings != nil
            case .hotkey: hotkey != nil
            }
        }
    }

    /// Whether `data` is a configuration backup (schema version 2) rather
    /// than a preset archive. Anything unreadable is left to the preset decoder.
    nonisolated static func isConfigurationBackup(_ data: Data) -> Bool {
        guard data.count <= maximumBytes,
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return envelope["schemaVersion"] as? Int == currentSchemaVersion
    }

    /// Decodes a configuration backup, a version 1 preset archive, or a bare
    /// preset array. The size limit applies before anything is parsed.
    nonisolated static func decode(_ data: Data) throws -> ConfigurationArchive {
        guard data.count <= maximumBytes else { throw ArchiveError.exceedsMaximumSize }
        guard let topLevel = try? JSONSerialization.jsonObject(with: data) else {
            throw ArchiveError.unreadable
        }
        if topLevel is [Any] {
            return ConfigurationArchive(presets: try presetArchive(data))
        }
        guard let envelope = topLevel as? [String: Any],
              let schemaVersion = envelope["schemaVersion"] as? Int else {
            throw ArchiveError.unreadable
        }
        switch schemaVersion {
        case WatchedAppsStore.PresetArchive.currentSchemaVersion:
            return ConfigurationArchive(presets: try presetArchive(data))
        case currentSchemaVersion:
            break
        default:
            throw ArchiveError.unsupportedSchemaVersion(schemaVersion)
        }
        let known = Set(Section.allCases.map(\.rawValue)).union(["schemaVersion"])
        var archive = ConfigurationArchive(
            unknownSections: envelope.keys.filter { !known.contains($0) }.sorted()
        )
        archive.presets = try section(.presets, in: envelope, limit: WatchedAppsStore.maximumPresetCount)
        archive.autoStopRules = try section(.autoStopRules, in: envelope, limit: maximumRuleCount)
        archive.savedSelections = try section(.savedSelections, in: envelope, limit: maximumSelectionCount)
        archive.settings = try section(.settings, in: envelope)
        archive.hotkey = try section(.hotkey, in: envelope)
        guard !archive.sections.isEmpty else { throw ArchiveError.empty }
        return archive
    }

    /// Encodes the sections given, each as the JSON its store would save, so
    /// fields a newer build wrote are kept in the backup.
    nonisolated static func encode(
        presets: Any? = nil,
        autoStopRules: Any? = nil,
        savedSelections: Any? = nil,
        settings: SettingsStore.Backup? = nil,
        hotkey: HotkeyManager.Backup? = nil
    ) throws -> Data {
        var archive: [String: Any] = ["schemaVersion": currentSchemaVersion]
        archive[Section.presets.rawValue] = presets
        archive[Section.autoStopRules.rawValue] = autoStopRules
        archive[Section.savedSelections.rawValue] = savedSelections
        if let settings {
            archive[Section.settings.rawValue] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        }
        if let hotkey {
            archive[Section.hotkey.rawValue] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(hotkey))
        }
        let data = try JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys])
        // A backup this build could not import again is refused here.
        guard data.count <= maximumBytes else { throw ArchiveError.exceedsMaximumSize }
        return data
    }

    nonisolated private static func presetArchive(_ data: Data) throws -> [WatchedAppPreset] {
        do {
            return try WatchedAppsStore.decodePresetArchive(data)
        } catch let error as WatchedAppsStore.PresetArchiveError {
            switch error {
            case .exceedsMaximumSize: throw ArchiveError.exceedsMaximumSize
            case .exceedsMaximumCount: throw ArchiveError.exceedsMaximumCount(.presets, WatchedAppsStore.maximumPresetCount)
            case .unsupportedSchemaVersion(let version): throw ArchiveError.unsupportedSchemaVersion(version)
            case .unreadable: throw ArchiveError.unreadable
            case .invalidContents(let detail): throw ArchiveError.invalidSection(.presets, detail)
            }
        }
    }

    nonisolated private static func section<Value: Decodable>(
        _ section: Section, in envelope: [String: Any], limit: Int? = nil
    ) throws -> Value? {
        guard let value = envelope[section.rawValue] else { return nil }
        if let limit, let entries = value as? [Any], entries.count > limit {
            throw ArchiveError.exceedsMaximumCount(section, limit)
        }
        guard JSONSerialization.isValidJSONObject(value) else {
            throw ArchiveError.invalidSection(section, "expected a list or a dictionary.")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ArchiveError.invalidSection(section, WatchedAppsStore.describeDecodingError(error))
        }
    }
}
