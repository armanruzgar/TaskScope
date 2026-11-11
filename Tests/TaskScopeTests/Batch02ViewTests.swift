import AppKit
import OSLog
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the URL scheme, accessibility labels, the
// Keep Off card in settings recovery, scene titles, persisted list options,
// the registry of running shell commands, and the action log.

// MARK: - URL scheme (A01-15, T05-3)

// MARK: - Views and scenes (L09-15, A11-2, L07-11, L11-15)

@MainActor
final class Batch02ViewTests: XCTestCase {
    /// L09-15: VoiceOver names the status item TaskScope, and the decorative
    /// header symbol is hidden next to the "TaskScope" text.
    func testStatusItemIsNamedTaskScopeAndTheHeaderSymbolIsHidden() throws {
        let label = try TaskScopeStatusItemLabel().inspect().find(ViewType.Label.self)
        XCTAssertEqual(try label.accessibilityLabel().string(), "TaskScope")

        let header = TaskScopeHeaderView(
            status: .idle, samples: [], samplingState: .paused,
            showsMetrics: false, showsOpenWindowButton: false, openFullWindow: nil, refreshAction: {}
        )
        let symbol = try header.inspect().find(ViewType.Image.self) {
            (try? $0.actualImage().name()) == "waveform.path.ecg"
        }
        XCTAssertTrue(try symbol.accessibilityHidden())
        XCTAssertNoThrow(try header.inspect().find(text: "TaskScope"))
    }

    /// A11-2: with unreadable settings the saved Keep Off intent is unknown, so
    /// the card shows it as unknown rather than as an Off switch, and says that
    /// background enforcement is paused until settings are reset.
    func testUnreadableSettingsShowKeepOffAsUnknownAndSayEnforcementIsPaused() throws {
        let recovery = makeCard(enabled: false)
        XCTAssertThrowsError(try recovery.inspect().find(ViewType.Toggle.self), "No Off switch in recovery")
        XCTAssertNoThrow(try recovery.inspect().find(text: "Keep GlobalProtect Off: Unknown"))
        XCTAssertNoThrow(try recovery.inspect().find(
            text: "Keep Off is not enforced in the background until then. After the reset, Keep Off is off until you turn it on again."
        ))

        let normal = makeCard(enabled: true)
        XCTAssertNoThrow(try normal.inspect().find(ViewType.Toggle.self))
        XCTAssertThrowsError(try normal.inspect().find(text: "Keep GlobalProtect Off: Unknown"))
    }

    /// L07-11: window suppression matches exactly the scene titles, declared
    /// once; the stale "TaskScope Processes" title is gone.
    func testWindowSuppressionUsesExactlyTheSceneTitles() {
        XCTAssertEqual(AppDelegate.automaticWindowTitles, ["TaskScope", "About TaskScope", "Onboarding"])
        XCTAssertEqual(AppDelegate.automaticWindowTitles, Set(TaskScopeScene.allCases.map(\.title)))
        XCTAssertFalse(AppDelegate.automaticWindowTitles.contains("TaskScope Processes"))
        XCTAssertEqual(TaskScopeScene.main.id, "processes")
        XCTAssertEqual(TaskScopeScene.about.id, "about")
        XCTAssertEqual(TaskScopeScene.onboarding.id, "onboarding")
    }

    /// L11-15: the list's Filter and Tree View are saved like Sort, and older
    /// payloads without them still load.
    func testFilterAndTreeViewArePersisted() throws {
        let defaults = batch02Defaults()
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.filterMode, .all)
        XCTAssertFalse(store.treeMode)

        store.filterModeRaw = ProcessFilterMode.watched.rawValue
        store.treeMode = true

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.filterMode, .watched)
        XCTAssertTrue(reloaded.treeMode)

        let older = batch02Defaults()
        older.set(Data(#"{"schemaVersion":3,"sortKeyRaw":"memory"}"#.utf8), forKey: "TaskScope.settings.v1")
        let fromOlder = SettingsStore(userDefaults: older)
        XCTAssertFalse(fromOlder.isReadOnlyAfterCorruption)
        XCTAssertEqual(fromOlder.sortKey, .memory)
        XCTAssertEqual(fromOlder.filterMode, .all)
        XCTAssertFalse(fromOlder.treeMode)

        let unknown = batch02Defaults()
        unknown.set(Data(#"{"schemaVersion":3,"filterModeRaw":"future"}"#.utf8), forKey: "TaskScope.settings.v1")
        XCTAssertEqual(SettingsStore(userDefaults: unknown).filterMode, .all)
    }

    private func makeCard(enabled: Bool) -> PresetCard {
        PresetCard(
            snapshot: WatchedAppSnapshot(preset: .globalProtect, runningNames: []),
            onOpen: {}, onQuitApp: {}, onQuitHelpers: {}, onQuitAll: {},
            isKeptOff: false, isKeepOffControlEnabled: enabled, onKeepOffChanged: { _ in }
        )
    }
}
