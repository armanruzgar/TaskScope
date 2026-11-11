import Security
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// Batch 13 follow-up: one name for a custom preset's full stop (L12-2), a copy
/// action named for what it copies (L12-3), and the hardened runtime in Health.
@MainActor
final class Batch13FollowUpTests: XCTestCase {
    private let custom = WatchedAppPreset(
        displayName: "Work Browser", mainProcessName: "Browser", helperProcessNames: ["Renderer"],
        protectedProcessNames: ["BrowserDaemon"], appPath: "/Applications/Browser.app"
    )

    private func card(for preset: WatchedAppPreset) -> PresetCard {
        PresetCard(
            snapshot: .init(preset: preset, runningNames: []),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: false, isKeepOffControlEnabled: true, onKeepOffChanged: { _ in },
            onStopWithoutDisconnect: {}, isMutationActive: false
        )
    }

    // L12-2: the custom card, its confirmation, the dry run, and the results
    // share one name; GlobalProtect keeps its stronger Quit All.
    func testCustomFullStopHasOneNameOnEverySurface() throws {
        let customCard = try card(for: custom).inspect()
        XCTAssertNoThrow(try customCard.find(button: "Quit App and Helpers…"))
        XCTAssertThrowsError(try customCard.find(button: "Quit All Killable…"))
        let globalProtectCard = try card(for: .globalProtect).inspect()
        XCTAssertNoThrow(try globalProtectCard.find(button: "Quit All…"))
        XCTAssertThrowsError(try globalProtectCard.find(button: "Quit App and Helpers…"))

        let pending = ProcessConfirmationState.PendingPresetAction(preset: custom, action: .quitAll)
        XCTAssertEqual(pending.confirmTitle, "Quit App and Helpers")
        XCTAssertEqual(pending.title, "Quit Work Browser and Its Helpers?")
        let globalProtect = ProcessConfirmationState.PendingPresetAction(preset: .globalProtect, action: .quitAll)
        XCTAssertEqual(globalProtect.confirmTitle, "Quit All")
        XCTAssertEqual(globalProtect.title, "Quit All GlobalProtect Processes?")

        let operations = SettingsView.lifecycleDryRunOperations(for: custom)
        XCTAssertTrue(operations.contains { $0.hasPrefix("Quit App and Helpers: run the Quit App and Quit Helpers targets") })
        XCTAssertFalse(operations.contains { $0.contains("Close") }, "\(operations)")
        let globalProtectOperations = SettingsView.lifecycleDryRunOperations(for: .globalProtect)
        XCTAssertTrue(globalProtectOperations.contains { $0.hasPrefix("Shortcuts Stop: run the Quit App and Quit Helpers targets") })
        XCTAssertFalse(globalProtectOperations.contains { $0.contains("Quit App and Helpers") },
                       "GlobalProtect's card has no Quit App and Helpers button")

        XCTAssertEqual(PresetStopScope.all.incompleteMessage, "Quit App and Helpers did not complete.")
        XCTAssertEqual(PresetStopScope.all.diagnosticAction, .close, "the diagnostics value is report schema")
    }

    // L12-3: the row action copies the kernel executable path, so it says so,
    // in the context menu, the VoiceOver actions, and the welcome text. The
    // buttons are found, never tapped, so the real clipboard is untouched.
    func testCopyActionIsNamedForTheExecutablePathItCopies() async throws {
        let target = Batch10.process(500, name: "Example")
        let fixture = await Batch10.fixture(processes: [target])
        defer { fixture.stores.cleanup() }
        let view = Batch10.popover(fixture)

        let menu = try view.processContextMenu(for: target).inspect()
        XCTAssertNoThrow(try menu.find(button: "Copy Executable Path"))
        XCTAssertThrowsError(try menu.find(button: "Copy Command"))
        XCTAssertNoThrow(try view.processAccessibilityActions(for: target).inspect().find(button: "Copy Executable Path"))

        let onboarding = try OnboardingView(onComplete: {}).inspect()
        XCTAssertNoThrow(try onboarding.find(ViewType.Text.self, where: {
            try $0.string().contains("copy its executable path")
        }))
    }

    // Health reports the hardened runtime of an intact signature and claims
    // nothing when the signature or its flags could not be read. It does not
    // change the signing state.
    func testHealthSigningRowSaysWhetherTheHardenedRuntimeIsOn() {
        let runtime = SecCodeSignatureFlags.runtime.rawValue
        let adhoc = SecCodeSignatureFlags.adhoc.rawValue
        XCTAssertEqual(InstallationHealthProbe.hardenedRuntimeState(
            status: errSecSuccess, informationStatus: errSecSuccess, flags: runtime | adhoc), true)
        XCTAssertEqual(InstallationHealthProbe.hardenedRuntimeState(
            status: errSecSuccess, informationStatus: errSecSuccess, flags: adhoc), false)
        XCTAssertNil(InstallationHealthProbe.hardenedRuntimeState(
            status: errSecCSSignatureFailed, informationStatus: errSecSuccess, flags: runtime))
        XCTAssertNil(InstallationHealthProbe.hardenedRuntimeState(
            status: errSecSuccess, informationStatus: errSecSuccess, flags: nil))

        func signingRow(_ signature: HealthSignature, hardenedRuntime: Bool?) -> InstallationHealthReport.Finding {
            let report = InstallationHealthAssessment.report(
                input: InstallationHealthInput(presets: [], presetsReadable: true, notificationsEnabled: true),
                permissions: .init(notificationsAvailable: true, notifications: .authorized,
                                   accessibilityTrusted: true, loginItem: .enabled),
                bundle: .init(identity: .healthy, identityDetail: "Bundle evidence", signature: signature,
                              metadata: .healthy, hardenedRuntime: hardenedRuntime),
                paths: [], recoveries: Set(InstallationHealthReport.Recovery.allCases),
                checkedAt: Date(timeIntervalSince1970: 1_000)
            )
            return report.findings.first { $0.category == .signing }!
        }
        let on = signingRow(.signed, hardenedRuntime: true)
        XCTAssertEqual(on.state, .healthy)
        XCTAssertTrue(on.detail.hasSuffix(" The hardened runtime is on."), on.detail)
        let off = signingRow(.adHoc, hardenedRuntime: false)
        XCTAssertEqual(off.state, .unavailable, "the runtime flag does not change the ad-hoc verdict")
        XCTAssertTrue(off.detail.contains("The hardened runtime is off"), off.detail)
        XCTAssertFalse(signingRow(.signed, hardenedRuntime: nil).detail.contains("hardened runtime"))
        XCTAssertFalse(signingRow(.invalid, hardenedRuntime: true).detail.contains("hardened runtime"))
    }
}
