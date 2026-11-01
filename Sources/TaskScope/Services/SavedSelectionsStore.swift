import Foundation

@MainActor
final class SavedSelectionsStore: ObservableObject {
    struct SavedProcess: Codable, Equatable, Identifiable {
        var pid: Int32
        var command: String
        var executablePath: String?
        var executableName: String

        var id: String {
            "\(executablePath ?? command)|\(executableName)|\(pid)"
        }

        init(
            pid: Int32,
            command: String,
            executableName: String,
            executablePath: String? = nil
        ) {
            self.pid = pid
            self.command = command
            self.executablePath = executablePath
            self.executableName = executableName
        }

        init(process: AppProcess) {
            self.init(
                pid: process.pid,
                command: process.command,
                executableName: process.name,
                executablePath: process.executablePath
            )
        }

        private enum CodingKeys: String, CodingKey {
            case pid, command, executablePath, executableName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pid = try container.decode(Int32.self, forKey: .pid)
            command = try container.decode(String.self, forKey: .command)
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
            executableName = try container.decodeIfPresent(String.self, forKey: .executableName)
                ?? URL(fileURLWithPath: command).lastPathComponent
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
        selections = loaded.value ?? []
        if loaded.rejectedCount > 0 {
            let backup = persistence.preserveCurrentPayload(suffix: "rejectedMigrationBackup")
                ?? (key: "\(key).rejectedMigrationBackup", isPreserved: false)
            allowsPersistence = false
            recoveryMessage = "Rejected \(loaded.rejectedCount) invalid stored selection\(loaded.rejectedCount == 1 ? "" : "s"). "
                + PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)
                + "; review the recovered selections, then reset to commit them."
        } else if let backupKey = loaded.backupKey {
            // Writing now would replace the unreadable payload with the empty
            // array we fell back to, destroying it at its primary key.
            allowsPersistence = false
            recoveryMessage = "Saved selections were unreadable. "
                + PersistenceRecovery.unreadableDataMessage(
                    backupKey: backupKey,
                    isPreserved: loaded.isBackupPreserved
                )
        }
    }

    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
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
        guard !trimmedName.isEmpty else {
            validationError = "Selection name is required."
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
        guard !trimmedName.isEmpty else {
            validationError = "Selection name is required."
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

        var resolvedPaths: Set<String> = []
        for saved in selection.processes {
            if let savedPath = saved.executablePath {
                let path = standardizedPath(savedPath)
                guard resolvedPaths.insert(path).inserted else { continue }
                let group = selection.processes.filter {
                    $0.executablePath.map(standardizedPath) == path
                }
                // The saved count bounds this path's group; PIDs may have changed.
                let candidates = processes.filter {
                    $0.executablePath.map(standardizedPath) == path
                        && !claimedIdentities.contains($0.identity)
                }
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
    func remove(at offsets: IndexSet) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        selections.remove(atOffsets: offsets)
        validationError = nil
        return true
    }

    @discardableResult
    func remove(_ selection: SavedSelection) -> Bool {
        guard !rejectIfReadOnly() else { return false }
        guard selections.contains(where: { $0.id == selection.id }) else { return false }
        selections.removeAll { $0.id == selection.id }
        validationError = nil
        return true
    }

    private func containsName(_ name: String, excluding id: UUID? = nil) -> Bool {
        selections.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func saveToDefaults() {
        guard allowsPersistence else { return }
        persistence.savePreservingUnknownFields(selections)
    }

}
