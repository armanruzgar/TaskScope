import UserNotifications
import XCTest
@testable import TaskScope

/// Notification delivery through the service's test seams: no request ever
/// reaches UNUserNotificationCenter.
@MainActor
final class Batch09NotificationDeliveryTests: XCTestCase {
    private let slack = WatchedAppPreset(
        displayName: "Slack", mainProcessName: "Slack",
        helperProcessNames: ["Slack Helper", "Slack Helper (GPU)", "Slack Helper (Renderer)"],
        protectedProcessNames: [], appPath: "/Applications/Slack.app"
    )
    private let zoom = WatchedAppPreset(
        displayName: "Zoom", mainProcessName: "zoom.us", helperProcessNames: [],
        protectedProcessNames: [], appPath: "/Applications/zoom.us.app"
    )

    private func service(
        _ state: NotificationService.AuthorizationState,
        isAvailable: Bool = true,
        delivered: @escaping (UNNotificationRequest) -> Void
    ) -> NotificationService {
        NotificationService(
            isAvailable: isAvailable, authorizationState: state,
            readAuthorization: { state }, deliver: { delivered($0) }
        )
    }

    // T04-14: the started/stopped mapping, the text and the request.
    func testAuthorizedServicePostsTheStartAndStopOfEachProcess() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        service.prime([WatchedAppSnapshot(preset: slack, runningNames: ["Slack Helper"])])

        service.diffAndNotify([WatchedAppSnapshot(preset: slack, runningNames: ["Slack"])])

        XCTAssertEqual(requests.map(\.content.title), ["Process Started", "Process Stopped"])
        XCTAssertEqual(requests.map(\.content.body), ["Slack is now running.", "Slack Helper is no longer running."])
        XCTAssertEqual(requests.map(\.identifier), [
            "TaskScope.watched.\(slack.id.uuidString).started",
            "TaskScope.watched.\(slack.id.uuidString).stopped"
        ])
        XCTAssertEqual(Set(requests.map(\.content.threadIdentifier)), ["TaskScope.watched.\(slack.id.uuidString)"])
        XCTAssertTrue(requests.allSatisfy { $0.trigger == nil })
    }

    func testProvisionalAuthorizationAlsoDelivers() {
        var requests: [UNNotificationRequest] = []
        let service = service(.provisional) { requests.append($0) }
        service.prime([WatchedAppSnapshot(preset: zoom, runningNames: [])])
        service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"])])
        XCTAssertEqual(requests.map(\.content.body), ["zoom.us is now running."])
    }

    func testUndeliverableOrUnavailableServicesPostNothing() {
        for (state, available) in [(NotificationService.AuthorizationState.denied, true), (.notDetermined, true),
                                   (.unknown, true), (.authorized, false)] {
            var requests: [UNNotificationRequest] = []
            let service = service(state, isAvailable: available) { requests.append($0) }
            service.prime([WatchedAppSnapshot(preset: zoom, runningNames: [])])
            service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"])])
            service.diffAndNotify([WatchedAppSnapshot(preset: zoom, runningNames: [])])
            XCTAssertTrue(requests.isEmpty, "\(state), available: \(available)")
        }
    }

    // A02-6: one request per preset and direction, not one per process name.
    func testAPresetWhoseProcessesAllStopProducesOneNotification() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        let everything: Set<String> = ["Slack", "Slack Helper", "Slack Helper (GPU)", "Slack Helper (Renderer)"]
        service.prime([WatchedAppSnapshot(preset: slack, runningNames: everything)])

        service.diffAndNotify([WatchedAppSnapshot(preset: slack, runningNames: [])])

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.content.title, "Processes Stopped")
        XCTAssertEqual(
            requests.first?.content.body,
            "Slack, Slack Helper, Slack Helper (GPU), and Slack Helper (Renderer) are no longer running."
        )
    }

    func testPresetsAreAnnouncedSeparatelyAndDisabledPresetsNotAtAll() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        var muted = zoom
        muted.id = UUID()
        muted.notificationsEnabled = false
        service.prime([
            WatchedAppSnapshot(preset: slack, runningNames: []),
            WatchedAppSnapshot(preset: zoom, runningNames: ["zoom.us"]),
            WatchedAppSnapshot(preset: muted, runningNames: [])
        ])

        service.diffAndNotify([
            WatchedAppSnapshot(preset: slack, runningNames: ["Slack", "Slack Helper"]),
            WatchedAppSnapshot(preset: zoom, runningNames: []),
            WatchedAppSnapshot(preset: muted, runningNames: ["zoom.us"])
        ])

        XCTAssertEqual(requests.map(\.content.body), [
            "Slack and Slack Helper are now running.",
            "zoom.us is no longer running."
        ])
        XCTAssertEqual(requests.map(\.content.threadIdentifier), [
            "TaskScope.watched.\(slack.id.uuidString)", "TaskScope.watched.\(zoom.id.uuidString)"
        ])
    }

    // A02-6 with batch 7's A09-5: presets that share a process name are
    // diffed apart, and the shared name is shown with the preset's name.
    func testPresetsSharingAProcessNameAreAnnouncedApart() {
        var requests: [UNNotificationRequest] = []
        let service = service(.authorized) { requests.append($0) }
        let downloader = WatchedAppPreset(
            displayName: "JDownloader2", mainProcessName: "JavaApplicationStub", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/JDownloader2.app"
        )
        let rocket = WatchedAppPreset(
            displayName: "OpenRocket", mainProcessName: "JavaApplicationStub", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Applications/OpenRocket.app"
        )
        service.prime([
            WatchedAppSnapshot(preset: downloader, runningNames: ["JavaApplicationStub"]),
            WatchedAppSnapshot(preset: rocket, runningNames: ["JavaApplicationStub"])
        ])

        service.diffAndNotify([
            WatchedAppSnapshot(preset: downloader, runningNames: []),
            WatchedAppSnapshot(preset: rocket, runningNames: ["JavaApplicationStub"])
        ])

        XCTAssertEqual(requests.map(\.content.body), ["JDownloader2: JavaApplicationStub is no longer running."])
        XCTAssertEqual(requests.map(\.identifier), ["TaskScope.watched.\(downloader.id.uuidString).stopped"])
    }

    // A02-7: an authorization granted in System Settings is picked up before
    // the next diff instead of only at the next app activation.
    func testUndeliverableStateIsReReadAndADeliverableOneIsNot() async {
        var reads = 0
        var current = NotificationService.AuthorizationState.denied
        let service = NotificationService(
            isAvailable: true, authorizationState: .denied,
            readAuthorization: { reads += 1; return current }, deliver: { _ in }
        )

        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(service.authorizationState, .denied)

        current = .authorized
        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(service.authorizationState, .authorized)
        await service.refreshAuthorizationIfUndeliverable()
        XCTAssertEqual(reads, 2, "nothing is read while delivery is possible")
    }
}
