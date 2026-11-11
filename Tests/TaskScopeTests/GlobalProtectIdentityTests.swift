import XCTest
@testable import TaskScope

/// The built-in GlobalProtect preset's named launch jobs and its single
/// built-in test (`isBuiltInGlobalProtect`).
@MainActor
final class GlobalProtectIdentityTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults(suiteName: "TaskScope.GlobalProtectIdentityTests.\(UUID().uuidString)")!
    }

    func testJobListsAreBuiltFromTheNamedJobs() {
        XCTAssertEqual(WatchedAppPreset.globalProtectInterfaceAgent.label, "com.paloaltonetworks.gp.pangpa")
        XCTAssertTrue(WatchedAppPreset.globalProtectInterfaceAgent.isRequired)
        XCTAssertEqual(WatchedAppPreset.globalProtectSessionAgent.label, "com.paloaltonetworks.gp.pangps")
        XCTAssertFalse(WatchedAppPreset.globalProtectSessionAgent.isRequired, "Older installations have no session agent")
        XCTAssertEqual(WatchedAppPreset.globalProtectSystemDaemon.label, "com.paloaltonetworks.gp.pangpsd")
        XCTAssertEqual(WatchedAppPreset.globalProtectSystemDaemon.processName, "PanGPS")

        XCTAssertEqual(
            WatchedAppPreset.globalProtectUserLaunchAgentJobs,
            [WatchedAppPreset.globalProtectInterfaceAgent, WatchedAppPreset.globalProtectSessionAgent]
        )
        XCTAssertEqual(WatchedAppPreset.legacyGlobalProtectUserLaunchAgentJobs, [WatchedAppPreset.globalProtectInterfaceAgent])
        XCTAssertEqual(WatchedAppPreset.globalProtectSystemLaunchDaemonJobs, [WatchedAppPreset.globalProtectSystemDaemon])
        XCTAssertEqual(WatchedAppPreset.globalProtect.userLaunchAgentJobs, WatchedAppPreset.globalProtectUserLaunchAgentJobs)
        XCTAssertEqual(WatchedAppPreset.globalProtect.systemLaunchDaemonJobs, WatchedAppPreset.globalProtectSystemLaunchDaemonJobs)
    }

    func testOnlyTheExactBuiltInPresetIsBuiltIn() {
        XCTAssertTrue(WatchedAppPreset.globalProtect.isBuiltInGlobalProtect)

        // The interface-only copy that non-disconnecting stops use.
        let interfaceOnly = WatchedAppPreset.globalProtect.globalProtectInterfaceOnly
        XCTAssertFalse(interfaceOnly.isBuiltInGlobalProtect)
        XCTAssertEqual(interfaceOnly.lifecycleUserLaunchAgentJobs, [WatchedAppPreset.globalProtectInterfaceAgent])
        XCTAssertEqual(interfaceOnly.lifecycleSystemLaunchDaemonJobs, [])

        // A previous build's payload is recognized only for migration.
        var legacy = WatchedAppPreset.globalProtect
        legacy.userLaunchAgentJobs = WatchedAppPreset.legacyGlobalProtectUserLaunchAgentJobs
        XCTAssertTrue(legacy.hasSupportedGlobalProtectIdentity)
        XCTAssertFalse(legacy.isBuiltInGlobalProtect)

        // The same fields under another identity, or another field changed.
        var lookalike = WatchedAppPreset.globalProtect
        lookalike.id = UUID()
        XCTAssertFalse(lookalike.isBuiltInGlobalProtect)
        XCTAssertEqual(lookalike.lifecycleSystemLaunchDaemonJobs, [], "Only the built-in preset may name the system daemon")
        var changedHelper = WatchedAppPreset.globalProtect
        changedHelper.helperProcessNames = ["Other"]
        XCTAssertFalse(changedHelper.isBuiltInGlobalProtect)

        // Notifications are a user preference, not part of the identity.
        var quiet = WatchedAppPreset.globalProtect
        quiet.notificationsEnabled = false
        XCTAssertTrue(quiet.isBuiltInGlobalProtect)
    }

    func testAStoredLegacyBuiltInPresetLoadsAsTheBuiltInPreset() throws {
        let defaults = makeDefaults()
        let key = "TaskScope.GlobalProtectIdentityTests.presets"
        var legacy = WatchedAppPreset.globalProtect
        legacy.userLaunchAgentJobs = WatchedAppPreset.legacyGlobalProtectUserLaunchAgentJobs
        defaults.set(try JSONEncoder().encode([legacy]), forKey: key)

        let store = WatchedAppsStore(userDefaults: defaults, key: key)

        XCTAssertEqual(store.presets.count, 1)
        XCTAssertTrue(store.presets[0].isBuiltInGlobalProtect)
        XCTAssertTrue(store.restoreBuiltInPreset(), "The migrated preset counts as present")
        XCTAssertEqual(store.presets.count, 1)
    }

    func testBuiltInKeepOffAsksWithTheGlobalProtectStopText() {
        let keepOff = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: .globalProtect, action: .keepOff))
        let quitAll = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: .globalProtect, action: .quitAll))
        XCTAssertEqual(keepOff, quitAll)
        XCTAssertTrue(keepOff.hasPrefix("TaskScope will disconnect the VPN, stop GlobalProtect and its services"))
        XCTAssertTrue(keepOff.hasSuffix(PresetStopScope.forceStopDisclosure))
    }

    func testCustomQuitTextsStillNameTheirAgentsAndTargets() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(label: "com.example.agent", plistPath: "/Users/me/Library/LaunchAgents/com.example.agent.plist")]
        )
        let quitApp = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: preset, action: .quitApp))
        XCTAssertEqual(
            quitApp,
            "TaskScope will unload the user launch agents (com.example.agent). It will then stop the currently running matches for: Example. "
                + PresetStopScope.forceStopDisclosure
        )
        let helpers = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: preset, action: .quitHelpers))
        XCTAssertEqual(
            helpers,
            "TaskScope will unload the helper launch agents (com.example.agent); an agent that is running the main Example process is left loaded. It will then stop the currently running matches for: Example Helper. "
                + PresetStopScope.forceStopDisclosure
        )
        var bare = preset
        bare.userLaunchAgentJobs = []
        let quitAll = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: bare, action: .quitAll))
        XCTAssertEqual(
            quitAll,
            "TaskScope will stop the currently running matches for: Example, Example Helper. " + PresetStopScope.forceStopDisclosure
        )
    }
}
