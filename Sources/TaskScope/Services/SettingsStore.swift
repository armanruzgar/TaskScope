import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    /// "Show all processes". Kept in `processListLimit` rather than a new
    /// field: an older build clamps it to its own maximum in memory and keeps
    /// the stored value, instead of finding a payload it cannot decode.
    nonisolated static let allProcessesLimit = 100_000
    nonisolated static let processListLimitRange: ClosedRange<Int> = 10...200

    /// The memory slider's grid. 1024 (the default) is on it: 128 + 14 × 64.
    nonisolated static let memoryThresholdRange: ClosedRange<Double> = 128...8192
    nonisolated static let memoryThresholdStep: Double = 64

    @Published var refreshIntervalSeconds: Double {
        didSet { normalizeAndSave() }
    }
    @Published var processListLimit: Int {
        didSet { normalizeAndSave() }
    }
    @Published var cpuHighlightThreshold: Double {
        didSet { normalizeAndSave() }
    }
    @Published var memHighlightThresholdMB: Double {
        didSet { normalizeAndSave() }
    }
    @Published var autoRefreshProcessList: Bool {
        didSet { save() }
    }
    @Published var enableNotifications: Bool {
        didSet { save() }
    }
    @Published var keepGlobalProtectOff: Bool {
        didSet { save() }
    }
    @Published var selectedSectionRaw: String {
        didSet { normalizeAndSave() }
    }
    /// Typed on every keystroke; persisted after a short quiet period rather than
    /// hitting UserDefaults per character.
    @Published var searchText: String {
        didSet { normalizeAndScheduleSearchSave() }
    }
    @Published var sortKeyRaw: String {
        didSet { normalizeAndSave() }
    }
    /// The direction of `sortKeyRaw`. A payload without one, from a build
    /// before directions, sorts in the key's default direction.
    @Published var sortDirectionRaw: String {
        didSet { normalizeAndSave() }
    }
    /// The process list's Filter and Tree View choices, shared by the window and
    /// the menu-bar popover and kept across launches, like Sort.
    @Published var filterModeRaw: String {
        didSet { normalizeAndSave() }
    }
    @Published var treeMode: Bool {
        didSet { save() }
    }
    /// The menu-bar icon shows TaskScope's state. While it does, watched status
    /// is read in the background so the icon stays current.
    @Published var showsMenuBarStatus: Bool {
        didSet { save() }
    }
    @Published private(set) var recoveryMessage: String?

    private let persistence: RecoveringCodableStorage<CodableSettings>
    private var lastSavedSettings: CodableSettings
    private var isNormalizing = false
    private var allowsPersistence: Bool
    private let searchPersistenceDelay: TimeInterval
    private var pendingSearchSave: Task<Void, Never>?

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "TaskScope.settings.v1",
        searchPersistenceDelay: TimeInterval = 0.5
    ) {
        let persistence = RecoveringCodableStorage<CodableSettings>(
            userDefaults: userDefaults,
            key: key
        )
        self.persistence = persistence
        self.searchPersistenceDelay = max(0, searchPersistenceDelay)
        let result = persistence.load()
        let decoded: CodableSettings
        if !persistence.hasStoredValue {
            decoded = .defaults
            recoveryMessage = nil
            allowsPersistence = true
        } else if let settings = result.value {
            decoded = settings.normalized()
            // Readable settings apply even when the payload cannot be written
            // back without losing a value; they stay read-only until reset.
            recoveryMessage = result.unrewritableDataDescription.map { "Settings were read, but the payload \($0)" }
            allowsPersistence = !result.isDecodedButUnrewritable
        } else {
            decoded = .defaults
            let backupKey = result.backupKey ?? "\(key).corruptBackup"
            recoveryMessage = "Settings were unreadable. \(PersistenceRecovery.preservedPayloadDescription(backupKey: backupKey, isPreserved: result.isBackupPreserved)), and the current primary remains untouched until reset."
            allowsPersistence = false
        }

        lastSavedSettings = decoded
        refreshIntervalSeconds = decoded.refreshIntervalSeconds
        processListLimit = decoded.processListLimit
        cpuHighlightThreshold = decoded.cpuHighlightThreshold
        memHighlightThresholdMB = decoded.memHighlightThresholdMB
        autoRefreshProcessList = decoded.autoRefreshProcessList
        enableNotifications = decoded.enableNotifications
        keepGlobalProtectOff = decoded.keepGlobalProtectOff
        selectedSectionRaw = decoded.selectedSectionRaw
        searchText = decoded.searchText
        sortKeyRaw = decoded.sortKeyRaw
        sortDirectionRaw = decoded.sortDirectionRaw
        filterModeRaw = decoded.filterModeRaw
        treeMode = decoded.treeMode
        showsMenuBarStatus = decoded.showsMenuBarStatus
    }

    var filterMode: ProcessFilterMode {
        ProcessFilterMode(rawValue: filterModeRaw) ?? .all
    }

    /// Lifts the process list limit, so every process can be browsed in any
    /// sort order. Turning it off returns to the default limit.
    var showsAllProcesses: Bool {
        get { processListLimit == Self.allProcessesLimit }
        set { processListLimit = newValue ? Self.allProcessesLimit : CodableSettings.defaults.processListLimit }
    }

    var sortKey: ProcessSortKey {
        ProcessSortKey(rawValue: sortKeyRaw) ?? .cpu
    }

    var sortDirection: ProcessSortDirection {
        ProcessSortDirection(rawValue: sortDirectionRaw) ?? sortKey.defaultDirection
    }

    var sortOrder: ProcessSortOrder {
        ProcessSortOrder(key: sortKey, direction: sortDirection)
    }

    func setSortOrder(_ order: ProcessSortOrder) {
        sortKeyRaw = order.key.rawValue
        sortDirectionRaw = order.direction.rawValue
    }

    var selectedSection: TaskScopeSection {
        TaskScopeSection(rawValue: selectedSectionRaw) ?? .processes
    }

    var isReadOnlyAfterCorruption: Bool {
        !allowsPersistence
    }

    /// False while the unreadable payload a reset would replace exists in no
    /// recovery slot, so the reset would destroy its only copy.
    var isRecoveryBackupPreserved: Bool {
        persistence.isCurrentPayloadPreserved
    }

    /// Explicitly accepts the safe in-memory settings and resumes persistence. Until
    /// this is called, every property may be used by the running app but the unreadable
    /// primary bytes remain untouched.
    func resetAfterCorruption() {
        guard !allowsPersistence else { return }
        allowsPersistence = true
        recoveryMessage = nil
        // The primary may hold bytes this build cannot decode or write back,
        // which `save()` refuses to replace; reset is the explicit overwrite.
        // They were backed up when the problem was found.
        persistence.save(currentSettings.normalized())
        normalizeAndSave()
    }

    /// Writes any debounced search text immediately (app termination).
    func flushPendingWrites() {
        guard pendingSearchSave != nil else { return }
        pendingSearchSave?.cancel()
        pendingSearchSave = nil
        save()
    }

    private func normalizeAndScheduleSearchSave() {
        guard !isNormalizing else { return }
        let normalized = currentSettings.normalized()
        if normalized.searchText != searchText {
            isNormalizing = true
            searchText = normalized.searchText
            isNormalizing = false
        }
        pendingSearchSave?.cancel()
        let delay = searchPersistenceDelay
        pendingSearchSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingSearchSave = nil
            self.save()
        }
    }

    private func normalizeAndSave() {
        guard !isNormalizing else { return }
        let normalized = currentSettings.normalized()
        if normalized != currentSettings {
            isNormalizing = true
            refreshIntervalSeconds = normalized.refreshIntervalSeconds
            processListLimit = normalized.processListLimit
            cpuHighlightThreshold = normalized.cpuHighlightThreshold
            memHighlightThresholdMB = normalized.memHighlightThresholdMB
            selectedSectionRaw = normalized.selectedSectionRaw
            searchText = normalized.searchText
            sortKeyRaw = normalized.sortKeyRaw
            sortDirectionRaw = normalized.sortDirectionRaw
            filterModeRaw = normalized.filterModeRaw
            treeMode = normalized.treeMode
            isNormalizing = false
        }
        save()
    }

    private var currentSettings: CodableSettings {
        CodableSettings(
            schemaVersion: CodableSettings.currentSchemaVersion,
            refreshIntervalSeconds: refreshIntervalSeconds,
            processListLimit: processListLimit,
            cpuHighlightThreshold: cpuHighlightThreshold,
            memHighlightThresholdMB: memHighlightThresholdMB,
            autoRefreshProcessList: autoRefreshProcessList,
            enableNotifications: enableNotifications,
            keepGlobalProtectOff: keepGlobalProtectOff,
            selectedSectionRaw: selectedSectionRaw,
            searchText: searchText,
            sortKeyRaw: sortKeyRaw,
            sortDirectionRaw: sortDirectionRaw,
            filterModeRaw: filterModeRaw,
            treeMode: treeMode,
            showsMenuBarStatus: showsMenuBarStatus
        )
    }

    private func save() {
        guard allowsPersistence, !isNormalizing else {
            return
        }
        let settings = currentSettings.normalized()
        defer { lastSavedSettings = settings }
        guard let storedData = persistence.rawData,
              (try? JSONDecoder().decode(CodableSettings.self, from: storedData)) != nil,
              var stored = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any],
              let encoded = try? JSONEncoder().encode(settings),
              var values = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            guard persistence.hasStoredValue else {
                persistence.save(settings)
                return
            }
            // Something outside TaskScope replaced the stored settings with a
            // payload this build cannot read or write back. Overwriting it would
            // destroy it, so keep it, back it up and stop writing, as load does.
            let backup = persistence.preserveCurrentPayload(suffix: "corruptBackup")
                ?? (key: "\(persistence.key).corruptBackup", isPreserved: false)
            allowsPersistence = false
            recoveryMessage = "Stored settings were changed outside TaskScope and can no longer be read. "
                + PersistenceRecovery.preservedPayloadDescription(backupKey: backup.key, isPreserved: backup.isPreserved)
                + "; the current settings stay in use and are saved again after reset."
            return
        }
        // A downgrade may edit known settings without discarding newer fields
        // or claiming that the stored payload has an older schema.
        if let version = stored["schemaVersion"] as? Int, version > settings.schemaVersion {
            values["schemaVersion"] = version
        }
        let previous = (try? JSONEncoder().encode(lastSavedSettings))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        for (key, value) in values {
            if key == "schemaVersion" || stored[key] == nil || (previous[key] as? NSObject)?.isEqual(value) != true {
                stored[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: stored) else { return }
        persistence.userDefaults.set(data, forKey: persistence.key)
    }

    private struct CodableSettings: Codable, Equatable {
        static let currentSchemaVersion = 3
        static let defaults = CodableSettings(
            schemaVersion: currentSchemaVersion,
            refreshIntervalSeconds: 10,
            processListLimit: 80,
            cpuHighlightThreshold: 30,
            memHighlightThresholdMB: 1024,
            autoRefreshProcessList: false,
            enableNotifications: false,
            keepGlobalProtectOff: false,
            selectedSectionRaw: TaskScopeSection.processes.rawValue,
            searchText: "",
            sortKeyRaw: ProcessSortKey.cpu.rawValue,
            sortDirectionRaw: ProcessSortKey.cpu.defaultDirection.rawValue
        )

        var schemaVersion: Int
        var refreshIntervalSeconds: Double
        var processListLimit: Int
        var cpuHighlightThreshold: Double
        var memHighlightThresholdMB: Double
        var autoRefreshProcessList: Bool
        var enableNotifications: Bool
        var keepGlobalProtectOff: Bool
        var selectedSectionRaw: String
        var searchText: String
        var sortKeyRaw: String
        var sortDirectionRaw: String
        var filterModeRaw: String
        var treeMode: Bool
        var showsMenuBarStatus: Bool

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case refreshIntervalSeconds
            case processListLimit
            case cpuHighlightThreshold
            case memHighlightThresholdMB
            case autoRefreshProcessList
            case enableNotifications
            case keepGlobalProtectOff
            case selectedSectionRaw
            case searchText
            case sortKeyRaw
            case sortDirectionRaw
            case filterModeRaw
            case treeMode
            case showsMenuBarStatus
        }

        init(
            schemaVersion: Int,
            refreshIntervalSeconds: Double,
            processListLimit: Int,
            cpuHighlightThreshold: Double,
            memHighlightThresholdMB: Double,
            autoRefreshProcessList: Bool,
            enableNotifications: Bool,
            keepGlobalProtectOff: Bool,
            selectedSectionRaw: String,
            searchText: String,
            sortKeyRaw: String,
            sortDirectionRaw: String = "",
            filterModeRaw: String = ProcessFilterMode.all.rawValue,
            treeMode: Bool = false,
            showsMenuBarStatus: Bool = true
        ) {
            self.schemaVersion = schemaVersion
            self.refreshIntervalSeconds = refreshIntervalSeconds
            self.processListLimit = processListLimit
            self.cpuHighlightThreshold = cpuHighlightThreshold
            self.memHighlightThresholdMB = memHighlightThresholdMB
            self.autoRefreshProcessList = autoRefreshProcessList
            self.enableNotifications = enableNotifications
            self.keepGlobalProtectOff = keepGlobalProtectOff
            self.selectedSectionRaw = selectedSectionRaw
            self.searchText = searchText
            self.sortKeyRaw = sortKeyRaw
            self.sortDirectionRaw = sortDirectionRaw
            self.filterModeRaw = filterModeRaw
            self.treeMode = treeMode
            self.showsMenuBarStatus = showsMenuBarStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self.defaults
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            refreshIntervalSeconds = try container.decodeIfPresent(
                Double.self,
                forKey: .refreshIntervalSeconds
            ) ?? defaults.refreshIntervalSeconds
            processListLimit = try container.decodeIfPresent(
                Int.self,
                forKey: .processListLimit
            ) ?? defaults.processListLimit
            cpuHighlightThreshold = try container.decodeIfPresent(
                Double.self,
                forKey: .cpuHighlightThreshold
            ) ?? defaults.cpuHighlightThreshold
            memHighlightThresholdMB = try container.decodeIfPresent(
                Double.self,
                forKey: .memHighlightThresholdMB
            ) ?? defaults.memHighlightThresholdMB
            autoRefreshProcessList = try container.decodeIfPresent(
                Bool.self,
                forKey: .autoRefreshProcessList
            ) ?? defaults.autoRefreshProcessList
            enableNotifications = try container.decodeIfPresent(
                Bool.self,
                forKey: .enableNotifications
            ) ?? defaults.enableNotifications
            keepGlobalProtectOff = try container.decodeIfPresent(
                Bool.self,
                forKey: .keepGlobalProtectOff
            ) ?? defaults.keepGlobalProtectOff
            selectedSectionRaw = try container.decodeIfPresent(
                String.self,
                forKey: .selectedSectionRaw
            ) ?? defaults.selectedSectionRaw
            searchText = try container.decodeIfPresent(
                String.self,
                forKey: .searchText
            ) ?? defaults.searchText
            sortKeyRaw = try container.decodeIfPresent(
                String.self,
                forKey: .sortKeyRaw
            ) ?? defaults.sortKeyRaw
            // Added after 1.1.0. A payload without it sorts in its key's
            // default direction (see `normalized()`), and older builds ignore
            // the field and keep it when they save.
            sortDirectionRaw = try container.decodeIfPresent(
                String.self,
                forKey: .sortDirectionRaw
            ) ?? ""
            // Added after schema version 1 shipped: payloads without them keep
            // the defaults, and older builds ignore them.
            filterModeRaw = try container.decodeIfPresent(
                String.self,
                forKey: .filterModeRaw
            ) ?? defaults.filterModeRaw
            treeMode = try container.decodeIfPresent(
                Bool.self,
                forKey: .treeMode
            ) ?? defaults.treeMode
            // Added after 1.1.0: a payload without it shows the state, and
            // older builds ignore the field and keep it when they save.
            showsMenuBarStatus = try container.decodeIfPresent(
                Bool.self,
                forKey: .showsMenuBarStatus
            ) ?? defaults.showsMenuBarStatus
        }

        func normalized() -> CodableSettings {
            var value = self
            value.schemaVersion = Self.currentSchemaVersion
            value.refreshIntervalSeconds = min(60, max(2, refreshIntervalSeconds))
            let limits = SettingsStore.processListLimitRange
            value.processListLimit = processListLimit == SettingsStore.allProcessesLimit
                ? processListLimit
                : min(limits.upperBound, max(limits.lowerBound, processListLimit))
            value.cpuHighlightThreshold = min(100, max(1, cpuHighlightThreshold))
            value.memHighlightThresholdMB = min(
                SettingsStore.memoryThresholdRange.upperBound,
                max(SettingsStore.memoryThresholdRange.lowerBound, memHighlightThresholdMB)
            )
            if TaskScopeSection(rawValue: selectedSectionRaw) == nil {
                value.selectedSectionRaw = TaskScopeSection.processes.rawValue
            }
            if ProcessFilterMode(rawValue: filterModeRaw) == nil {
                value.filterModeRaw = ProcessFilterMode.all.rawValue
            }
            value.searchText = String(searchText.prefix(500))
            if ProcessSortKey(rawValue: sortKeyRaw) == nil {
                // A key this build does not know: its direction meant nothing
                // for the replacement key either.
                value.sortKeyRaw = ProcessSortKey.cpu.rawValue
                value.sortDirectionRaw = ""
            }
            if ProcessSortDirection(rawValue: value.sortDirectionRaw) == nil {
                value.sortDirectionRaw = (ProcessSortKey(rawValue: value.sortKeyRaw) ?? .cpu).defaultDirection.rawValue
            }
            return value
        }
    }

}
