import XCTest
import ViewInspector
@testable import TaskScope

/// L15-12: the popover and Settings take the process-wide services they use,
/// so a test gives them its own and nothing reaches the shared ones: no command
/// lands on `AppCommandBus.shared`, Quit cannot end the test run, and Settings
/// never touches the real hotkey registration or notification center.
@MainActor
final class ViewDependencyInjectionTests: XCTestCase {
    func testPopoverQuitCallsTheInjectedActionAndLeavesTheTestRunning() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let views = ViewTestDependencies()
        let popover = Batch10.popover(fixture, quitAction: views.quitAction)

        try quitButton(in: popover).tap()

        XCTAssertEqual(views.quitRequests, 1)
    }

    func testPresetsRefreshGoesToTheInjectedBus() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        fixture.stores.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        let views = ViewTestDependencies()
        views.recordCommands()

        Batch10.popover(fixture, commandBus: views.commandBus).viewCommands.refresh()

        let delivered = await Batch10.waitUntil { !views.receivedCommands.isEmpty }
        XCTAssertTrue(delivered, "Refresh never reached the view's own bus")
        XCTAssertEqual(views.receivedCommands, [.refresh])
    }

    func testSettingsShowsTheInjectedNotificationPermission() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }

        let denied = settings(fixture, notificationService: .forTests(state: .denied))
        XCTAssertNoThrow(try denied.inspect().find(button: "Open Notification Settings"))
        XCTAssertNoThrow(try denied.inspect().find(text: NotificationService.AuthorizationState.denied.label))

        let allowed = settings(fixture, notificationService: .forTests(state: .authorized))
        XCTAssertThrowsError(try allowed.inspect().find(button: "Open Notification Settings"))
        XCTAssertNoThrow(try allowed.inspect().find(text: NotificationService.AuthorizationState.authorized.label))
    }

    func testSettingsHotkeySwitchChangesOnlyTheInjectedManager() async throws {
        let fixture = await Batch10.fixture(processes: [])
        defer { fixture.stores.cleanup() }
        let defaults = InMemoryUserDefaults(suiteName: "TaskScope.ViewDependencyInjectionTests.\(UUID().uuidString)")!
        let backend = RecordingHotkeyBackend()
        let hotkey = HotkeyManager(defaults: defaults, backend: backend)
        XCTAssertTrue(hotkey.hotkeyEnabled, "precondition: the default hotkey is on")

        let view = settings(fixture, hotkey: hotkey, tab: .hotkey)
        try view.inspect().find(ViewType.Toggle.self, where: {
            (try? $0.labelView().text().string()) == "Enable global Show TaskScope hotkey"
        }).tap()

        XCTAssertFalse(hotkey.hotkeyEnabled)
        let saved = try XCTUnwrap(defaults.dictionary(forKey: "TaskScope.hotkey.v1"), "The switch saved nothing")
        XCTAssertEqual(saved["enabled"] as? Bool, false)
        XCTAssertFalse(backend.events.contains { $0.hasPrefix("register:") }, "Turning the hotkey off registers nothing")
    }

    // MARK: Helpers

    private func quitButton(in popover: TaskScopePopoverView) throws -> InspectableView<ViewType.Button> {
        try popover.inspect().find(TaskScopeFooterView.self).find(ViewType.Button.self, where: {
            (try? $0.accessibilityLabel().string()) == "Quit TaskScope"
        })
    }

    private func settings(
        _ fixture: UIFixture,
        hotkey: HotkeyManager = .forTests(),
        notificationService: NotificationService = .forTests(),
        tab: SettingsView.Tab = .general
    ) -> SettingsView {
        SettingsView(
            settings: fixture.stores.settings,
            watchedApps: fixture.stores.watchedApps,
            autoStopRules: fixture.stores.autoStopRules,
            processManager: fixture.manager,
            hotkey: hotkey,
            notificationService: notificationService,
            selectedTab: tab
        )
    }
}
