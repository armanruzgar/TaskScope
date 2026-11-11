import XCTest
@testable import TaskScope

@available(macOS 13.0, *)
final class TaskScopeIntentsTests: XCTestCase {
    func testShortcutsDoNotRequestForegroundActivation() {
        XCTAssertFalse(RefreshTaskScopeIntent.openAppWhenRun)
        XCTAssertFalse(OpenWatchedAppIntent.openAppWhenRun)
        XCTAssertFalse(StopWatchedAppIntent.openAppWhenRun)
        XCTAssertFalse(GetWatchedAppStatusIntent.openAppWhenRun)
    }

    @MainActor
    func testStopRequiresConfirmationBeforeSubmittingAndDeclineDoesNotStop() async throws {
        let bus = AppCommandBus()
        var events: [String] = []
        var commands: [TaskScopeCommand] = []
        bus.onIntentExecution = { events.append("intent") }
        bus.install { command in
            commands.append(command)
            events.append("stop")
            return .init(status: .completed, message: "Stopped Example.")
        }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(id: UUID(), displayName: "Example")
        let result = try await intent.executeStop(bus: bus) { message in
            XCTAssertTrue(message.contains("Example"))
            XCTAssertTrue(message.contains("eligible watched processes"))
            XCTAssertTrue(commands.isEmpty)
            events.append("confirm")
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(events, ["intent", "confirm", "stop"])
        XCTAssertEqual(commands, [.stopPresetEntity(intent.app.commandTarget)])

        do {
            _ = try await intent.executeStop(bus: bus) { _ in throw CancellationError() }
            XCTFail("Declined confirmation must throw")
        } catch is CancellationError {
            XCTAssertEqual(commands.count, 1)
        }
    }

    @MainActor
    func testColdIntentLaunchSuppressesPresentationBeforeConfirmation() async throws {
        let bus = AppCommandBus()
        var context = TaskScopeLaunchContext.interactive
        var phase = TaskScopeLaunchPhase.starting
        var hasInteractiveSignal = false
        bus.onIntentExecution = {
            context = TaskScopeLaunchContext.receivingAutomation(current: context, phase: phase,
                                                                  source: .intent, hasInteractiveSignal: hasInteractiveSignal)
        }
        bus.install { _ in .init(status: .completed, message: "done") }
        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus) {
            XCTAssertEqual(context, .urlAutomation)
            XCTAssertEqual(TaskScopeLaunchPresentation.resolve(context: context, isActive: false), .background)
            XCTAssertEqual(TaskScopeLaunchPresentation.resolve(context: context, isActive: true), .background)
        }
        // Intent execution in an already-running interactive app leaves it interactive.
        context = .interactive
        phase = .running
        hasInteractiveSignal = true
        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
        XCTAssertEqual(context, .interactive)
    }

    @MainActor
    func testIntentSignalIsRetainedUntilLaunchObserverIsInstalled() async throws {
        let bus = AppCommandBus()
        bus.install { _ in .init(status: .completed, message: "done") }
        _ = try await TaskScopeIntentExecution.perform(.refresh, bus: bus)
        var context = TaskScopeLaunchContext.pending
        bus.onIntentExecution = {
            context = TaskScopeLaunchContext.receivingAutomation(current: context, phase: .starting,
                                                                  source: .intent, hasInteractiveSignal: false)
        }
        XCTAssertEqual(context, .urlAutomation)
        context = TaskScopeLaunchContext.resolve(
            current: context,
            signal: TaskScopeLaunchSignal(arguments: ["TaskScope"], launchedAsLoginItem: false, receivedOpenURL: false),
            finalizeInteractiveLaunch: true
        )
        XCTAssertEqual(context, .urlAutomation)
    }

    func testEntityCommandTargetPreservesStableIdentifier() {
        let id = UUID()
        let entity = WatchedPresetEntity(id: id, displayName: "Example")

        XCTAssertEqual(
            entity.commandTarget,
            WatchedPresetCommandTarget(id: id, displayName: "Example")
        )
    }

    private let suiteName = "TaskScope.TaskScopeIntentsTests.\(UUID().uuidString)"
    private let key = "watched-presets-intent-tests"
    private var defaults: InMemoryUserDefaults!

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCatalogUsesDefaultPresetOnlyWhenNoPayloadExists() {
        let catalog = makeCatalog()
        XCTAssertEqual(catalog.entities().map(\.displayName), ["GlobalProtect"])

        for payload: Any in [Data([0xFE, 0xED]), "unreadable", ["unexpected": "dictionary"]] {
            defaults.set(payload, forKey: key)
            XCTAssertTrue(catalog.entities().isEmpty)
        }
    }

    @MainActor
    func testShortcutRefreshPublishesBootstrappedAddedAndRenamedPresets() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        let catalog = makeCatalog()
        var publishedNames: [[String]] = []
        let update = { publishedNames.append(catalog.entities().map(\.displayName)) }

        TaskScopeShortcuts.refreshParameters(for: .interactive, update: update)
        var added = preset(name: "Added")
        XCTAssertTrue(store.add(added))
        TaskScopeShortcuts.refreshParameters(for: .interactive, update: update)
        added.displayName = "Renamed"
        XCTAssertTrue(store.update(added))
        TaskScopeShortcuts.refreshParameters(for: .interactive, update: update)

        XCTAssertEqual(publishedNames, [
            ["GlobalProtect"], ["GlobalProtect", "Added"], ["GlobalProtect", "Renamed"]
        ])
    }

    func testShortcutRefreshSkipsStartupVerification() {
        var updates = 0
        TaskScopeShortcuts.refreshParameters(for: .startupVerification) { updates += 1 }
        XCTAssertEqual(updates, 0)
        for context in [TaskScopeLaunchContext.interactive, .loginItem, .automation, .urlAutomation] {
            TaskScopeShortcuts.refreshParameters(for: context) { updates += 1 }
        }
        XCTAssertEqual(updates, 4)
    }

    func testQueryResolvesStableIdentifiersAndSearchesNames() async throws {
        let alpha = preset(name: "Alpha")
        let beta = preset(name: "Beta Client")
        defaults.set(try JSONEncoder().encode([alpha, beta]), forKey: key)
        let query = WatchedPresetEntityQuery(
            catalog: makeCatalog()
        )

        let resolved = try await query.entities(for: [beta.id, UUID()])
        let searched = try await query.entities(matching: "client")
        let suggested = try await query.suggestedEntities()

        XCTAssertEqual(resolved.map(\.id), [beta.id])
        XCTAssertEqual(searched.map(\.id), [beta.id])
        XCTAssertEqual(suggested.map(\.id), [alpha.id, beta.id])
    }

    func testDialogPreservesSuccessAndLabelsRejectedAndFailedResults() {
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .completed, message: "Opened Alpha."),
                action: "open Alpha"
            ),
            "Opened Alpha."
        )
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .rejected, message: "No matching preset."),
                action: "open Alpha"
            ),
            "Couldn’t open Alpha: No matching preset."
        )
        XCTAssertEqual(
            TaskScopeIntentDialog.message(
                for: TaskScopeCommandResult(status: .failed, message: "Lifecycle incomplete."),
                action: "stop Alpha"
            ),
            "Failed to stop Alpha: Lifecycle incomplete."
        )
    }

    func testRejectedAndFailedCommandsThrowForShortcuts() throws {
        XCTAssertEqual(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .completed, message: "Opened Alpha."),
                action: "open Alpha"
            ),
            "Opened Alpha."
        )
        XCTAssertThrowsError(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .rejected, message: "No matching preset."),
                action: "open Alpha"
            )
        )
        XCTAssertThrowsError(
            try TaskScopeIntentDialog.successMessage(
                for: TaskScopeCommandResult(status: .failed, message: "Lifecycle incomplete."),
                action: "stop Alpha"
            )
        )
    }

    private func makeCatalog() -> WatchedPresetCatalog {
        let defaults = defaults!
        return WatchedPresetCatalog(key: key, objectForKey: defaults.objectReader)
    }

    private func preset(name: String) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: "\(name)Process",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app"
        )
    }
}
