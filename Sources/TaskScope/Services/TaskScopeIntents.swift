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
        let object = objectForKey(key)
        let presets: [WatchedAppPreset]
        if let data = object as? Data,
           let decoded = try? JSONDecoder().decode(PartiallyDecodedArray<WatchedAppPreset>.self, from: data) {
            presets = WatchedAppsStore.validatedPresets(decoded.elements).presets
        } else if object == nil {
            presets = [.globalProtect]
        } else {
            // Match WatchedAppsStore's corruption policy: do not silently replace
            // unreadable user data with a default automation target.
            presets = []
        }

        return presets.map(WatchedPresetEntity.init(preset:))
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await executeStop(bus: .shared) { message in
            let dialog = IntentDialog(stringLiteral: message)
            if #available(macOS 15.0, *) {
                try await requestConfirmation(dialog: dialog)
            } else if try await !$app.requestConfirmation(for: app, dialog: dialog) {
                throw CancellationError()
            }
        }
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "stop \(app.displayName)"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    @MainActor
    func executeStop(
        bus: AppCommandBus,
        confirmation: (String) async throws -> Void
    ) async throws -> TaskScopeCommandResult {
        try await TaskScopeIntentExecution.perform(.stopPresetEntity(app.commandTarget), bus: bus) {
            try await confirmation("Stop \(app.displayName) and its eligible watched processes? This may interrupt active work or connections.")
        }
    }
}

@available(macOS 13.0, *)
struct OpenWatchedAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Watched App"
    static let description = IntentDescription("Open a watched app using TaskScope's managed lifecycle.")

    @Parameter(title: "Watched App")
    var app: WatchedPresetEntity

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await TaskScopeIntentExecution.perform(.openPresetEntity(app.commandTarget), bus: .shared)
        let message = try TaskScopeIntentDialog.successMessage(
            for: result,
            action: "open \(app.displayName)"
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
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
    }
}
