import Foundation
import XCTest
@testable import TaskScope

// Regression tests for audit batch 7: watched-app presets, saved selections,
// settings and persistence recovery. Every test keeps its settings in its own
// in-memory defaults domain and its files in a temporary directory.

// MARK: - Preset editor

@MainActor
final class Batch07PresetEditorTests: XCTestCase {
    private let optionalAgent = UserLaunchAgentJob(
        label: "com.example.tool.agent",
        plistPath: "/Library/LaunchAgents/com.example.tool.agent.plist",
        isRequired: false
    )

    // A09-7
    func testEditingAnOptionalAgentsLabelOrPathKeepsItOptional() throws {
        var existing = batch07Preset(name: "Tool", main: "Tool")
        existing.userLaunchAgentJobs = [optionalAgent]
        let form = WatchedPresetFormState()
        func requirements(labels: String? = nil, paths: String? = nil) throws -> [Bool] {
            form.prepareForEditing(existing)
            if let labels { form.agentLabels = labels }
            if let paths { form.agentPlistPaths = paths }
            return try form.makePreset(existing: existing).get().userLaunchAgentJobs.map(\.isRequired)
        }

        XCTAssertEqual(try requirements(labels: "com.example.tool.helper"), [false])
        XCTAssertEqual(try requirements(paths: "/Users/Shared/LaunchAgents/com.example.tool.agent.plist"), [false])
        XCTAssertEqual(try requirements(paths: "/Library/LaunchAgents/./com.example.tool.agent.plist"), [false])
        XCTAssertEqual(
            try requirements(
                labels: "com.example.tool.agent, com.example.other",
                paths: "/Library/LaunchAgents/com.example.tool.agent.plist, /Library/LaunchAgents/com.example.other.plist"
            ),
            [false, true],
            "an agent added in the editor is required, as before"
        )
    }

    // T04-12 (1), A09-10
    func testEditingAPresetKeepsItsNotificationSwitch() throws {
        var existing = batch07Preset(name: "Tool", main: "Tool")
        existing.notificationsEnabled = false
        let form = WatchedPresetFormState()
        form.prepareForEditing(existing)
        form.displayName = "Tool Renamed"
        let edited = try form.makePreset(existing: existing).get()
        XCTAssertEqual(edited.displayName, "Tool Renamed")
        XCTAssertFalse(edited.notificationsEnabled)
        existing.notificationsEnabled = true
        form.prepareForEditing(existing)
        XCTAssertTrue(try form.makePreset(existing: existing).get().notificationsEnabled)
    }
}
