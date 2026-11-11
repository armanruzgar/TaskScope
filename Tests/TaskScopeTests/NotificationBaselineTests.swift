import XCTest
import UserNotifications
@testable import TaskScope

final class NotificationBaselineTests: XCTestCase {
    func testFirstObservationAndDisabledDeliveryOnlyRebaseline() {
        var baseline = ProcessNotificationBaseline()

        let first = baseline.transitions(to: ["Example"], canNotify: true)
        let disabled = baseline.transitions(to: ["Other"], canNotify: false)
        let enabledAgain = baseline.transitions(to: ["Other"], canNotify: true)

        XCTAssertTrue(first.started.isEmpty)
        XCTAssertTrue(first.stopped.isEmpty)
        XCTAssertTrue(disabled.started.isEmpty)
        XCTAssertTrue(disabled.stopped.isEmpty)
        XCTAssertTrue(enabledAgain.started.isEmpty)
        XCTAssertTrue(enabledAgain.stopped.isEmpty)
    }

    func testPreferenceChangeCanRebaselineWithoutFalseTransition() {
        var baseline = ProcessNotificationBaseline()
        baseline.rebaseline(["Allowed"])

        baseline.rebaseline(["DifferentEligibleSet"])
        let transition = baseline.transitions(to: ["DifferentEligibleSet"], canNotify: true)

        XCTAssertTrue(transition.started.isEmpty)
        XCTAssertTrue(transition.stopped.isEmpty)
    }

    func testPhysicalTransitionsAreDiffedAfterBaseline() {
        var baseline = ProcessNotificationBaseline()
        baseline.rebaseline(["Old", "Shared"])

        let transition = baseline.transitions(to: ["New", "Shared"], canNotify: true)

        XCTAssertEqual(transition.started, ["New"])
        XCTAssertEqual(transition.stopped, ["Old"])
    }

    @MainActor
    func testAuthorizationMappingAndDeliveryEligibilityAreExplicit() {
        XCTAssertEqual(
            NotificationService.authorizationState(for: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(NotificationService.authorizationState(for: .denied), .denied)
        XCTAssertEqual(NotificationService.authorizationState(for: .authorized), .authorized)
        XCTAssertEqual(NotificationService.authorizationState(for: .provisional), .provisional)
        XCTAssertTrue(NotificationService.canDeliver(for: .authorized))
        XCTAssertTrue(NotificationService.canDeliver(for: .provisional))
        XCTAssertFalse(NotificationService.canDeliver(for: .denied))
        XCTAssertFalse(NotificationService.canDeliver(for: .notDetermined))
    }

    /// `swift test` runs unbundled. `UNUserNotificationCenter` aborts the
    /// process in that situation, so every center-touching method must be a
    /// no-op when the service is unavailable.
    @MainActor
    func testUnbundledServiceIsUnavailableAndNeverTouchesTheNotificationCenter() async {
        let service = NotificationService.shared

        XCTAssertFalse(service.isAvailable)
        await service.requestAuthorization()
        await service.refreshAuthorizationStatus()
        let preset = WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example", helperProcessNames: ["Other"],
            protectedProcessNames: [], appPath: "/Applications/Example.app"
        )
        service.prime([WatchedAppSnapshot(preset: preset, runningNames: ["Example"])])
        service.diffAndNotify([WatchedAppSnapshot(preset: preset, runningNames: ["Example", "Other"])])
        await service.refreshAuthorizationIfUndeliverable()

        XCTAssertEqual(service.authorizationState, .unknown)
    }

    func testForegroundPresentationUsesBannerWithoutSound() {
        let options = NotificationService.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        // Without .list a notification that arrives while TaskScope is
        // frontmost is shown once and not kept in Notification Center.
        XCTAssertTrue(options.contains(.list))
        XCTAssertFalse(options.contains(.sound))
    }

    @MainActor
    func testEnablementPrimesBeforeDeliveryAndRejectsStaleCompletion() {
        let coordinator = NotificationEnablementCoordinator()
        var deliveryEnabled = true
        var events: [String] = []

        let staleToken = coordinator.beginConfiguration(
            setDeliveryEnabled: {
                deliveryEnabled = $0
                events.append("delivery:\($0)")
            }
        )
        _ = coordinator.beginConfiguration(
            setDeliveryEnabled: { deliveryEnabled = $0 }
        )

        XCTAssertFalse(
            coordinator.completeEnabledConfiguration(
                token: staleToken,
                currentBaseline: { ["Stale"] },
                primeBaseline: { _ in events.append("stale-prime") },
                setDeliveryEnabled: { deliveryEnabled = $0 }
            )
        )
        XCTAssertFalse(deliveryEnabled)
        XCTAssertFalse(events.contains("stale-prime"))

        let currentToken = coordinator.beginConfiguration(
            setDeliveryEnabled: {
                deliveryEnabled = $0
                events.append("delivery:\($0)")
            }
        )
        XCTAssertTrue(
            coordinator.completeEnabledConfiguration(
                token: currentToken,
                currentBaseline: { ["Current"] },
                primeBaseline: { (names: Set<String>) in events.append("prime:\(names.sorted())") },
                setDeliveryEnabled: {
                    deliveryEnabled = $0
                    events.append("delivery:\($0)")
                }
            )
        )

        XCTAssertTrue(deliveryEnabled)
        XCTAssertEqual(Array(events.suffix(3)), [
            "delivery:false",
            "prime:[\"Current\"]",
            "delivery:true"
        ])
    }
}
