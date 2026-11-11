import Foundation

@MainActor
final class SavedSelectionsStore: ObservableObject {
    struct SavedProcess: Codable, Equatable, Identifiable {
        var pid: Int32
        var command: String
        var executablePath: String?
        var executableName: String
        /// When the process started, so recall can recognize the saved process
        /// itself among more running copies. Nil for entries saved before start
        /// times were kept; older builds leave the field in place.
        var startTime: String?

        var id: String {
            "\(executablePath ?? command)|\(executableName)|\(pid)"
        }

        init(
            pid: Int32,
            command: String,
            executableName: String,
            executablePath: String? = nil,
            startTime: String? = nil
        ) {
            self.pid = pid
            self.command = command
            self.executablePath = executablePath
            self.executableName = executableName
            self.startTime = startTime
        }

        init(process: AppProcess) {
            self.init(
                pid: process.pid,
                command: process.command,
                executableName: process.name,
                executablePath: process.executablePath,
                startTime: process.startTime.isEmpty ? nil : process.startTime
            )
        }

        private enum CodingKeys: String, CodingKey {
            case pid, command, executablePath, executableName, startTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = try container.decode(Int32.self, forKey: .pid)
            command = try container.decode(String.self, forKey: .command)
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
            executableName = try container.decodeIfPresent(String.self, forKey: .executableName)
                ?? URL(fileURLWithPath: command).lastPathComponent
            startTime = try container.decodeIfPresent(String.self, forKey: .startTime)
        }
    }

    struct SavedSelection: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
        var pids: [Int32]
        var processes: [SavedProcess]
        var isLegacyUnsupported: Bool

        private enum CodingKeys: String, CodingKey {
            case id, name, pids, processes, isLegacyUnsupported
        }

        init(
            id: UUID = UUID(),
            name: String,
            pids: [Int32],
            processes: [SavedProcess],
            isLegacyUnsupported: Bool = false
        ) {
            self.id = id
            self.name = name
            self.pids = pids
            self.processes = processes
            self.isLegacyUnsupported = isLegacyUnsupported
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Recovered Selection"
            pids = try container.decodeIfPresent([Int32].self, forKey: .pids) ?? []
            if let decodedProcesses = try container.decodeIfPresent(
                [SavedProcess].self,
                forKey: .processes
            ) {
                processes = decodedProcesses
                isLegacyUnsupported = try container.decodeIfPresent(
                    Bool.self,
                    forKey: .isLegacyUnsupported
                ) ?? false
            } else {
                processes = []
                isLegacyUnsupported = !pids.isEmpty
            }
        }
    }

    struct RecallResult: Equatable {
        var matched: [AppProcess]
        var unmatched: [SavedProcess]
        var ambiguous: [SavedProcess]
        var legacyUnsupported: Bool
        /// Matches produced by the legacy command/name fallback because the
        /// saved entry carries no kernel executable path. Shown with a visible
        /// marker so a name-only match is never mistaken for a path-bound one.
        var legacyNameMatches: Set<ProcessIdentity> = []

        var summary: String {
            if legacyUnsupported {
                return "This legacy selection contains only PIDs and cannot be recalled safely."
            }
            return "\(matched.count) matched, \(unmatched.count) unavailable, \(ambiguous.count) ambiguous."
        }
    }

    @Published private(set) var selections: [SavedSelection] {
        didSet { saveToDefaults() }
    }
    @Published private(set) var validationError: String?
    @Published private(set) var recoveryMessage: String?

    private let persistence: RecoveringCodableStorage<[SavedSelection]>
    private var allowsPersistence: Bool

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.savedSelections.v1"
    ) {
        let persistence = RecoveringCodableStorage<[SavedSelection]>(
            userDefaults: userDefaults,
            key: key
        )
        self.persistence = persistence
        allowsPersistence = true
        let loaded = persistence.loadRecoveringElements()
        // Rename and Delete find a selection by its id, so a repeated id would
        // send them to the wrong entry, or to all of its copies. Keep the first
        // and treat later copies as rejected entries.
        var seenIDs: Set<UUID> = []
        var recovered: [SavedSelection] = []
        var repeatedIDCount = 0
        for selection in loaded.value ?? [] {
            if seenIDs.insert(selection.id).inserted {
                recovered.append(selection)
            } else {
                repeatedIDCount += 1
            }
        }
        selections = recovered
        let rejectedCount = loaded.rejectedCount + repeatedIDCount
        if rejectedCount > 0 {
            let backup = persistence.preserveCurrentPayload(suffix: "rejectedMigrationBackup")
                ?? (key: "\(key).rejectedMigrationBackup", isPreserved: false)
            allowsPersistence = false
            recoveryMessage = "Rejected \(rejectedCount) invalid or duplicate stored selection\(rejectedCount == 1 ? "" : "s"). "
                + PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)
                + "; review the recovered selections, then reset to commit them."
        } else if let backupKey = loaded.backupKey {
            // Writing now would replace the unreadable payload with the empty
            // array we fell back to, destroying it at its primary key. A payload
            // that decoded but cannot be written back keeps its selections.
            allowsPersistence = false
            recoveryMessage = loaded.unrewritableDataDescription.map { "Saved selections were read, but the payload \($0)" }
                ?? "Saved selections were unreadable. "
                + PersistenceRecovery.unreadableDataMessage(
                    backupKey: backupKey,
                    isPreserved: loaded.isBackupPreserved
                )
        }
    }

    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// False while the unreadable payload a reset would replace exists in no
    /// recovery slot, so the reset would destroy its only copy.
    var isRecoveryBackupPreserved: Bool {
        persistence.isCurrentPayloadPreserved
    }

    /// Clears a message left by an earlier attempt so a newly presented sheet
    /// does not open with an unrelated error.
    func clearValidationError() {
        validationError = nil
    }

    /// Explicitly accepts the recovered selections and resumes durable mutations.
    /// A payload with no decodable entries resumes from an empty selection list.
    func resetAfterCorruption() {
        guard !allowsPersistence else { return }
        allowsPersistence = true
        recoveryMessage = nil
        validationError = nil
        saveToDefaults()
    }

    private func rejectIfReadOnly() -> Bool {
        guard !allowsPersistence else { return false }
        validationError = "Saved selection data is unreadable; reset it before making changes."
        return true
    }

    @discardableResult
    func save(name: String, processes: [AppProcess]) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Self.nameValidationError(trimmedName) {
            validationError = error
            return false
        }
        guard !processes.isEmpty else {
            validationError = "Select at least one process."
            return false
        }
        guard !containsName(trimmedName) else {
            validationError = "A saved selection named \(trimmedName) already exists."
            return false
        }
        // A new entry without a kernel executable path could only ever be
        // recalled through the spoofable legacy command/name fallback. Refuse
        // it rather than silently saving a name-only match.
        let unverifiable = processes.filter { $0.executablePath == nil }
        guard unverifiable.isEmpty else {
            let names = unverifiable.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
            validationError = "Cannot save \(names): no kernel executable path is available, so the selection could only be recalled by name."
            return false
        }

        validationError = nil
        selections.append(
            SavedSelection(
                name: trimmedName,
                pids: processes.map(\.pid),
                processes: processes.map(SavedProcess.init)
            )
        )
        return true
    }

    @discardableResult
    func rename(_ selection: SavedSelection, to name: String) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Self.nameValidationError(trimmedName) {
            validationError = error
            return false
        }
        guard !containsName(trimmedName, excluding: selection.id) else {
            validationError = "A saved selection named \(trimmedName) already exists."
            return false
        }
        guard let index = selections.firstIndex(where: { $0.id == selection.id }) else {
            // Another window may have deleted it while the rename sheet was open.
            validationError = "This saved selection no longer exists."
            return false
        }
        validationError = nil
        selections[index].name = trimmedName
        return true
    }

    func resolve(_ selection: SavedSelection, in processes: [AppProcess]) -> RecallResult {
        Self.resolve(selection, in: processes, standardizedPath: Self.standardizedPath)
    }

    /// Matches a saved selection against the live inventory. Each saved and each
    /// running executable path is standardized once (standardizing asks the file
    /// system), so a selection that spans many executables stays linear on the
    /// main actor. `standardizedPath` is a seam for tests.
    nonisolated static func resolve(
        _ selection: SavedSelection,
        in processes: [AppProcess],
        standardizedPath: (String) -> String
    ) -> RecallResult {
        guard !selection.isLegacyUnsupported else {
            return RecallResult(
                matched: [],
                unmatched: [],
                ambiguous: [],
                legacyUnsupported: true
            )
        }

        var matched: [AppProcess] = []
        var unmatched: [SavedProcess] = []
        var ambiguous: [SavedProcess] = []
        var legacyNameMatches: Set<ProcessIdentity> = []
        var claimedIdentities: Set<ProcessIdentity> = []

        let savedPaths = selection.processes.map { $0.executablePath.map(standardizedPath) }
        // Buckets keep the saved and inventory order of each path's entries.
        var groups: [String: [SavedProcess]] = [:]
        for (saved, path) in zip(selection.processes, savedPaths) {
            if let path { groups[path, default: []].append(saved) }
        }
        var runningByPath: [String: [AppProcess]] = [:]
        for process in processes {
            if let path = process.executablePath.map(standardizedPath) {
                runningByPath[path, default: []].append(process)
            }
        }

        var resolvedPaths: Set<String> = []
        for (saved, savedPath) in zip(selection.processes, savedPaths) {
            if let path = savedPath {
                guard resolvedPaths.insert(path).inserted else { continue }
                var group = groups[path] ?? []
                // Checked here, not when bucketing: a legacy entry earlier in the
                // loop may already have claimed one of these processes.
                var candidates = (runningByPath[path] ?? []).filter {
                    !claimedIdentities.contains($0.identity)
                }
                // A saved process that is still running is recognized by its PID
                // and start time even when more copies run than were saved. An
                // entry saved before start times were kept falls back to its PID,
                // which with the same executable is no weaker than the path match.
                group.removeAll { entry in
                    guard let index = candidates.firstIndex(where: { candidate in
                        candidate.pid == entry.pid
                            && (entry.startTime.map { $0 == candidate.startTime } ?? true)
                    }) else {
                        return false
                    }
                    let original = candidates.remove(at: index)
                    matched.append(original)
                    claimedIdentities.insert(original.identity)
                    return true
                }
                // The saved count bounds the rest of this path's group; PIDs may
                // have changed. More unclaimed copies than saved entries cannot be
                // told apart, so none of them is selected.
                if candidates.count > group.count {
                    ambiguous.append(contentsOf: group)
                } else {
                    matched.append(contentsOf: candidates)
                    claimedIdentities.formUnion(candidates.map(\.identity))
                    unmatched.append(contentsOf: group.dropFirst(candidates.count))
                }
                continue
            }
            // Legacy payloads retain their command/name fallback and marker.
            let exactCommand = processes.filter { $0.command == saved.command }
            let candidates = exactCommand.isEmpty
                ? processes.filter {
                    $0.name.caseInsensitiveCompare(saved.executableName) == .orderedSame
                }
                : exactCommand

            let unclaimed = candidates.filter { !claimedIdentities.contains($0.identity) }
            if unclaimed.count == 1, let match = unclaimed.first {
                matched.append(match)
                claimedIdentities.insert(match.identity)
                if saved.executablePath == nil {
                    legacyNameMatches.insert(match.identity)
                }
            } else if unclaimed.isEmpty {
                // Every candidate was claimed by an earlier entry, so nothing is
                // left for this one; that is unavailable, not ambiguous.
                unmatched.append(saved)
            } else {
                ambiguous.append(saved)
            }
        }

        return RecallResult(
            matched: matched,
            unmatched: unmatched,
            ambiguous: ambiguous,
            legacyUnsupported: false,
            legacyNameMatches: legacyNameMatches
        )
    }

    @discardableResult
    func remove(_ selection: SavedSelection) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard selections.contains(where: { $0.id == selection.id }) else { return false }
        selections.removeAll { $0.id == selection.id }
        validationError = nil
        return true
    }

    nonisolated static let maximumNameLength = 100

    /// Applied to names typed now (Save and Rename), never at load, so an
    /// existing odd name stays readable and can be renamed. Names are menu and
    /// sheet titles: line breaks, control characters and bidirectional
    /// overrides would split or disguise them, and a long one pushes the recall
    /// sheet's buttons off screen. Other format characters such as the joiners
    /// in emoji sequences stay allowed.
    nonisolated static func nameValidationError(_ name: String) -> String? {
        guard !name.isEmpty else { return "Selection name is required." }
        guard name.count <= maximumNameLength else {
            return "Selection names must be \(maximumNameLength) characters or fewer."
        }
        let disallowed = name.unicodeScalars.contains {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
                || $0.value == 0x2028 || $0.value == 0x2029
                || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }
        guard !disallowed else {
            return "Selection names cannot contain line breaks, control characters or bidirectional formatting characters."
        }
        return nil
    }

    private func containsName(_ name: String, excluding id: UUID? = nil) -> Bool {
        selections.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Executables are files, so `isDirectory: false` spares the directory check.
    nonisolated private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }

    private func saveToDefaults() {
        guard allowsPersistence else { return }
        persistence.savePreservingUnknownFields(selections)
    }

}
