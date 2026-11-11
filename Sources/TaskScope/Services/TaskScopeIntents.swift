import AppIntents
import Foundation

@available(macOS 13.0, *)
struct WatchedPresetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Watched App")
    static let defaultQuery = WatchedPresetEntityQuery()

    let id: UUID
    let displayName: String

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(preset: WatchedAppPreset) {
        self.init(id: preset.id, displayName: preset.displayName)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    var commandTarget: WatchedPresetCommandTarget {
        WatchedPresetCommandTarget(id: id, displayName: displayName)
    }
}

struct WatchedPresetCatalog: Sendable {
    private let objectForKey: @Sendable (String) -> Any?
    private let key: String

    init(
        suiteName: String? = nil,
        key: String = WatchedAppsStore.defaultPersistenceKey
    ) {
        objectForKey = { key in
            let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            return defaults.object(forKey: key)
        }
        self.key = key
    }

    /// Reads the stored presets through `objectForKey`, for tests that keep
    /// their settings in memory.
    init(key: String, objectForKey: @escaping @Sendable (String) -> Any?) {
        self.key = key
        self.objectForKey = objectForKey
    }

    func entities() -> [WatchedPresetEntity] {
        presets().filter { !$0.hasUnknownFields }.map(WatchedPresetEntity.init(preset:))
    }

    func preset(id: UUID) -> WatchedAppPreset? {
        presets().first { $0.id == id }
    }

    private func presets() -> [WatchedAppPreset] {
        let object = objectForKey(key)
        if let data = object as? Data,
           let decoded = try? JSONDecoder().decode(PartiallyDecodedArray<WatchedAppPreset>.self, from: data) {
            return WatchedAppsStore.validatedPresets(decoded.elements).presets
        } else if object == nil {
            return [.globalProtect]
        } else {
            // Match WatchedAppsStore's corruption policy: do not silently replace
            // unreadable user data with a default automation target.
            return []
        }
    }
}

@available(macOS 13.0, *)
struct WatchedPresetEntityQuery: EntityStringQuery {
    private let catalog: WatchedPresetCatalog
    private let prepareForIntent: @MainActor @Sendable () -> Void

    init() {
        catalog = WatchedPresetCatalog()
        prepareForIntent = { AppCommandBus.shared.prepareForIntentExecution() }
    }

    init(
        catalog: WatchedPresetCatalog,
        prepareForIntent: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.catalog = catalog
        self.prepareForIntent = prepareForIntent
    }

    func entities(for identifiers: [WatchedPresetEntity.ID]) async throws -> [WatchedPresetEntity] {
        await prepareForIntent()
        let requested = Set(identifiers)
        return catalog.entities().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [WatchedPresetEntity] {
        await prepareForIntent()
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return catalog.entities() }
        return catalog.entities().filter {
            $0.displayName.localizedCaseInsensitiveContains(normalized)
        }
    }

    func suggestedEntities() async throws -> [WatchedPresetEntity] {
        await prepareForIntent()
        return catalog.entities()
    }
}

/// Whether TaskScope could verify a watched app's status, as Shortcuts offers it.
@available(macOS 13.0, *)
enum WatchedStatusAvailabilityAppEnum: String, AppEnum {
    case current
    case stale
    case unknown

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Status Availability")
    static let caseDisplayRepresentations: [WatchedStatusAvailabilityAppEnum: DisplayRepresentation] = [
        .current: "Current",
        .stale: "Stale",
        .unknown: "Unknown"
    ]

    init(_ availability: WatchedStatusAvailability) {
        switch availability {
        case .current: self = .current
        case .stale: self = .stale
        case .unknown: self = .unknown
        }
    }
}

/// The value Get Watched App Status, Open Watched App and Stop Watched App
/// return. It is a read-only report: nothing in Shortcuts can change TaskScope
/// through it.
@available(macOS 13.0, *)
struct WatchedAppStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Watched App Status")

    @Property(title: "Watched App")
    var watchedApp: String

    @Property(title: "Status Availability")
    var availability: WatchedStatusAvailabilityAppEnum

    /// Empty while the status is unknown.
    @Property(title: "Main App Running")
    var isMainAppRunning: Bool?

    /// Empty while the status is unknown.
    @Property(title: "Helpers Running")
    var runningHelperCount: Int?

    @Property(title: "Keep Off")
    var isKeptOff: Bool

    init() {
        watchedApp = ""
        availability = .unknown
        isMainAppRunning = nil
        runningHelperCount = nil
        isKeptOff = false
    }

    init(_ summary: WatchedAppStatusSummary) {
        self.init()
        watchedApp = summary.presetName
        availability = WatchedStatusAvailabilityAppEnum(summary.availability)
        isMainAppRunning = summary.isMainAppRunning
        runningHelperCount = summary.runningHelperCount
        isKeptOff = summary.isKeptOff
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(watchedApp)", subtitle: "\(subtitle)")
    }

    private var subtitle: String {
        guard availability != .unknown, let isMainAppRunning, let runningHelperCount else {
            return "Status unknown"
        }
        var parts = [isMainAppRunning ? "Running" : "Not running"]
        parts.append(runningHelperCount == 1 ? "1 helper" : "\(runningHelperCount) helpers")
        if isKeptOff { parts.append("Keep Off") }
        if availability == .stale { parts.append("stale") }
        return parts.joined(separator: " · ")
    }
}

@available(macOS 13.0, *)
enum TaskScopeIntentDialog {
    enum CommandError: LocalizedError {
        case rejected(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message), .failed(let message):
                message
            }
        }
    }

    static func message(
        for result: TaskScopeCommandResult,
        action: String
    ) -> String {
        switch result.status {
        case .completed:
            return result.message
        case .rejected:
            return "Couldn’t \(action): \(result.message)"
        case .failed:
            return "Failed to \(action): \(result.message)"
        }
    }

    static func successMessage(
        for result: TaskScopeCommandResult,
        action: String
    ) throws -> String {
        switch result.status {
        case .completed:
            return result.message
        case .rejected:
            throw CommandError.rejected("Couldn’t \(action): \(result.message)")
        case .failed:
            throw CommandError.failed("Failed to \(action): \(result.message)")
        }
    }

    /// The status value and dialog of a completed command. A rejected or
    /// failed command throws, as before. A completed one that carries no
    /// status, which TaskScope's own commands always attach, still completed:
    /// its value says the status is unknown rather than failing the shortcut.
    static func statusResult(
        for result: TaskScopeCommandResult,
        action: String,
        presetName: String
    ) throws -> (value: WatchedAppStatusEntity, message: String) {
        let message = try successMessage(for: result, action: action)
        let summary = result.watchedStatus ?? WatchedAppStatusSummary(
            presetName: presetName, availability: .unknown,
            isMainAppRunning: nil, runningHelperCount: nil, isKeptOff: false
        )
        return (WatchedAppStatusEntity(summary), message)
    }
}

@MainActor
enum TaskScopeIntentExecution {
    static func perform(
        _ command: TaskScopeCommand,
        bus: AppCommandBus,
        confirmation: () async throws -> Void = {}
    ) async throws -> TaskScopeCommandResult {
        bus.prepareForIntentExecution()
        try await confirmation()
        try Task.checkCancellation()
        return await bus.submit(command)
    }
}

@available(macOS 13.0, *)
struct StopWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Watched App"
    static let description = IntentDescription("Stop a watched app using TaskScope's managed lifecycle.")

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    /// The bus `perform()` submits to; tests replace it and restore it.
    @MainActor static var commandBus = AppCommandBus.shared
    /// The system confirmation `perform()` requests before stopping anything. It
    /// throws when the user declines. Tests replace it and restore it.
    @MainActor static var requestStopConfirmation: @MainActor (StopWatchedAppIntent, String) async throws -> Void = {
        intent, message in
        let dialog = IntentDialog(stringLiteral: message)
        if #available(macOS 15.0, *) {
            try await intent.requestConfirmation(dialog: dialog)
        } else {
            try requireConfirmed(await intent.$app.requestConfirmation(for: intent.app, dialog: dialog))
        }
    }

    /// A declined macOS 14 confirmation returns false; treat it as cancellation.
    static func requireConfirmed(_ confirmed: Bool) throws {
        guard confirmed else { throw CancellationError() }
    }

    @MainActor
    private static func confirmStop(_ intent: StopWatchedAppIntent, _ message: String) async throws {
        try await requestStopConfirmation(intent, message)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<WatchedAppStatusEntity> & ProvidesDialog {
        let result = try await executeStop(bus: Self.commandBus) { message in
            try await Self.confirmStop(self, message)
        }
        let status = try TaskScopeIntentDialog.statusResult(
            for: result, action: "stop \(app.displayName)", presetName: app.displayName
        )
        return .result(value: status.value, dialog: IntentDialog(stringLiteral: status.message))
    }

    @MainActor
    func executeStop(
        bus: AppCommandBus,
        catalog: WatchedPresetCatalog = WatchedPresetCatalog(),
        confirmation: (String) async throws -> Void
    ) async throws -> TaskScopeCommandResult {
        try await TaskScopeIntentExecution.perform(.stopPresetEntity(app.commandTarget), bus: bus) {
            try await confirmation(Self.stopConfirmationMessage(for: app, preset: catalog.preset(id: app.id)))
        }
    }

    /// Discloses what the stop does, as the in-app Close confirmation does: the
    /// launch agents unloaded first and the force stop after the graceful window.
    static func stopConfirmationMessage(for app: WatchedPresetEntity, preset: WatchedAppPreset?) -> String {
        var sentences = ["Stop \(app.displayName) and its eligible watched processes?"]
        let agents = preset.map(PresetStopScope.closeAgentLabels(for:)) ?? []
        if !agents.isEmpty {
            sentences.append("TaskScope will first unload its user launch agents (\(agents.joined(separator: ", "))).")
        }
        sentences.append(PresetStopScope.forceStopDisclosure)
        sentences.append("This may interrupt active work or connections.")
        return sentences.joined(separator: " ")
    }
}

@available(macOS 13.0, *)
struct OpenWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Watched App"
    static let description = IntentDescription("Open a watched app using TaskScope's managed lifecycle.")

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    /// The bus `perform()` submits to; tests replace it and restore it.
    @MainActor static var commandBus = AppCommandBus.shared

    func perform() async throws -> some IntentResult & ReturnsValue<WatchedAppStatusEntity> & ProvidesDialog {
        let result = try await TaskScopeIntentExecution.perform(.openPresetEntity(app.commandTarget), bus: Self.commandBus)
        let status = try TaskScopeIntentDialog.statusResult(
            for: result, action: "open \(app.displayName)", presetName: app.displayName
        )
        return .result(value: status.value, dialog: IntentDialog(stringLiteral: status.message))
    }
}

/// Read-only: refreshes watched status and returns one watched app's state.
/// Keep Off and every privileged operation stay out of App Intents.
@available(macOS 13.0, *)
struct GetWatchedAppStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Watched App Status"
    static let description = IntentDescription(
        "Report whether a watched app and its helpers are running, whether Keep Off is on, and whether TaskScope could verify that status. It changes nothing."
    )

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    /// The bus `perform()` submits to; tests replace it and restore it.
    @MainActor static var commandBus = AppCommandBus.shared

    func perform() async throws -> some IntentResult & ReturnsValue<WatchedAppStatusEntity> & ProvidesDialog {
        let result = try await executeStatus(bus: Self.commandBus)
        let status = try TaskScopeIntentDialog.statusResult(
            for: result, action: "get the status of \(app.displayName)", presetName: app.displayName
        )
        return .result(value: status.value, dialog: IntentDialog(stringLiteral: status.message))
    }

    @MainActor
    func executeStatus(bus: AppCommandBus) async throws -> TaskScopeCommandResult {
        try await TaskScopeIntentExecution.perform(.statusPresetEntity(app.commandTarget), bus: bus)
    }
}

@available(macOS 13.0, *)
struct RefreshTaskScopeIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh TaskScope"
    static let description = IntentDescription("Request TaskScope to refresh its watched status.")

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await TaskScopeIntentExecution.perform(.refresh, bus: .shared)
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "refresh TaskScope"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(macOS 13.0, *)
struct TaskScopeShortcuts: AppShortcutsProvider {
    static func refreshParameters(
        for launchContext: TaskScopeLaunchContext,
        update: () -> Void = { TaskScopeShortcuts.updateAppShortcutParameters() }
    ) {
        guard launchContext.performsRuntimeBootstrap else { return }
        update()
    }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshTaskScopeIntent(),
            phrases: ["Refresh \(.applicationName)"],
            shortTitle: "Refresh",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: StopWatchedAppIntent(),
            phrases: ["Stop \(\.$app) in \(.applicationName)"],
            shortTitle: "Stop Watched App",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: OpenWatchedAppIntent(),
            phrases: ["Open \(\.$app) in \(.applicationName)"],
            shortTitle: "Open Watched App",
            systemImageName: "arrow.up.forward.app"
        )
        AppShortcut(
            intent: GetWatchedAppStatusIntent(),
            phrases: ["Get \(\.$app) status in \(.applicationName)"],
            shortTitle: "Watched App Status",
            systemImageName: "info.circle"
        )
    }
}
