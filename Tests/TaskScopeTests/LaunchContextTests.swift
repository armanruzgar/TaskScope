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
