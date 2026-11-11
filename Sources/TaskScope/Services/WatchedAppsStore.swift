import Darwin
import Foundation

@MainActor
final class WatchedAppsStore: ObservableObject {
    nonisolated static let maximumPresetArchiveBytes = 1_000_000

    struct PresetArchive: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var presets: [WatchedAppPreset]

        init(
            schemaVersion: Int = PresetArchive.currentSchemaVersion,
            presets: [WatchedAppPreset]
        ) {
            self.schemaVersion = schemaVersion
            self.presets = presets
        }
    }

    enum PresetArchiveError: LocalizedError, Equatable {
        case exceedsMaximumSize
        case unsupportedSchemaVersion(Int)
        case unreadable
        /// The archive shape was recognized but its presets did not decode. The
        /// detail names the failing field so the user can repair the file.
        case invalidContents(String)

        var errorDescription: String? {
            switch self {
            case .exceedsMaximumSize:
                "Preset archives must be 1 MB or smaller."
            case .unsupportedSchemaVersion(let version):
                "Preset schema version \(version) is not supported by this TaskScope build."
            case .unreadable:
                "The file is not a recognized TaskScope preset archive."
            case .invalidContents(let detail):
                "The preset archive could not be decoded: \(detail)"
            }
        }
    }

    struct ImportResult: Equatable {
        var importedCount: Int
        var rejectedCount: Int
    }

    struct ImportPreviewItem: Identifiable, Equatable {
        var id: Int
        var preset: WatchedAppPreset
        var normalizedPreset: WatchedAppPreset?
        var rejectionReason: String?

        var isAccepted: Bool { normalizedPreset != nil }
    }

    struct ImportPreview: Equatable {
        var items: [ImportPreviewItem]

        var importableCount: Int { items.filter(\.isAccepted).count }
        var rejectedCount: Int { items.count - importableCount }
    }

    nonisolated static let defaultPersistenceKey = "TaskScope.watchedPresets.v1"

    @Published private(set) var presets: [WatchedAppPreset] {
        didSet { persistIfAllowed() }
    }
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var validationError: String?

    private let persistence: RecoveringCodableStorage<[WatchedAppPreset]>
    private var allowsPersistence: Bool
    private var recoveredDecodedPayload: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = WatchedAppsStore.defaultPersistenceKey
    ) {
        let persistence = RecoveringCodableStorage<[WatchedAppPreset]>(
            userDefaults: userDefaults,
            key: key
        )
        self.persistence = persistence
        guard persistence.hasStoredValue else {
            presets = [.globalProtect]
            allowsPersistence = true
            recoveredDecodedPayload = false
            // Assigning in `init` does not fire `didSet`, so the seeded default was
            // never written. Persist it now so the preset the App Intents catalog
            // publishes is backed by stored bytes and keeps one identity.
            persistIfAllowed()
            return
        }

        let loaded = persistence.loadRecoveringElements()
        if let decoded = loaded.value {
            let validated = Self.validatedPresets(decoded)
            let rejectedCount = loaded.rejectedCount + validated.rejectedCount
            presets = validated.presets
            if rejectedCount > 0 {
                let backup = persistence.preserveCurrentPayload(
                    suffix: "rejectedMigrationBackup"
                ) ?? (key: "\(key).rejectedMigrationBackup", isPreserved: false)
                allowsPersistence = false
                recoveredDecodedPayload = true
                let guidance = presets.isEmpty
                    ? "No presets could be recovered for export; preserve the named backup before resetting to the built-in default."
                    : "Review or export the recovered presets, then reset to commit them. Rejected presets are excluded from export."
                persistenceIssue = "Rejected \(rejectedCount) unsafe or invalid stored preset\(rejectedCount == 1 ? "" : "s"). \(PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)). \(guidance)"
            } else {
                allowsPersistence = true
                recoveredDecodedPayload = false
                if validated.presets != decoded {
                    persistence.savePreservingUnknownFields(validated.presets)
                }
            }
        } else {
            let backupKey = loaded.backupKey ?? "\(key).corruptBackup"
            presets = []
            allowsPersistence = false
            recoveredDecodedPayload = false
            persistenceIssue = "Preset data was unreadable. \(PersistenceRecovery.preservedPayloadDescription(backupKey: backupKey, isPreserved: loaded.isBackupPreserved)), and the current primary remains untouched until reset."
        }
    }

    /// True once a decode failure has disabled writing. Callers must treat a
    /// mutation as unsuccessful in this state rather than reporting a save that
    /// cannot reach disk.
    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// Safe recovered presets from a decoded payload may be exported for review even
    /// though persistence stays locked. A payload that could not be decoded has no
    /// trustworthy in-memory representation to export.
    var canExportPresets: Bool {
        allowsPersistence || (recoveredDecodedPayload && !presets.isEmpty)
    }

    private func rejectIfReadOnly() -> Bool {
        guard !allowsPersistence else { return false }
        validationError = "Preset data is in recovery mode; reset presets before making changes."
        return true
    }

    @discardableResult
    func add(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized) else {
            return false
        }
        validationError = nil
        presets.append(normalized)
        return true
    }

    @discardableResult
    func remove(at offsets: IndexSet) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.remove(atOffsets: offsets)
        return true
    }

    @discardableResult
    func remove(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.removeAll { $0.id == preset.id }
        return true
    }

    @discardableResult
    func move(from source: IndexSet, to destination: Int) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        presets.move(fromOffsets: source, toOffset: destination)
        return true
    }

    @discardableResult
    func update(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard let index = presets.firstIndex(where: { $0.id == preset.id }),
              let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized, excluding: preset.id) else {
            return false
        }
        validationError = nil
        presets[index] = normalized
        return true
    }

    /// Explicitly accepts the safe recovered presets and resumes writing. A payload
    /// that could not be decoded has no recoverable entries, so it resets to the
    /// built-in default; a decoded payload rejected by newer validation commits only
    /// the entries that passed current validation.
    func resetAfterCorruption() {
        guard !allowsPersistence else { return }
        allowsPersistence = true
        recoveredDecodedPayload = false
        if presets.isEmpty {
            presets = [.globalProtect]
        } else {
            persistIfAllowed()
        }
        persistenceIssue = nil
        validationError = nil
    }

    func importPresets(_ candidates: [WatchedAppPreset]) -> ImportResult {
        guard !rejectIfReadOnly() else {
            return ImportResult(importedCount: 0, rejectedCount: candidates.count)
        }
        let preview = previewImport(candidates)
        let accepted = preview.items.compactMap(\.normalizedPreset)
        presets.append(contentsOf: accepted)
        validationError = preview.rejectedCount == 0
            ? nil
            : "\(preview.rejectedCount) preset\(preview.rejectedCount == 1 ? " was" : "s were") rejected by validation."

        return ImportResult(
            importedCount: accepted.count,
            rejectedCount: preview.rejectedCount
        )
    }

    func previewImport(_ candidates: [WatchedAppPreset]) -> ImportPreview {
        guard allowsPersistence else {
            return ImportPreview(items: candidates.enumerated().map { offset, preset in
                ImportPreviewItem(
                    id: offset,
                    preset: preset,
                    normalizedPreset: nil,
                    rejectionReason: "Preset storage is in recovery mode."
                )
            })
        }

        var workingPresets = presets
        var seenIDs = Set(presets.map(\.id))
        var items: [ImportPreviewItem] = []
        for (offset, candidate) in candidates.enumerated() {
            let validation = Self.validateAndNormalizePreset(candidate)
            guard let normalized = validation.preset else {
                items.append(ImportPreviewItem(
                    id: offset,
                    preset: candidate,
                    normalizedPreset: nil,
                    rejectionReason: validation.error ?? "Invalid preset."
                ))
                continue
            }
            guard !seenIDs.contains(normalized.id) else {
                items.append(ImportPreviewItem(
                    id: offset,
                    preset: candidate,
                    normalizedPreset: nil,
                    rejectionReason: "A preset with this identity already exists."
                ))
                continue
            }
            guard !Self.hasSemanticDuplicate(normalized, in: workingPresets) else {
                items.append(ImportPreviewItem(
                    id: offset,
                    preset: candidate,
                    normalizedPreset: nil,
                    rejectionReason: "A preset with the same name, process, or app path already exists."
                ))
                continue
            }
            // Record the ID only once the candidate is accepted, so a rejected
            // duplicate does not block a later valid candidate with the same ID.
            seenIDs.insert(normalized.id)
            workingPresets.append(normalized)
            items.append(ImportPreviewItem(
                id: offset,
                preset: candidate,
                normalizedPreset: normalized,
                rejectionReason: nil
            ))
        }
        return ImportPreview(items: items)
    }

    func encodedPresetArchive() throws -> Data {
        guard canExportPresets else { throw PresetArchiveError.unreadable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetArchive(presets: presets))
    }

    /// Decodes a versioned archive or a legacy preset array.
    ///
    /// The envelope shape decides the format first; a versioned archive whose
    /// presets fail to decode reports that decoding error and is never retried
    /// as a legacy array, which used to mask the real problem behind a generic
    /// "not a recognized archive" message.
    nonisolated static func decodePresetArchive(_ data: Data) throws -> [WatchedAppPreset] {
        guard data.count <= maximumPresetArchiveBytes else {
            throw PresetArchiveError.exceedsMaximumSize
        }
        let topLevel: Any
        do {
            topLevel = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PresetArchiveError.unreadable
        }

        let decoder = JSONDecoder()
        if let envelope = topLevel as? [String: Any] {
            guard let schemaVersion = envelope["schemaVersion"] as? Int else {
                throw PresetArchiveError.unreadable
            }
            guard schemaVersion == PresetArchive.currentSchemaVersion else {
                throw PresetArchiveError.unsupportedSchemaVersion(schemaVersion)
            }
            do {
                return try decoder.decode(PresetArchive.self, from: data).presets
            } catch {
                throw PresetArchiveError.invalidContents(describeDecodingError(error))
            }
        }
        if topLevel is [Any] {
            do {
                return try decoder.decode([WatchedAppPreset].self, from: data)
            } catch {
                throw PresetArchiveError.invalidContents(describeDecodingError(error))
            }
        }
        throw PresetArchiveError.unreadable
    }

    nonisolated private static func describeDecodingError(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            var joined = ""
            for key in codingPath {
                if let index = key.intValue {
                    joined += "[\(index)]"
                } else {
                    joined += joined.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return joined.isEmpty ? "the top level" : joined
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "missing \(key.stringValue) at \(path(context.codingPath))."
        case DecodingError.typeMismatch(_, let context):
            return "wrong value type at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "missing value at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "corrupted data at \(path(context.codingPath)): \(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private func validateAndNormalize(_ preset: WatchedAppPreset) -> WatchedAppPreset? {
        let result = Self.validateAndNormalizePreset(preset)
        validationError = result.error
        return result.preset
    }

    nonisolated static func validatedPresets(
        _ candidates: [WatchedAppPreset]
    ) -> (presets: [WatchedAppPreset], rejectedCount: Int) {
        var accepted: [WatchedAppPreset] = []
        var seenIDs: Set<UUID> = []
        var rejected = 0

        for candidate in candidates {
            guard let preset = validateAndNormalizePreset(candidate).preset else {
                rejected += 1
                continue
            }
            guard seenIDs.insert(preset.id).inserted,
                  !hasSemanticDuplicate(preset, in: accepted) else {
                rejected += 1
                continue
            }
            accepted.append(preset)
        }
        return (accepted, rejected)
    }

    nonisolated private static func validateAndNormalizePreset(
        _ preset: WatchedAppPreset
    ) -> (preset: WatchedAppPreset?, error: String?) {
        var value = preset
        value.displayName = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.mainProcessName = value.mainProcessName.trimmingCharacters(in: .whitespacesAndNewlines)
        value.helperProcessNames = normalizedNames(value.helperProcessNames).filter {
            $0.caseInsensitiveCompare(value.mainProcessName) != .orderedSame
        }
        value.protectedProcessNames = normalizedNames(value.protectedProcessNames)
        value.appPath = value.appPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // The preset form edits these as comma-separated lists, so a comma
        // inside one item would split it into two on the next edit.
        let listItems = value.helperProcessNames + value.protectedProcessNames
            + value.userLaunchAgentJobs.flatMap { [$0.label, $0.plistPath] }
        guard !listItems.contains(where: { $0.contains(",") }) else {
            return (nil, "Helper and protected process names and launch agent labels and paths cannot contain commas.")
        }
        // Before path normalization: realpath reads a path only up to an
        // embedded NUL and could hide it.
        if let error = PresetFieldValidation.error(in: value) { return (nil, error) }
        guard !value.displayName.isEmpty, !value.mainProcessName.isEmpty else {
            return (nil, "Display name and main process name are required.")
        }
        guard value.appPath.hasPrefix("/"),
              URL(fileURLWithPath: value.appPath).pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return (nil, "App path must be an absolute .app bundle path.")
        }
        value.appPath = URL(fileURLWithPath: value.appPath).standardizedFileURL.path
        if value.id != WatchedAppPreset.globalProtectID {
            if let resolved = realpath(value.appPath, nil) {
                value.appPath = String(cString: resolved)
                free(resolved)
            }
            // Process names match case-sensitively, so a main name that differs
            // from the bundle executable only by case could never match. Adopt
            // the executable's spelling rather than rejecting a stored preset.
            if let executable = Bundle(path: value.appPath)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
               executable.caseInsensitiveCompare(value.mainProcessName) == .orderedSame {
                value.mainProcessName = executable
            }
        }
        value.userLaunchAgentJobs = value.userLaunchAgentJobs.map { original in
            var job = original
            job.label = job.label.trimmingCharacters(in: .whitespacesAndNewlines)
            job.plistPath = normalizedPlistPath(job.plistPath)
            return job
        }
        value.systemLaunchDaemonJobs = value.systemLaunchDaemonJobs.map { original in
            var job = original
            job.label = job.label.trimmingCharacters(in: .whitespacesAndNewlines)
            job.plistPath = normalizedPlistPath(job.plistPath)
            job.processName = job.processName.trimmingCharacters(in: .whitespacesAndNewlines)
            return job
        }
        // realpath can resolve the app path to a different spelling.
        if let error = PresetFieldValidation.error(in: value) { return (nil, error) }
        let killable = Set(([value.mainProcessName] + value.helperProcessNames).map { $0.lowercased() })
        let protected = Set(value.protectedProcessNames.map { $0.lowercased() })
        guard killable.isDisjoint(with: protected) else {
            return (nil, "Protected process names cannot also be main or helper process names.")
        }
        if value.id == WatchedAppPreset.globalProtectID {
            guard value.hasSupportedGlobalProtectIdentity else {
                return (nil, "The built-in GlobalProtect lifecycle identity cannot be modified.")
            }
            let notificationsEnabled = value.notificationsEnabled
            value = .globalProtect
            value.notificationsEnabled = notificationsEnabled
        } else if !value.systemLaunchDaemonJobs.isEmpty {
            return (nil, "Custom presets cannot configure privileged system launch daemons.")
        }
        guard let jobsError = jobsValidationError(value) else {
            return (value, nil)
        }
        return (nil, jobsError)
    }

    nonisolated private static func normalizedPlistPath(_ value: String) -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : path
    }

    nonisolated private static func jobsValidationError(_ preset: WatchedAppPreset) -> String? {
        var labels: Set<String> = []
        var paths: Set<String> = []
        for job in preset.userLaunchAgentJobs {
            guard !job.label.isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension.caseInsensitiveCompare("plist") == .orderedSame else {
                return "Every launch agent requires a label and absolute .plist path."
            }
            guard labels.insert(job.label.lowercased()).inserted,
                  paths.insert(job.plistPath.lowercased()).inserted else {
                return "Launch job labels and plist paths must be unique."
            }
        }
        for job in preset.systemLaunchDaemonJobs {
            guard !job.label.isEmpty,
                  !job.processName.isEmpty,
                  job.plistPath.hasPrefix("/"),
                  URL(fileURLWithPath: job.plistPath).pathExtension.caseInsensitiveCompare("plist") == .orderedSame,
                  job.servicePort.map({ (1...65_535).contains($0) }) ?? true else {
                return "Every daemon requires valid label, process, plist path, and optional port."
            }
            guard labels.insert(job.label.lowercased()).inserted,
                  paths.insert(job.plistPath.lowercased()).inserted else {
                return "Launch job labels and plist paths must be unique."
            }
        }
        return nil
    }

    nonisolated private static func normalizedNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    private func isSemanticDuplicate(
        _ preset: WatchedAppPreset,
        excluding id: UUID? = nil
    ) -> Bool {
        let duplicate = Self.hasSemanticDuplicate(preset, in: presets, excluding: id)
        if duplicate {
            validationError = "A preset with the same name, process, or app path already exists."
        }
        return duplicate
    }

    nonisolated private static func hasSemanticDuplicate(
        _ preset: WatchedAppPreset,
        in candidates: [WatchedAppPreset],
        excluding id: UUID? = nil
    ) -> Bool {
        candidates.contains {
            $0.id != id && (
                $0.displayName.caseInsensitiveCompare(preset.displayName) == .orderedSame
                || $0.mainProcessName.caseInsensitiveCompare(preset.mainProcessName) == .orderedSame
                || $0.appPath.caseInsensitiveCompare(preset.appPath) == .orderedSame
            )
        }
    }

    private func persistIfAllowed() {
        guard allowsPersistence else { return }
        persistence.savePreservingUnknownFields(presets)
    }

}
