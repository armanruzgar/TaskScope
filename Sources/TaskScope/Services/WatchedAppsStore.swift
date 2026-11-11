import Foundation

@MainActor
final class WatchedAppsStore: ObservableObject {
    /// Bounds the presets one archive may carry and the presets Add and Import
    /// may create. Import validation and duplicate checks run on the main actor,
    /// and a 1 MB archive could otherwise hold about 13,000 minimal presets.
    nonisolated static let maximumPresetCount = 200
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
        case exceedsMaximumCount
        case unsupportedSchemaVersion(Int)
        case unreadable
        /// The archive shape was recognized but its presets did not decode. The
        /// detail names the failing field so the user can repair the file.
        case invalidContents(String)

        var errorDescription: String? {
            switch self {
            case .exceedsMaximumSize:
                "Preset archives must be 1 MB or smaller."
            case .exceedsMaximumCount:
                "Preset archives may contain at most \(WatchedAppsStore.maximumPresetCount) presets."
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
    nonisolated static let presetLimitMessage = "At most \(maximumPresetCount) presets can be stored."
    nonisolated static let newerBuildMessage = "This preset contains fields from a newer build and is read-only. Use a build that understands it."

    @Published private(set) var presets: [WatchedAppPreset] {
        didSet { persistIfAllowed() }
    }
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var validationError: String?

    private let persistence: RecoveringCodableStorage<[WatchedAppPreset]>
    private var allowsPersistence: Bool
    private var recoveredDecodedPayload: Bool
    private let changePolicy: PresetChangePolicy

    /// `changePolicy` decides every deletion and edit; the app passes its Keep
    /// Off rule (`TaskScopeLaunchStores`).
    init(
        userDefaults: UserDefaults = .standard,
        key: String = WatchedAppsStore.defaultPersistenceKey,
        changePolicy: PresetChangePolicy = .unrestricted
    ) {
        let persistence = RecoveringCodableStorage<[WatchedAppPreset]>(
            userDefaults: userDefaults,
            key: key
        )
        self.persistence = persistence
        self.changePolicy = changePolicy
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
            if let unrewritable = loaded.unrewritableDataDescription {
                // The presets decoded, but the payload also holds a value this
                // build cannot write back. Use them, and keep the bytes as they are.
                allowsPersistence = false
                recoveredDecodedPayload = true
                persistenceIssue = "Preset data was read, but it \(unrewritable) Review or export the presets before resetting."
            } else if rejectedCount > 0 {
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

    /// False while the unreadable payload a reset would replace exists in no
    /// recovery slot, so the reset would destroy its only copy.
    var isRecoveryBackupPreserved: Bool {
        persistence.isCurrentPayloadPreserved
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

    /// A preset that carries a newer build's fields stays exactly as stored. A
    /// fabricated copy without those fields must not replace or remove it.
    private func rejectIfRequiresNewerBuild(_ preset: WatchedAppPreset) -> Bool {
        guard preset.hasUnknownFields
            || presets.contains(where: { $0.id == preset.id && $0.hasUnknownFields }) else {
            return false
        }
        validationError = Self.newerBuildMessage
        return true
    }

    /// Adds the built-in GlobalProtect preset back after it was deleted. A
    /// look-alike custom preset blocks it; the refusal names that preset and
    /// says how to proceed.
    @discardableResult
    func restoreBuiltInPreset() -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard !presets.contains(where: \.isBuiltInGlobalProtect) else {
            validationError = nil
            return true
        }
        if let collision = DuplicateIndex(presets, comparesResolvedPaths: true).collision(for: .globalProtect) {
            validationError = "The built-in GlobalProtect preset cannot be restored. \(collision) Delete or change that preset first."
            return false
        }
        return add(.globalProtect)
    }

    @discardableResult
    func add(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard presets.count < Self.maximumPresetCount else {
            validationError = Self.presetLimitMessage
            return false
        }
        guard let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized) else {
            return false
        }
        validationError = nil
        presets.append(normalized)
        return true
    }

    /// Why the deletion policy refuses to delete `preset` now, or nil. Asked
    /// before a deletion is offered for confirmation; `remove` asks again.
    func deletionRefusal(for preset: WatchedAppPreset) -> String? {
        changePolicy.deletionRefusal(presets.first { $0.id == preset.id } ?? preset)
    }

    /// Why the change policy refuses editing `preset` now, or nil. Asked to
    /// disable the editor; `update` asks again.
    func editRefusal(for preset: WatchedAppPreset) -> String? {
        changePolicy.editRefusal(presets.first { $0.id == preset.id } ?? preset)
    }

    @discardableResult
    func remove(_ preset: WatchedAppPreset) -> Bool {
        guard !rejectIfReadOnly(), !rejectIfRequiresNewerBuild(preset) else { return false }
        if let refusal = deletionRefusal(for: preset) {
            validationError = refusal
            return false
        }
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
        guard !rejectIfReadOnly(), !rejectIfRequiresNewerBuild(preset) else { return false }
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else {
            validationError = "This preset no longer exists."
            return false
        }
        guard let normalized = validateAndNormalize(preset),
              !isSemanticDuplicate(normalized, excluding: preset.id) else {
            return false
        }
        // Only a change to what Keep Off acts on is refused: the
        // notifications setting alone may change at any time.
        var sameNotifications = normalized
        sameNotifications.notificationsEnabled = presets[index].notificationsEnabled
        if sameNotifications != presets[index], let refusal = changePolicy.editRefusal(presets[index]) {
            validationError = refusal
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

        var acceptedCount = presets.count
        var duplicates = DuplicateIndex(presets, comparesResolvedPaths: true)
        var seenIDs = Set(presets.map(\.id))
        var items: [ImportPreviewItem] = []
        for (offset, candidate) in candidates.enumerated() {
            func reject(_ reason: String) {
                items.append(ImportPreviewItem(
                    id: offset,
                    preset: candidate,
                    normalizedPreset: nil,
                    rejectionReason: reason
                ))
            }
            guard acceptedCount < Self.maximumPresetCount else {
                reject(Self.presetLimitMessage)
                continue
            }
            let validation = Self.validateAndNormalizePreset(candidate)
            guard let normalized = validation.preset else {
                reject(validation.error ?? "Invalid preset.")
                continue
            }
            if let bundleError = Self.bundleTargetError(normalized) {
                reject(bundleError)
                continue
            }
            // Importing would drop the newer build's fields from the payload, and
            // with them any restriction they place on the preset.
            guard !normalized.hasUnknownFields else {
                reject("This preset contains fields from a newer TaskScope build and cannot be imported by this build.")
                continue
            }
            guard !seenIDs.contains(normalized.id) else {
                reject("A preset with this identity already exists.")
                continue
            }
            if let collision = duplicates.collision(for: normalized) {
                reject(collision)
                continue
            }
            // Record the ID only once the candidate is accepted, so a rejected
            // duplicate does not block a later valid candidate with the same ID.
            seenIDs.insert(normalized.id)
            duplicates.insert(normalized)
            acceptedCount += 1
            items.append(ImportPreviewItem(
                id: offset,
                preset: candidate,
                normalizedPreset: normalized,
                rejectionReason: nil
            ))
        }
        return ImportPreview(items: items)
    }

    /// The stored JSON of the presets for a configuration backup, keeping
    /// fields a newer build wrote. Nil when there is nothing to export (see
    /// `canExportPresets`).
    func exportedPresetsJSON() throws -> Any? {
        guard canExportPresets else { return nil }
        return try persistence.mergedJSONObject(presets)
    }

    /// Exports the stored JSON of the presets in memory, so fields written by a
    /// newer build, which ordinary saves keep, are not dropped from a backup.
    func encodedPresetArchive() throws -> Data {
        guard canExportPresets else { throw PresetArchiveError.unreadable }
        let archive: [String: Any] = [
            "schemaVersion": PresetArchive.currentSchemaVersion,
            "presets": try persistence.mergedJSONObject(presets)
        ]
        return try JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys])
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
            if let presets = envelope["presets"] as? [Any], presets.count > maximumPresetCount {
                throw PresetArchiveError.exceedsMaximumCount
            }
            do {
                return try decoder.decode(PresetArchive.self, from: data).presets
            } catch {
                throw PresetArchiveError.invalidContents(describeDecodingError(error))
            }
        }
        if let presets = topLevel as? [Any] {
            guard presets.count <= maximumPresetCount else {
                throw PresetArchiveError.exceedsMaximumCount
            }
            do {
                return try decoder.decode([WatchedAppPreset].self, from: data)
            } catch {
                throw PresetArchiveError.invalidContents(describeDecodingError(error))
            }
        }
        throw PresetArchiveError.unreadable
    }

    nonisolated static func describeDecodingError(_ error: Error) -> String {
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

    /// Validation for a preset the user is adding or editing now. On top of the
    /// stored-value rules it checks what the app path points at today.
    private func validateAndNormalize(_ preset: WatchedAppPreset) -> WatchedAppPreset? {
        let result = Self.validateAndNormalizePreset(preset)
        guard let normalized = result.preset else {
            validationError = result.error
            return nil
        }
        if let bundleError = Self.bundleTargetError(normalized) {
            validationError = bundleError
            return nil
        }
        validationError = nil
        return normalized
    }

    /// Revalidates stored presets. Nothing here may depend on the file system
    /// beyond spelling, because a preset this build saved must load again
    /// unchanged however links and installs changed in between.
    nonisolated static func validatedPresets(
        _ candidates: [WatchedAppPreset]
    ) -> (presets: [WatchedAppPreset], rejectedCount: Int) {
        var accepted: [WatchedAppPreset] = []
        var seenIDs: Set<UUID> = []
        var duplicates = DuplicateIndex([], comparesResolvedPaths: false)
        var rejected = 0

        for candidate in candidates {
            guard let preset = validateAndNormalizePreset(candidate).preset else {
                rejected += 1
                continue
            }
            guard seenIDs.insert(preset.id).inserted,
                  duplicates.collision(for: preset) == nil else {
                rejected += 1
                continue
            }
            duplicates.insert(preset)
            accepted.append(preset)
        }
        return (accepted, rejected)
    }

    /// Launch agents, daemons and process names that belong to GlobalProtect.
    /// Only the built-in preset may act on them: its actions disconnect first
    /// and keep the VPN service, while a custom preset's Quit and Open would
    /// boot out or start them directly.
    nonisolated private static let reservedGlobalProtectLabels = Set(
        (WatchedAppPreset.globalProtectUserLaunchAgentJobs.map(\.label)
            + WatchedAppPreset.globalProtectSystemLaunchDaemonJobs.map(\.label)).map { $0.lowercased() }
    )
    nonisolated private static let reservedGlobalProtectPlistPaths = Set(
        (WatchedAppPreset.globalProtectUserLaunchAgentJobs.map(\.plistPath)
            + WatchedAppPreset.globalProtectSystemLaunchDaemonJobs.map(\.plistPath)).map { $0.lowercased() }
    )
    nonisolated private static let reservedGlobalProtectProcessNames = Set(
        WatchedAppPreset.globalProtectSystemLaunchDaemonJobs.map { $0.processName.lowercased() }
    )

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
        // Before the path is standardized or resolved: realpath reads a path
        // only up to an embedded NUL and could hide it.
        if let error = PresetFieldValidation.error(in: value) { return (nil, error) }
        guard !value.displayName.isEmpty, !value.mainProcessName.isEmpty else {
            return (nil, "Display name and main process name are required.")
        }
        guard value.appPath.hasPrefix("/"),
              URL(fileURLWithPath: value.appPath).pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return (nil, "App path must be an absolute .app bundle path.")
        }
        // The configured path is stored, standardized but not resolved: links are
        // followed when the preset is matched or opened (`resolvedAppPath`), so
        // the stored value never depends on what the file system held at save.
        value.appPath = URL(fileURLWithPath: value.appPath).standardizedFileURL.path
        if value.id != WatchedAppPreset.globalProtectID {
            // Process names match case-sensitively, so a main name that differs
            // from the bundle executable only by case could never match. Adopt
            // the executable's spelling rather than rejecting a stored preset.
            if let executable = Bundle(path: value.resolvedAppPath)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
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
        // The main process name can take the bundle executable's spelling.
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
        } else {
            guard value.systemLaunchDaemonJobs.isEmpty else {
                return (nil, "Custom presets cannot configure privileged system launch daemons.")
            }
            let usesReservedJob = value.userLaunchAgentJobs.contains {
                reservedGlobalProtectLabels.contains($0.label.lowercased())
                    || reservedGlobalProtectPlistPaths.contains($0.plistPath.lowercased())
            }
            guard !usesReservedJob,
                  killable.isDisjoint(with: reservedGlobalProtectProcessNames) else {
                return (nil, "GlobalProtect's launch agents and its PanGPS service are reserved for the built-in GlobalProtect preset.")
            }
        }
        guard let jobsError = jobsValidationError(value) else {
            return (value, nil)
        }
        return (nil, jobsError)
    }

    /// A `*.app` link must lead to an app bundle: its name passed the extension
    /// check, but its target can be a script, a document or any folder, which
    /// `/usr/bin/open` would run or show. A link with nothing behind it yet stays
    /// configurable, like an app that is not installed. Checked when a preset is
    /// added, edited or imported, never at load, where a later change on disk
    /// must not reject a preset this build saved; Open checks again.
    nonisolated private static func bundleTargetError(_ preset: WatchedAppPreset) -> String? {
        guard preset.id != WatchedAppPreset.globalProtectID,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: preset.appPath)) != nil,
              FileManager.default.fileExists(atPath: preset.appPath) else {
            return nil
        }
        return SystemProcessLifecycleService.isAppBundle(at: preset.appPath)
            ? nil
            : "App path must lead to an app bundle: \(preset.resolvedAppPath) is not a folder named .app with Contents/Info.plist."
    }

    nonisolated private static func normalizedPlistPath(_ value: String) -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : path
    }

    /// Custom presets cannot carry system daemons, and the built-in preset is
    /// replaced by its canonical value before this runs, so only user launch
    /// agents need checking here.
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
        let others = presets.filter { $0.id != id }
        guard let collision = DuplicateIndex(others, comparesResolvedPaths: true).collision(for: preset) else {
            return false
        }
        validationError = collision
        return true
    }

    private func persistIfAllowed() {
        guard allowsPersistence else { return }
        persistence.savePreservingUnknownFields(presets)
    }

}

/// Presets are distinct by display name and by app path, compared
/// case-insensitively. Two presets may share a main process name: each one only
/// matches processes inside its own bundle. Lookups are by key, so validating an
/// archive or a stored list is linear in the number of presets.
private struct DuplicateIndex {
    private var names: [String: String] = [:]
    private var paths: [String: String] = [:]
    private let comparesResolvedPaths: Bool

    /// `comparesResolvedPaths` also treats two paths that lead to the same
    /// bundle today as one. Only checks for a change made now may use it; a
    /// stored list must not depend on the file system.
    init(_ presets: [WatchedAppPreset], comparesResolvedPaths: Bool) {
        self.comparesResolvedPaths = comparesResolvedPaths
        presets.forEach { insert($0) }
    }

    func collision(for preset: WatchedAppPreset) -> String? {
        if let owner = names[Self.key(preset.displayName)] {
            return "A preset named “\(owner)” already exists."
        }
        if let owner = pathKeys(for: preset).lazy.compactMap({ paths[$0] }).first {
            return "The preset “\(owner)” already watches this app path."
        }
        return nil
    }

    mutating func insert(_ preset: WatchedAppPreset) {
        names[Self.key(preset.displayName)] = names[Self.key(preset.displayName)] ?? preset.displayName
        for key in pathKeys(for: preset) where paths[key] == nil {
            paths[key] = preset.displayName
        }
    }

    private func pathKeys(for preset: WatchedAppPreset) -> [String] {
        let configured = Self.key(preset.appPath)
        guard comparesResolvedPaths else { return [configured] }
        let resolved = Self.key(preset.resolvedAppPath)
        return resolved == configured ? [configured] : [configured, resolved]
    }

    /// Case folding matches `caseInsensitiveCompare`, which this check used
    /// before, and String equality adds canonical equivalence.
    private static func key(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: nil)
    }
}
