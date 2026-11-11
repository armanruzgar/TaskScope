import Security
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

private let healthDate = Date(timeIntervalSince1970: 1_000)
private let healthInput = InstallationHealthInput(presets: [], presetsReadable: true, notificationsEnabled: true)

private func healthReport(
    notifications: NotificationService.AuthorizationState = .authorized,
    available: Bool = true, accessibility: Bool = true, login: LoginItemState = .enabled,
    signature: HealthSignature = .signed, identity: InstallationHealthReport.State = .healthy,
    metadata: InstallationHealthReport.State = .healthy,
    paths: [HealthPathFinding] = [], input: InstallationHealthInput = healthInput,
    recoveries: Set<InstallationHealthReport.Recovery> = Set(InstallationHealthReport.Recovery.allCases),
    date: Date = healthDate
) -> InstallationHealthReport {
    InstallationHealthAssessment.report(
        input: input,
        permissions: .init(notificationsAvailable: available, notifications: notifications,
                           accessibilityTrusted: accessibility, loginItem: login),
        bundle: .init(identity: identity, identityDetail: "Bundle evidence", signature: signature, metadata: metadata),
        paths: paths, recoveries: recoveries, checkedAt: date
    )
}

private extension InstallationHealthReport {
    subscript(_ category: Category) -> Finding { findings.first { $0.category == category }! }
}

final class InstallationHealthTests: XCTestCase {
    func testEveryCategoryIsPresentWithoutClaimingShortcutsExecution() {
        let report = healthReport()
        XCTAssertEqual(Set(report.findings.map(\.category)), Set(InstallationHealthReport.Category.allCases))
        XCTAssertEqual(report[.signing].state, .healthy)
        XCTAssertEqual(report[.appIntents].state, .unverified)
        XCTAssertTrue(report[.appIntents].detail.contains("no action was run"))
        XCTAssertTrue(report[.signing].detail.contains("notarization"))
    }

    func testNotificationsDistinguishDenialNotRequestedUnavailableAndUnknown() {
        let cases: [(NotificationService.AuthorizationState, InstallationHealthReport.State)] = [
            (.authorized, .healthy), (.provisional, .healthy), (.denied, .denied),
            (.notDetermined, .notRequested), (.unknown, .unverified)
        ]
        for (authorization, expected) in cases {
            XCTAssertEqual(healthReport(notifications: authorization)[.notifications].state, expected)
        }
        XCTAssertEqual(healthReport(notifications: .unknown, available: false)[.notifications].state, .unavailable)
        let disabled = InstallationHealthInput(presets: [], presetsReadable: true, notificationsEnabled: false)
        XCTAssertEqual(healthReport(input: disabled)[.notifications].state, .healthy)
        XCTAssertTrue(healthReport(input: disabled)[.notifications].detail.contains("toggle is off"))
    }

    func testAccessibilityFalseDoesNotInventDenialOrTriggerPrompt() {
        let finding = healthReport(accessibility: false)[.accessibility]
        XCTAssertEqual(finding.state, .unverified)
        XCTAssertTrue(finding.detail.contains("not granted"))
        XCTAssertTrue(finding.detail.contains("does not distinguish denial"))
        XCTAssertEqual(finding.recovery, .systemSettings)
    }

    func testLoginNotFoundDoesNotInventStaleRegistration() {
        for (value, expected) in [(LoginItemState.notRegistered, InstallationHealthReport.State.off),
                                  (.enabled, .healthy), (.requiresApproval, .requiresApproval), (.notFound, .unavailable)] {
            XCTAssertEqual(healthReport(login: value)[.loginItem].state, expected)
        }
        XCTAssertTrue(healthReport(login: .notFound)[.loginItem].detail.contains("does not prove a stale registration"))
    }

    func testKnownSigningBlockersAndMissingMetadataDoNotReportReady() {
        for signature in [HealthSignature.adHoc, .unsigned, .invalid] {
            XCTAssertEqual(healthReport(signature: signature)[.signing].state, .unavailable)
            XCTAssertEqual(healthReport(signature: signature)[.appIntents].state, .unavailable)
        }
        XCTAssertEqual(healthReport(signature: .unverified)[.signing].state, .unverified)
        XCTAssertEqual(healthReport(metadata: .unavailable)[.appIntents].state, .unavailable)
        XCTAssertEqual(healthReport(metadata: .unverified)[.appIntents].state, .unverified)
    }

    func testSignatureProbeRequiresSuccessfulValidationAndReadableFlags() {
        func state(_ status: OSStatus, _ flags: UInt32? = 0, _ copied: OSStatus = errSecSuccess) -> HealthSignature {
            InstallationHealthProbe.signatureState(status: status, informationStatus: copied, flags: flags)
        }
        XCTAssertEqual(state(errSecSuccess), .signed)
        XCTAssertEqual(state(errSecSuccess, SecCodeSignatureFlags.adhoc.rawValue), .adHoc)
        XCTAssertEqual(state(errSecSuccess, nil), .unverified)
        XCTAssertEqual(state(errSecSuccess, 0, errSecCSInternalError), .unverified)
        XCTAssertEqual(state(errSecCSUnsigned), .unsigned)
        XCTAssertEqual(state(errSecCSBadResource), .invalid)
        XCTAssertEqual(state(errSecCSInternalError), .unverified)
    }

    func testAppReplacementInvalidatesPermissionContinuityAndIntents() {
        let report = healthReport(identity: .stale)
        for category in [InstallationHealthReport.Category.notifications, .accessibility, .loginItem, .appIntents, .bundleIdentity] {
            XCTAssertEqual(report[category].state, .stale)
        }
        XCTAssertTrue(report[.notifications].detail.contains("replacement is unverified"))
    }

    func testFreshnessClockReversalAndInvalidationRemoveRecoveryControls() {
        let report = healthReport()
        XCTAssertTrue(report.isFresh(at: healthDate.addingTimeInterval(59)))
        for date in [healthDate.addingTimeInterval(-1), healthDate.addingTimeInterval(60)] {
            XCTAssertFalse(report.isFresh(at: date))
            let findings = report.displayedFindings(at: date, invalidated: false)
            XCTAssertTrue(findings.allSatisfy { $0.state == .stale && $0.recovery == nil })
        }
        XCTAssertTrue(report.displayedFindings(at: healthDate, invalidated: true).allSatisfy { $0.state == .stale })
        XCTAssertTrue(healthReport(recoveries: []).findings.allSatisfy { $0.recovery == nil })
    }

    func testUnreadablePresetStoreNeverVerifiesFallbackPaths() {
        let input = InstallationHealthInput(presets: [.globalProtect], presetsReadable: false, notificationsEnabled: nil)
        let report = healthReport(input: input)
        XCTAssertEqual(report[.presetPaths].state, .unverified)
        XCTAssertTrue(report[.presetPaths].detail.contains("fallback entries"))
        XCTAssertTrue(report[.notifications].detail.contains("preference is unreadable"))
    }

    func testIdentityAcceptsCustomIdentifierAndDistinguishesReplacementFromReadFailure() {
        let info: [String: Any] = ["CFBundleIdentifier": "org.example.TaskScope",
                                   "CFBundleExecutable": "TaskScope", "CFBundlePackageType": "APPL"]
        func state(_ running: String?, _ signed: String?, _ status: OSStatus) -> InstallationHealthReport.State {
            InstallationHealthProbe.identityState(info: info, runningIdentifier: running,
                                                   signingIdentifier: signed, dynamicStatus: status)
        }
        XCTAssertEqual(state("org.example.TaskScope", "org.example.TaskScope", errSecSuccess), .healthy)
        XCTAssertEqual(state("com.local.TaskScope", "org.example.TaskScope", errSecSuccess), .stale)
        XCTAssertEqual(state("org.example.TaskScope", "org.example.TaskScope", errSecCSStaticCodeChanged), .stale)
        XCTAssertEqual(state("org.example.TaskScope", nil, errSecCSUnsigned), .unverified)
        XCTAssertEqual(state(nil, "org.example.TaskScope", errSecSuccess), .unverified)
        XCTAssertEqual(state("org.example.TaskScope", "org.example.TaskScope", errSecCSInternalError), .unverified)
        XCTAssertFalse(InstallationHealthProbe.validBundleIdentifier("private/path"))
    }

    func testMetadataRequiresKnownVersionAllActionsQueriesAndPhrases() throws {
        // The expected names and phrases come from script/expected_intents.json.
        let (version, valid) = try XCTUnwrap(ExpectedAppIntents.current).extractedMetadata()
        var actions = valid
        XCTAssertTrue(InstallationHealthProbe.validMetadata(version: version, actions: actions))
        XCTAssertFalse(InstallationHealthProbe.validMetadata(version: ["version": "4.0"], actions: actions))
        actions.removeValue(forKey: "queries")
        XCTAssertFalse(InstallationHealthProbe.validMetadata(version: version, actions: actions))
        actions = valid
        actions["autoShortcuts"] = [[String: Any]]()
        XCTAssertFalse(InstallationHealthProbe.validMetadata(version: version, actions: actions))
    }

    func testRealPathProbesDistinguishRequiredOptionalMalformedAndRepairedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Example.app")
        let executable = app.appendingPathComponent("Contents/MacOS/Example")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Example", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let job = directory.appendingPathComponent("agent.plist")
        var preset = WatchedAppPreset(displayName: "Private name", mainProcessName: "Example",
                                     helperProcessNames: [], protectedProcessNames: [], appPath: app.path,
                                     userLaunchAgentJobs: [.init(label: "private.label", plistPath: job.path)])
        var results = InstallationHealthProbe.inspectPaths([preset])
        XCTAssertEqual(results.map(\.state), [.healthy, .stale])
        preset.userLaunchAgentJobs[0].isRequired = false
        results = InstallationHealthProbe.inspectPaths([preset])
        XCTAssertEqual(results.map(\.state), [.healthy, .healthy])
        XCTAssertTrue(results[1].detail.contains("optional"))
        try Data("not a plist".utf8).write(to: job)
        XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset])[1].state, .unverified)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "wrong"], format: .binary, options: 0).write(to: job)
        XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset])[1].state, .unverified)
        try PropertyListSerialization.data(fromPropertyList: ["Label": "private.label"], format: .binary, options: 0).write(to: job)
        results = InstallationHealthProbe.inspectPaths([preset])
        XCTAssertTrue(results.allSatisfy { $0.state == .healthy })
        XCTAssertFalse(results.map(\.detail).joined().contains(directory.path))
        XCTAssertFalse(results.map(\.detail).joined().contains("private.label"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: job.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: job.path) }
        XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset])[1].state, .unavailable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: job.path)
        XCTAssertThrowsError(try InstallationHealthProbe.readDictionary(job, limit: 1))
        XCTAssertThrowsError(try InstallationHealthProbe.readDictionary(directory))
        try FileManager.default.removeItem(at: executable)
        XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset])[0].state, .stale)
    }

    func testUnbundledProbeDoesNotClaimPermissionOrInstallationReadiness() async {
        let runtime = InstallationHealthRuntime(
            permissions: {
                .init(notificationsAvailable: false, notifications: .unknown,
                      accessibilityTrusted: false, loginItem: .notFound)
            },
            bundle: { InstallationHealthProbe.inspectBundle() },
            paths: { presets in XCTAssertTrue(presets.isEmpty); return [] },
            recoveries: { [] }
        )
        let report = await runtime.collect(healthInput)
        XCTAssertEqual(report[.bundleIdentity].state, .unavailable)
        XCTAssertEqual(report[.notifications].state, .unavailable)
        XCTAssertEqual(report[.loginItem].state, .unavailable)
        XCTAssertEqual(report[.appIntents].state, .unavailable)
        XCTAssertNil(report[.bundleIdentity].recovery)
    }
}

@MainActor
final class InstallationHealthControllerTests: XCTestCase {
    func testPermissionRevocationAndRecoveryRequireFreshEvidence() async {
        var current = healthReport()
        var opened: [InstallationHealthReport.Recovery] = []
        let controller = InstallationHealthController(collect: { _ in current },
            availableRecoveries: { [.systemSettings] }, performRecovery: { opened.append($0); return true }, now: { healthDate })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        XCTAssertEqual(controller.report?[.notifications].state, .healthy)
        controller.invalidate()
        let staleAttempt = await controller.recover(.systemSettings)
        XCTAssertFalse(staleAttempt)
        current = healthReport(notifications: .denied, accessibility: false, login: .requiresApproval)
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        XCTAssertEqual(controller.report?[.notifications].state, .denied)
        XCTAssertEqual(controller.report?[.accessibility].state, .unverified)
        let openedSettings = await controller.recover(.systemSettings)
        XCTAssertTrue(openedSettings)
        XCTAssertEqual(opened, [.systemSettings])
        XCTAssertTrue(controller.invalidated)
        XCTAssertEqual(controller.report?[.notifications].state, .denied)
    }

    func testRecoveryRechecksDestinationAndReportsOpenFailureWithoutAssumingRepair() async {
        var available: Set<InstallationHealthReport.Recovery> = [.systemSettings]
        var attempts = 0
        let controller = InstallationHealthController(collect: { _ in healthReport() },
            availableRecoveries: { available }, performRecovery: { _ in attempts += 1; return false }, now: { healthDate })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        available = []
        let missing = await controller.recover(.systemSettings)
        XCTAssertFalse(missing)
        XCTAssertEqual(attempts, 0)
        available = [.systemSettings]
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        let failed = await controller.recover(.systemSettings)
        XCTAssertFalse(failed)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(controller.actionMessage?.contains("could not be opened") == true)
    }

    func testExpiredEvidenceCannotOpenRecoveryEvenBeforeViewRendersAgain() async {
        var date = healthDate
        var attempts = 0
        let controller = InstallationHealthController(collect: { _ in healthReport() },
            availableRecoveries: { [.systemSettings] }, performRecovery: { _ in attempts += 1; return true }, now: { date })
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        date = healthDate.addingTimeInterval(61)
        let result = await controller.recover(.systemSettings)
        XCTAssertFalse(result)
        XCTAssertEqual(attempts, 0)
    }

    func testLateCollectionCannotOverwriteNewerAppReplacementResult() async {
        var first: CheckedContinuation<InstallationHealthReport, Never>?
        var calls = 0
        let controller = InstallationHealthController(collect: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { first = $0 } }
            return healthReport(identity: .stale)
        }, availableRecoveries: { [] }, performRecovery: { _ in XCTFail("Unexpected action"); return false }, now: { healthDate })
        controller.refresh(healthInput)
        for _ in 0..<100 where first == nil { await Task.yield() }
        XCTAssertNotNil(first)
        controller.refresh(healthInput)
        await waitForRefresh(controller)
        first?.resume(returning: healthReport())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.report?[.bundleIdentity].state, .stale)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testRowDisplaysStateAndOnlyOfferedRecovery() throws {
        var selected: InstallationHealthReport.Recovery?
        let row = InstallationHealthRow(finding: healthReport(notifications: .denied)[.notifications]) { selected = $0 }
        XCTAssertNoThrow(try row.inspect().find(text: "Denied"))
        try row.inspect().find(button: "Open System Settings").tap()
        XCTAssertEqual(selected, .systemSettings)
        let stale = healthReport().displayedFindings(at: healthDate.addingTimeInterval(61), invalidated: false)[0]
        let staleRow = InstallationHealthRow(finding: stale) { _ in XCTFail("Stale action") }
        XCTAssertTrue(try staleRow.inspect().findAll(ViewType.Button.self).isEmpty)
        XCTAssertNoThrow(try staleRow.inspect().find(text: "Stale"))
    }

    private func waitForRefresh(_ controller: InstallationHealthController) async {
        for _ in 0..<100 where controller.isRefreshing { await Task.yield() }
        XCTAssertFalse(controller.isRefreshing)
    }
}
