import AppKit
import XCTest
@testable import TaskScope

/// L15-6: the menu-bar confirmation's button order and answer mapping are pure
/// functions, and the alert is built from them.
@MainActor
final class MenuBarConfirmationTests: XCTestCase {
    private let request = MenuBarConfirmationRequest(
        title: "Stop Example?", message: "Sends SIGTERM.", confirmTitle: "Stop", cancelTitle: "Keep Running"
    )

    func testTheConfirmationComesFirstIsDestructiveAndNotOnReturn() {
        XCTAssertEqual(AppModalMenuBarConfirmation.alertButtons(for: request), [
            .init(title: "Stop", keyEquivalent: "", isDestructive: true),
            .init(title: "Keep Running", keyEquivalent: "\u{1b}", isDestructive: false)
        ])
    }

    func testOnlyTheFirstButtonConsents() {
        XCTAssertTrue(AppModalMenuBarConfirmation.consents(.alertFirstButtonReturn))
        for response in [NSApplication.ModalResponse.alertSecondButtonReturn, .alertThirdButtonReturn,
                         .cancel, .stop, .abort, .continue, .OK] {
            XCTAssertFalse(AppModalMenuBarConfirmation.consents(response), "\(response.rawValue) must not consent")
        }
    }

    func testTheAlertIsBuiltFromTheButtonList() {
        let alert = AppModalMenuBarConfirmation.makeAlert(request)
        let built = alert.buttons.map {
            AppModalMenuBarConfirmation.AlertButton(title: $0.title, keyEquivalent: $0.keyEquivalent, isDestructive: $0.hasDestructiveAction)
        }
        XCTAssertEqual(built, AppModalMenuBarConfirmation.alertButtons(for: request))
        XCTAssertEqual(alert.alertStyle, .warning)
        XCTAssertEqual(alert.messageText, request.title)
        XCTAssertEqual(alert.informativeText, request.message)
    }

    func testConfirmAnswersWithTheMappingOfTheButtonChosen() async {
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn, .stop] {
            let presenter = AppModalMenuBarConfirmation(runAlert: { _ in response })
            let confirmed = await presenter.confirm(request)
            XCTAssertEqual(confirmed, AppModalMenuBarConfirmation.consents(response))
        }
    }
}
