import XCTest
@testable import TaskScope

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testRequiresApprovalIsDistinctAndActionable() {
        let service = FakeLoginItemService(state: .requiresApproval)
        let manager = LoginItemManager(service: service)

        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(manager.state, .requiresApproval)
        XCTAssertTrue(manager.message?.contains("requires approval") == true)

        manager.openSystemSettings()
        XCTAssertEqual(service.openSettingsCount, 1)
    }

    func testObservedStateDrivesMessageAfterRegistration() {
        let service = FakeLoginItemService(state: .notRegistered)
        let manager = LoginItemManager(service: service)

        manager.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(manager.state, .enabled)
        XCTAssertEqual(manager.message, "Launch at Login is on.")
    }

    func testRefreshObservesApprovalGrantedInSystemSettings() {
        let service = FakeLoginItemService(state: .requiresApproval)
        let manager = LoginItemManager(service: service)

        service.state = .enabled
        manager.refresh()

        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(manager.message, "Launch at Login is on.")
    }

    /// A `.notFound` registration (bundle moved or replaced) can only be
    /// cleared by an unregister attempt; the thrown error must be surfaced.
    func testDisablingAnUnavailableRegistrationStillAttemptsUnregisterAndSurfacesTheError() {
        let service = FakeLoginItemService(state: .notFound)
        let manager = LoginItemManager(service: service)

        manager.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)

        let failing = FakeLoginItemService(state: .notFound)
        failing.unregisterError = LoginItemTestError.refused
        let failingManager = LoginItemManager(service: failing)

        failingManager.setEnabled(false)

        XCTAssertEqual(failing.unregisterCount, 1)
        XCTAssertTrue(failingManager.message?.contains("Could not update Launch at Login") == true)
        XCTAssertTrue(failingManager.message?.contains("The system refused the change.") == true)
    }

    /// The switch shows Off for these states, so turning it on must act:
    /// register an unavailable registration, or open approval settings.
    func testEnablingFromUnavailableOrPendingApprovalActs() {
        let unavailable = FakeLoginItemService(state: .notFound)
        LoginItemManager(service: unavailable).setEnabled(true)
        XCTAssertEqual(unavailable.registerCount, 1)

        let pending = FakeLoginItemService(state: .requiresApproval)
        LoginItemManager(service: pending).setEnabled(true)
        XCTAssertEqual(pending.registerCount, 0)
        XCTAssertEqual(pending.openSettingsCount, 1)
    }

    func testActivationRefreshUpdatesLoginAndNotificationState() async {
        var events: [String] = []

        await TaskScopeExternalStateRefresh.perform(
            refreshLoginItem: { events.append("login") },
            refreshNotificationAuthorization: { events.append("notifications") }
        )

        XCTAssertEqual(events, ["login", "notifications"])
    }
}

private enum LoginItemTestError: LocalizedError {
    case refused

    var errorDescription: String? {
        "The system refused the change."
    }
}

private final class FakeLoginItemService: LoginItemServicing {
    var state: LoginItemState
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(state: LoginItemState) {
        self.state = state
    }

    func register() throws {
        registerCount += 1
        state = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        state = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}
