import XCTest
@testable import TaskScope

final class LaunchContextTests: XCTestCase {
    func testLoginAndAutomationLaunchesAreBackground() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope"],
                    launchedAsLoginItem: true,
                    receivedOpenURL: false
                )
            ),
            .loginItem
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope", "--automation"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: false
                )
            ),
            .automation
        )
    }

    func testNormalLaunchIsInteractive() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: false
                )
            ),
            .interactive
        )
    }

    func testStartupVerificationIsIsolatedFromRuntimeAndCommands() {
        let context = TaskScopeLaunchContext.detect(
            TaskScopeLaunchSignal(
                arguments: ["TaskScope", "--verify-startup"],
                launchedAsLoginItem: false,
                receivedOpenURL: false
            )
        )

        XCTAssertEqual(context, .startupVerification)
        XCTAssertTrue(context.suppressesAutomaticWindowPresentation)
        XCTAssertFalse(context.allowsExplicitCommands)
        XCTAssertFalse(context.performsRuntimeBootstrap)
    }

    func testColdURLLaunchIsBackgroundButStillAcceptsItsExplicitCommand() {
        let context = TaskScopeLaunchContext.detect(
            TaskScopeLaunchSignal(
                arguments: ["TaskScope"],
                launchedAsLoginItem: false,
                receivedOpenURL: true
            )
        )

        XCTAssertEqual(context, .urlAutomation)
        XCTAssertTrue(context.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(context.allowsExplicitCommands)
    }

    func testInteractiveLaunchAloneAllowsAutomaticWindowPresentation() {
        XCTAssertFalse(TaskScopeLaunchContext.interactive.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.loginItem.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.automation.suppressesAutomaticWindowPresentation)
        XCTAssertTrue(TaskScopeLaunchContext.urlAutomation.suppressesAutomaticWindowPresentation)
    }

    func testBackgroundArgumentsTakePriorityOverURLSignal() {
        XCTAssertEqual(
            TaskScopeLaunchContext.detect(
                TaskScopeLaunchSignal(
                    arguments: ["TaskScope", "--background"],
                    launchedAsLoginItem: false,
                    receivedOpenURL: true
                )
            ),
            .automation
        )
    }

    func testLaunchResolutionWaitsUntilFinalCallbackBeforePromotingInteractiveLaunch() {
        let interactiveSignal = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: false
        )

        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: .pending,
                signal: interactiveSignal,
                finalizeInteractiveLaunch: false
            ),
            .pending
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: .pending,
                signal: interactiveSignal,
                finalizeInteractiveLaunch: true
            ),
            .interactive
        )
    }

    func testLaunchResolutionNeverPromotesURLContextWhenEventIsNoLongerCurrent() {
        let urlSignal = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: true
        )
        let noCurrentEvent = TaskScopeLaunchSignal(
            arguments: ["TaskScope"],
            launchedAsLoginItem: false,
            receivedOpenURL: false
        )
        let detectedURL = TaskScopeLaunchContext.resolve(
            current: .pending,
            signal: urlSignal,
            finalizeInteractiveLaunch: false
        )

        XCTAssertEqual(detectedURL, .urlAutomation)
        XCTAssertEqual(
            TaskScopeLaunchContext.resolve(
                current: detectedURL,
                signal: noCurrentEvent,
                finalizeInteractiveLaunch: true
            ),
            .urlAutomation
        )
    }

    /// An interactive launch that is not yet active when the cold-open grace
    /// period ends keeps its interactive intent and presents on the next
    /// activation; it is never demoted to an accessory app.
    func testInactiveInteractiveLaunchPresentsOnNextActivationWithoutDemotion() {
        XCTAssertEqual(
            TaskScopeLaunchPresentation.resolve(context: .interactive, isActive: false),
            .presentOnNextActivation
        )
        XCTAssertEqual(
            TaskScopeLaunchPresentation.resolve(context: .interactive, isActive: true),
            .presentNow
        )
        for context in [TaskScopeLaunchContext.pending, .urlAutomation, .automation, .loginItem, .startupVerification] {
            for active in [false, true] {
                XCTAssertEqual(TaskScopeLaunchPresentation.resolve(context: context, isActive: active), .background)
            }
        }
    }

    func testIncomingURLOnlyConvertsStartupLaunchToBackground() {
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .interactive,
                phase: .starting, source: .url, hasInteractiveSignal: true
            ),
            .urlAutomation
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .interactive,
                phase: .running, source: .url, hasInteractiveSignal: true
            ),
            .interactive
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .loginItem,
                phase: .running, source: .url, hasInteractiveSignal: true
            ),
            .loginItem
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .startupVerification,
                phase: .starting, source: .url, hasInteractiveSignal: true
            ),
            .startupVerification
        )
    }

    /// A01-1: an intent or entity query demotes only a launch nobody activated,
    /// also while the launch is still starting.
    func testIntentOrQueryDemotesOnlyALaunchWithoutInteractiveSignal() {
        for phase in [TaskScopeLaunchPhase.starting, .running] {
            XCTAssertEqual(
                TaskScopeLaunchContext.receivingAutomation(
                    current: .interactive, phase: phase, source: .intent, hasInteractiveSignal: true
                ),
                .interactive,
                "An activated or reopened launch stays interactive"
            )
            XCTAssertEqual(
                TaskScopeLaunchContext.receivingAutomation(
                    current: .interactive, phase: phase, source: .intent, hasInteractiveSignal: false
                ),
                .urlAutomation,
                "A launch nobody activated is treated as an automation launch"
            )
        }
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .pending, phase: .starting, source: .intent, hasInteractiveSignal: false
            ),
            .urlAutomation
        )
        XCTAssertEqual(
            TaskScopeLaunchContext.receivingAutomation(
                current: .loginItem, phase: .running, source: .intent, hasInteractiveSignal: false
            ),
            .loginItem
        )
    }
}

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
