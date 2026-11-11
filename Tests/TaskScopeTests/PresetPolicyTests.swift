import XCTest
@testable import TaskScope

/// Preset policy that lives in the model: who may delete a preset, and which
/// launch agents an ordinary stop unloads.
@MainActor
final class PresetPolicyTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        InMemoryUserDefaults(suiteName: "TaskScope.PresetPolicyTests.\(UUID().uuidString)")!
    }

    private func customPreset(_ name: String = "Example") -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: name,
            mainProcessName: name,
            helperProcessNames: ["\(name) Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/\(name).app",
            userLaunchAgentJobs: [UserLaunchAgentJob(label: "com.example.\(name.lowercased())", plistPath: "/Users/Shared/com.example.\(name.lowercased()).plist")]
        )
    }

    // MARK: - Deletion

    func testStoreRefusesWhatItsDeletionPolicyRefuses() {
        let kept = customPreset("Kept")
        let free = customPreset("Free")
        let store = WatchedAppsStore(
            userDefaults: makeDefaults(),
            key: "presets",
            deletionPolicy: PresetDeletionPolicy { $0.id == kept.id ? "Kept is protected." : nil }
        )
        XCTAssertTrue(store.add(kept))
        XCTAssertTrue(store.add(free))

        XCTAssertEqual(store.deletionRefusal(for: kept), "Kept is protected.")
        XCTAssertFalse(store.remove(kept))
        XCTAssertEqual(store.validationError, "Kept is protected.")
        XCTAssertTrue(store.presets.contains { $0.id == kept.id })

        XCTAssertNil(store.deletionRefusal(for: free))
        XCTAssertTrue(store.remove(free))
        XCTAssertFalse(store.presets.contains { $0.id == free.id })
    }

    /// The audit's repro: with Keep Off on, deleting the built-in preset
    /// through the store itself (not through Settings) is refused, so the
    /// launchd override it left can still be cleared.
    func testAppStoresRefuseDeletingTheBuiltInPresetWhileKeepOffIsOnPendingOrUnknown() {
        let defaults = makeDefaults()
        let session = makeBatch02Session(.interactive, standardDefaults: { defaults })
        defer { session.cleanUp() }
        let stores = TaskScopeLaunchStores(session: session, inventory: Batch02FixedInventory(result: .success([])))
        XCTAssertEqual(stores.watchedApps.presets, [.globalProtect])

        stores.settings.keepGlobalProtectOff = true
        XCTAssertFalse(stores.watchedApps.remove(.globalProtect))
        XCTAssertEqual(stores.watchedApps.presets, [.globalProtect])
        XCTAssertEqual(
            stores.watchedApps.validationError,
            "Turn off Keep GlobalProtect Off (or choose Open) before deleting the built-in preset. Its user launch agents are disabled by a persistent launchd override that deleting the preset would not clear."
        )

        stores.settings.keepGlobalProtectOff = false
        stores.keepOffActivity.begin(WatchedAppPreset.globalProtectID)
        XCTAssertEqual(
            stores.watchedApps.deletionRefusal(for: .globalProtect),
            "Wait for the pending GlobalProtect Keep Off action to finish before deleting the built-in preset."
        )
        XCTAssertFalse(stores.watchedApps.remove(.globalProtect))
        stores.keepOffActivity.end(WatchedAppPreset.globalProtectID)

        XCTAssertNil(stores.watchedApps.deletionRefusal(for: .globalProtect))
        XCTAssertTrue(stores.watchedApps.remove(.globalProtect))
        XCTAssertTrue(stores.watchedApps.presets.isEmpty)
    }

    func testKeepOffRefusalNamesTheWayOut() {
        XCTAssertNil(PresetDeletionPolicy.keepOffRefusal(
            for: .globalProtect, isKeptOff: false, isSettingsReadOnly: false, isKeepOffPending: false
        ))
        XCTAssertTrue(PresetDeletionPolicy.keepOffRefusal(
            for: .globalProtect, isKeptOff: true, isSettingsReadOnly: false, isKeepOffPending: false
        )?.hasPrefix("Turn off Keep GlobalProtect Off") == true)
        XCTAssertTrue(PresetDeletionPolicy.keepOffRefusal(
            for: .globalProtect, isKeptOff: false, isSettingsReadOnly: false, isKeepOffPending: true
        )?.hasPrefix("Wait for the pending GlobalProtect Keep Off action") == true)
        // Unreadable settings hide the intent, which may still be on.
        XCTAssertTrue(PresetDeletionPolicy.keepOffRefusal(
            for: .globalProtect, isKeptOff: false, isSettingsReadOnly: true, isKeepOffPending: false
        )?.hasPrefix("Settings are unreadable") == true)
        XCTAssertNil(PresetDeletionPolicy.keepOffRefusal(
            for: customPreset(), isKeptOff: true, isSettingsReadOnly: true, isKeepOffPending: true
        ), "Only the built-in preset can be kept off here")
    }

    func testKeepOffActivityStaysPendingUntilTheLastOverlappingActionEnds() {
        let activity = KeepOffActivity()
        let id = UUID()
        activity.begin(id)
        activity.begin(id)
        activity.end(id)
        XCTAssertTrue(activity.isPending(id))
        activity.end(id)
        XCTAssertFalse(activity.isPending(id))
        XCTAssertTrue(activity.pendingPresetIDs.isEmpty)
        activity.end(id)
        XCTAssertFalse(activity.isPending(id), "An unmatched end leaves nothing pending")
        activity.begin(id)
        XCTAssertTrue(activity.isPending(id))
    }

    /// A preset copy that differs from the stored one is judged as stored.
    func testDeletionPolicyJudgesTheStoredPreset() {
        let stored = customPreset()
        var stale = stored
        stale.displayName = "Renamed elsewhere"
        let store = WatchedAppsStore(
            userDefaults: makeDefaults(),
            key: "presets",
            deletionPolicy: PresetDeletionPolicy { $0.displayName == "Example" ? "Stored copy refused." : nil }
        )
        XCTAssertTrue(store.add(stored))
        XCTAssertEqual(store.deletionRefusal(for: stale), "Stored copy refused.")
        XCTAssertFalse(store.remove(stale))
    }

    // MARK: - Stop scope agents

    func testOrdinaryStopsUnloadOnlyTheGlobalProtectInterfaceAgent() {
        XCTAssertEqual(
            WatchedAppPreset.globalProtect.stopScopeAgentPreset.lifecycleUserLaunchAgentJobs,
            [WatchedAppPreset.globalProtectInterfaceAgent]
        )
        XCTAssertEqual(PresetStopScope.closeAgentLabels(for: .globalProtect), ["com.paloaltonetworks.gp.pangpa"])
        let custom = customPreset()
        XCTAssertEqual(custom.stopScopeAgentPreset, custom)
        XCTAssertEqual(PresetStopScope.closeAgentLabels(for: custom), ["com.example.example"])
    }

    /// The confirmation and the dry run describe the agents the stop uses.
    func testDescriptionsNameTheAgentsTheStopUnloads() {
        for preset in [WatchedAppPreset.globalProtect, customPreset()] {
            let labels = preset.stopScopeAgentPreset.lifecycleUserLaunchAgentJobs.map(\.label).joined(separator: ", ")
            let dryRun = SettingsView.lifecycleDryRunOperations(for: preset)
            XCTAssertTrue(
                dryRun.contains { $0.contains("unload and verify the user launch agents (\(labels))") },
                "Dry run for \(preset.displayName): \(dryRun)"
            )
            let quitApp = TaskScopePopoverView.presetConfirmationMessage(for: .init(preset: preset, action: .quitApp))
            XCTAssertTrue(quitApp.contains("unload the user launch agents (\(labels))"), quitApp)
        }
        // The VPN session agent is never named for an ordinary stop.
        let gpDryRun = SettingsView.lifecycleDryRunOperations(for: .globalProtect).joined(separator: "\n")
        XCTAssertFalse(gpDryRun.contains("Quit App, Quit Helpers, or Shortcuts Stop: unload and verify the user launch agents (com.paloaltonetworks.gp.pangpa, com.paloaltonetworks.gp.pangps)"))
    }
}
