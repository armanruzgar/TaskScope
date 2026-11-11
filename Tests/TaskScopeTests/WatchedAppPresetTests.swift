import XCTest
@testable import TaskScope

final class WatchedAppPresetTests: XCTestCase {
    @MainActor
    func testWhitespaceDisplayNameFallsBackToMainProcess() throws {
        let form = WatchedPresetFormState()
        form.mainProcess = "Example"
        form.displayName = " \n\t "
        form.appPath = "/Applications/Example.app"
        let preset = try form.makePreset(existing: nil).get()
        XCTAssertEqual(preset.displayName, "Example")
        let suite = "TaskScope.FormTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchedAppsStore(userDefaults: defaults, key: "presets")
        XCTAssertTrue(store.add(preset))
        form.displayName = "  Display Name \n"
        XCTAssertEqual(try form.makePreset(existing: nil).get().displayName, "Display Name")
    }

    func testDecodingOlderPresetDefaultsNewFields() throws {
        let json = """
        {
          "displayName": "Example",
          "mainProcessName": "ExampleApp",
          "appPath": "/Applications/Example.app"
        }
        """.data(using: .utf8)!

        let preset = try JSONDecoder().decode(WatchedAppPreset.self, from: json)

        XCTAssertEqual(preset.displayName, "Example")
        XCTAssertEqual(preset.mainProcessName, "ExampleApp")
        XCTAssertEqual(preset.helperProcessNames, [])
        XCTAssertEqual(preset.protectedProcessNames, [])
        XCTAssertEqual(preset.userLaunchAgentJobs, [])
        XCTAssertEqual(preset.systemLaunchDaemonJobs, [])
        XCTAssertTrue(preset.notificationsEnabled)
    }

    func testSnapshotAggregateStatusPrioritizesMainAppOverHelpers() {
        let preset = WatchedAppPreset.globalProtect

        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: ["PanGPA"])].aggregateStatus,
            .helpersOnly
        )
        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: ["GlobalProtect", "PanGPA"])].aggregateStatus,
            .watchedRunning
        )
        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: [])].aggregateStatus,
            .idle
        )
        XCTAssertEqual(
            [WatchedAppSnapshot(preset: preset, runningNames: ["PanGPS"])].aggregateStatus,
            .protectedOnly
        )
    }

    /// The editor exposes only labels and paths. Saving an unrelated change must
    /// keep an optional agent optional rather than resetting it to required.
    @MainActor
    func testEditingAPresetKeepsEachAgentsRequiredFlag() throws {
        let optional = UserLaunchAgentJob(
            label: "com.example.optional",
            plistPath: "/Library/LaunchAgents/com.example.optional.plist",
            isRequired: false
        )
        let required = UserLaunchAgentJob(
            label: "com.example.required",
            plistPath: "/Library/LaunchAgents/com.example.required.plist"
        )
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [optional, required]
        )
        let form = WatchedPresetFormState()
        form.prepareForEditing(preset)
        form.displayName = "Renamed"

        let edited = try form.makePreset(existing: preset).get()

        XCTAssertEqual(edited.displayName, "Renamed")
        XCTAssertEqual(edited.userLaunchAgentJobs, [optional, required])
    }
}
