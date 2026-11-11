import Security
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class Batch09InstallationHealthRecoveryTests: XCTestCase {
    // T05-11 (a): a recovery the current report did not offer is refused,
    // even when the destination has become available since.
    func testRecoveryRequiresThatTheCurrentReportOfferedIt() async {
        var performed: [InstallationHealthReport.Recovery] = []
        let controller = InstallationHealthController(
            collect: { _ in batch09Report(recoveries: [.systemSettings, .reviewPresets]) },
            availableRecoveries: { [.systemSettings, .reviewPresets, .revealApp] },
            performRecovery: { performed.append($0); return true },
            now: { batch09HealthDate }
        )
        controller.refresh(batch09HealthInput)
        for _ in 0..<100 where controller.isRefreshing { await Task.yield() }
        XCTAssertFalse(controller.isRefreshing)

        let revealed = await controller.recover(.revealApp)

        XCTAssertFalse(revealed)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertTrue(controller.actionMessage?.contains("no longer verified") == true)
    }

    func testRecoveryAvailabilityAndNavigationUseTheVerifiedDestinations() async {
        var opened: [URL] = []
        var revealed: [URL] = []
        let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        let app = URL(fileURLWithPath: "/Applications/TaskScope.app")
        var environment = InstallationHealthRecovery.Environment(
            systemSettingsURL: { settings }, runningAppURL: { app }, finderAvailable: { true },
            openApplication: { opened.append($0) }, revealInFinder: { revealed.append($0) }
        )

        XCTAssertEqual(InstallationHealthRecovery.available(in: environment), [.systemSettings, .revealApp, .reviewPresets])
        let openedSettings = await InstallationHealthRecovery.perform(.systemSettings, in: environment)
        let revealedApp = await InstallationHealthRecovery.perform(.revealApp, in: environment)
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(revealedApp)
        XCTAssertEqual(opened, [settings])
        XCTAssertEqual(revealed, [app])

        environment.finderAvailable = { false }
        environment.systemSettingsURL = { nil }
        XCTAssertEqual(InstallationHealthRecovery.available(in: environment), [.reviewPresets])
        let refusedSettings = await InstallationHealthRecovery.perform(.systemSettings, in: environment)
        let refusedReveal = await InstallationHealthRecovery.perform(.revealApp, in: environment)
        XCTAssertFalse(refusedSettings)
        XCTAssertFalse(refusedReveal)
        XCTAssertEqual(opened, [settings])
        XCTAssertEqual(revealed, [app])

        environment.systemSettingsURL = { settings }
        environment.openApplication = { _ in throw CocoaError(.fileNoSuchFile) }
        let failedOpen = await InstallationHealthRecovery.perform(.systemSettings, in: environment)
        XCTAssertFalse(failedOpen)
    }

    // A02-11 (3): the Support report's permission mapping.
    func testSupportPermissionsMapEveryAuthorizationAndLoginState() async {
        let notifications: [(NotificationService.AuthorizationState, SupportDiagnosticsReport.Permissions.Notification)] = [
            (.unknown, .unknown), (.notDetermined, .notRequested), (.denied, .denied),
            (.authorized, .allowed), (.provisional, .provisional)
        ]
        for (state, expected) in notifications {
            let permissions = await SupportDiagnosticsCollector.permissions(
                notificationsEnabled: true, authorization: { state },
                accessibility: { true }, loginState: { .enabled }
            )
            XCTAssertEqual(permissions.notifications, expected)
        }
        let logins: [(LoginItemState, SupportDiagnosticsReport.Permissions.LoginItem)] = [
            (.notRegistered, .off), (.enabled, .on), (.requiresApproval, .requiresApproval), (.notFound, .unavailable)
        ]
        for (state, expected) in logins {
            let permissions = await SupportDiagnosticsCollector.permissions(
                notificationsEnabled: nil, authorization: { .denied },
                accessibility: { false }, loginState: { state }
            )
            XCTAssertEqual(permissions.launchAtLogin, expected)
            XCTAssertNil(permissions.notificationsEnabledInApp)
            XCTAssertFalse(permissions.accessibilityGranted)
        }
    }

    // A02-11 (6): Copy JSON and Save JSON hand over exactly the previewed text.
    func testPreviewCopyAndSaveExportExactlyThePreview() throws {
        let preview = try SupportDiagnosticsPreview(report: Self.report())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Batch09Support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostics.json")
        var copied: [String] = []
        let sheet = SupportDiagnosticsPreviewSheet(
            preview: preview, onClose: {},
            copyText: { copied.append($0); return true },
            chooseDestination: { destination }
        )

        try sheet.inspect().find(button: "Copy JSON").tap()
        try sheet.inspect().find(button: "Save JSON…").tap()

        XCTAssertEqual(copied, [preview.text])
        XCTAssertEqual(try Data(contentsOf: destination), Data(preview.text.utf8))
    }

    func testCancelledSavePanelWritesNothing() throws {
        let preview = try SupportDiagnosticsPreview(report: Self.report())
        var asked = 0
        let sheet = SupportDiagnosticsPreviewSheet(
            preview: preview, onClose: {},
            copyText: { _ in XCTFail("Nothing may be copied"); return false },
            chooseDestination: { asked += 1; return nil }
        )
        try sheet.inspect().find(button: "Save JSON…").tap()
        XCTAssertEqual(asked, 1)
    }

    // A02-9: a selection whose preset was deleted is refused instead of
    // silently producing a report without any preset.
    func testDeletedPresetSelectionIsRefusedInsteadOfBuildingANoPresetReport() async throws {
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.Batch09.Support.\(UUID().uuidString)"))
        var collected = 0
        var previews = 0
        let manager = ProcessManager(
            processInventory: ScriptedInventory(processes: []), verificationInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler.forbidding("No process may be signalled"), lifecycle: FakeLifecycle(), settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        let view = SupportDiagnosticsView(
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            processManager: manager,
            collectPermissions: { _ in
                collected += 1
                return .init(notifications: .denied, notificationsEnabledInApp: false,
                             accessibilityGranted: false, launchAtLogin: .off)
            },
            makePreview: { report in
                previews += 1
                return try SupportDiagnosticsPreview(report: report)
            },
            selectedPresetID: UUID()
        )

        try view.inspect().find(button: "Preview Diagnostics").tap()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(collected, 0)
        XCTAssertEqual(previews, 0)
        XCTAssertEqual(SupportDiagnosticsView.removedPresetMessage, "The selected preset was removed. Choose a preset again.")
    }

    private static func report() -> SupportDiagnosticsReport {
        .init(
            version: "1.0.0", build: "3", macOS: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            capturedAt: batch09HealthDate,
            permissions: .init(notifications: .allowed, notificationsEnabledInApp: true,
                               accessibilityGranted: false, launchAtLogin: .off),
            selectedPreset: nil, recentLifecycleFailures: []
        )
    }
}

private let batch09HealthDate = Date(timeIntervalSince1970: 2_000)

private func batch09Report(
    recoveries: Set<InstallationHealthReport.Recovery>,
    paths: [HealthPathFinding] = []
) -> InstallationHealthReport {
    InstallationHealthAssessment.report(
        input: batch09HealthInput,
        permissions: .init(notificationsAvailable: true, notifications: .authorized,
                           accessibilityTrusted: true, loginItem: .enabled),
        bundle: .init(identity: .healthy, identityDetail: "Bundle evidence", signature: .signed, metadata: .healthy),
        paths: paths, recoveries: recoveries, checkedAt: batch09HealthDate
    )
}
