import AppKit
import ViewInspector
import XCTest
@testable import TaskScope

/// L11-21: the menu-bar icon shows TaskScope's state while the popover is
/// closed, on one fixed canvas so the status item never changes width.
@MainActor
final class MenuBarStatusTests: XCTestCase {
    private let example = WatchedAppPreset(
        displayName: "Example",
        mainProcessName: "Example",
        helperProcessNames: ["Example Helper"],
        protectedProcessNames: ["ExampleService"],
        appPath: "/Applications/Example.app"
    )
    private let other = WatchedAppPreset(
        displayName: "Other",
        mainProcessName: "Other",
        helperProcessNames: [],
        protectedProcessNames: [],
        appPath: "/Applications/Other.app"
    )

    private func resolve(
        _ snapshots: [WatchedAppSnapshot],
        presets: [WatchedAppPreset]? = nil,
        availability: WatchedStatusAvailability = .current,
        keptOff: Set<UUID> = [],
        prompts: Int = 0
    ) -> MenuBarStatus {
        MenuBarStatus.resolve(
            presets: presets ?? [example, other],
            snapshots: snapshots,
            availability: availability,
            isKeptOff: { keptOff.contains($0.id) },
            pendingPromptCount: prompts
        )
    }

    private func snapshot(
        _ preset: WatchedAppPreset, running: Set<String> = [], userAgent: Bool = false
    ) -> WatchedAppSnapshot {
        WatchedAppSnapshot(preset: preset, runningNames: running, hasCurrentUserLaunchAgent: userAgent)
    }

    func testEachStateComesFromPublishedValues() {
        let quiet = [snapshot(example), snapshot(other)]
        XCTAssertEqual(resolve(quiet), .normal)
        // Helpers alone are not the watched app running.
        XCTAssertEqual(resolve([snapshot(example, running: ["Example Helper"]), snapshot(other)]), .normal)
        XCTAssertEqual(resolve([snapshot(example), snapshot(other, running: ["Other"])]), .watchedAppRunning)

        // Keep Off is on, but its service or user agent is back.
        let service = [snapshot(example, running: ["ExampleService"]), snapshot(other)]
        XCTAssertEqual(resolve(service, keptOff: [example.id]), .keepOffServiceRunning)
        XCTAssertEqual(resolve(service), .normal, "a protected service of a preset not kept off is not news")
        let agent = [snapshot(example, userAgent: true), snapshot(other)]
        XCTAssertEqual(resolve(agent, keptOff: [example.id]), .keepOffServiceRunning)
        XCTAssertEqual(resolve(quiet, keptOff: [example.id]), .normal, "kept off and quiet")

        XCTAssertEqual(resolve(quiet, availability: .stale), .statusStale)
        XCTAssertEqual(resolve(quiet, availability: .unknown), .statusUnknown)
        XCTAssertEqual(resolve([snapshot(example)]), .statusUnknown, "a preset no read has covered")
        XCTAssertEqual(resolve(quiet, prompts: 2), .autoStopPromptPending)
    }

    func testTheStateThatMostNeedsTheUserWins() {
        let everything = [snapshot(example, running: ["Example", "ExampleService"]), snapshot(other, running: ["Other"])]
        XCTAssertEqual(resolve(everything, availability: .stale, keptOff: [example.id], prompts: 1),
                       .autoStopPromptPending)
        XCTAssertEqual(resolve(everything, availability: .stale, keptOff: [example.id]), .statusStale,
                       "stale snapshots cannot claim that anything runs")
        XCTAssertEqual(resolve(everything, keptOff: [example.id]), .keepOffServiceRunning)
        XCTAssertEqual(resolve(everything), .watchedAppRunning)
        // Snapshots of presets that are no longer stored are ignored.
        XCTAssertEqual(resolve(everything, presets: []), .normal)
    }

    func testEveryStateHasItsOwnLabelAndUnknownAndStaleShareAMark() {
        XCTAssertEqual(Set(MenuBarStatus.allCases.map(\.accessibilityLabel)).count, MenuBarStatus.allCases.count)
        XCTAssertEqual(MenuBarStatus.normal.accessibilityLabel, "TaskScope")
        XCTAssertEqual(MenuBarStatus.statusUnknown.badge, MenuBarStatus.statusStale.badge)
        XCTAssertEqual(Set(MenuBarStatus.allCases.map(\.badge)), Set(MenuBarStatus.Badge.allCases))
    }

    func testEveryImageIsATemplateOnTheSameCanvasAndEachMarkLooksDifferent() throws {
        var drawings: [MenuBarStatus.Badge: Data] = [:]
        for status in MenuBarStatus.allCases {
            let image = MenuBarStatusIcon.image(for: status)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(status)")
            XCTAssertTrue(image.isTemplate, "\(status)")
            XCTAssertEqual(image.accessibilityDescription, status.accessibilityLabel)
            XCTAssertTrue(image === MenuBarStatusIcon.image(for: status), "an unchanged state reuses its image")
            let pixels = try alphaPixels(of: image)
            XCTAssertTrue(pixels.contains { $0 > 0 }, "\(status) draws something")
            if let earlier = drawings[status.badge] {
                XCTAssertEqual(pixels, earlier, "\(status) draws its mark's image")
            }
            drawings[status.badge] = pixels
        }
        XCTAssertEqual(Set(drawings.values).count, MenuBarStatus.Badge.allCases.count, "every mark is distinct")
    }

    func testTheLabelNamesTheStateForVoiceOver() throws {
        for status in MenuBarStatus.allCases {
            let label = try TaskScopeStatusItemLabel(status: status).inspect().find(ViewType.Label.self)
            XCTAssertEqual(try label.accessibilityLabel().string(), status.accessibilityLabel)
        }
    }

    func testTheSettingIsOnByDefaultPersistsAndOlderSettingsShowTheState() throws {
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.MenuBarStatusTests.\(UUID().uuidString)"))
        let store = SettingsStore(userDefaults: defaults, key: "menu-bar-settings")
        XCTAssertTrue(store.showsMenuBarStatus)
        store.showsMenuBarStatus = false
        XCTAssertFalse(SettingsStore(userDefaults: defaults, key: "menu-bar-settings").showsMenuBarStatus)

        // A payload from before the setting existed shows the state.
        defaults.set(Data(#"{"schemaVersion":3,"refreshIntervalSeconds":10}"#.utf8), forKey: "older-settings")
        XCTAssertTrue(SettingsStore(userDefaults: defaults, key: "older-settings").showsMenuBarStatus)
    }

    func testTheLabelFollowsTheStoresAndStaysPlainWithTheSettingOff() async throws {
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.MenuBarStatusTests.\(UUID().uuidString)"))
        let watchedApps = WatchedAppsStore(userDefaults: defaults, key: "menu-bar-presets")
        let settings = SettingsStore(userDefaults: defaults, key: "menu-bar-settings")
        let rules = AutoStopRulesStore(
            userDefaults: defaults, key: "menu-bar-rules", eventsKey: "menu-bar-events",
            inventory: MenuBarInventory(processes: [])
        )
        let main = "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"
        let manager = ProcessManager(
            processInventory: MenuBarInventory(processes: [AppProcess(
                pid: 4242, parentPID: 1, uid: getuid(), cpu: 0, memoryMB: 0, command: main,
                executablePath: main, elapsedTime: "00:01", netInKB: nil, netOutKB: nil,
                diskReadBytes: nil, diskWriteBytes: nil
            )]),
            processSignaler: MenuBarInertSignaler(),
            settleAfterProcessChange: {},
            dependencies: .inert
        )
        manager.enableNotifications = false
        manager.dependencies.watchedPresets = { watchedApps.presets }
        func label() -> TaskScopeMenuBarStatusLabel {
            TaskScopeMenuBarStatusLabel(
                processManager: manager, watchedApps: watchedApps, autoStopRules: rules, settings: settings
            )
        }

        XCTAssertEqual(label().status, .statusUnknown, "nothing has been read yet")
        await manager.refreshWatchedStatus(showMessage: false)
        XCTAssertEqual(label().status, .watchedAppRunning)
        manager.dependencies.isPresetKeptOff = { _ in true }
        XCTAssertEqual(label().status, .watchedAppRunning, "no service is running")

        settings.showsMenuBarStatus = false
        XCTAssertEqual(label().status, .normal)
        let rendered = try label().inspect().find(ViewType.Label.self)
        XCTAssertEqual(try rendered.accessibilityLabel().string(), "TaskScope")
    }

    /// Renders the image at 2x into a bitmap and returns its alpha channel.
    private func alphaPixels(of image: NSImage) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 36 * 4, bitsPerPixel: 32
        ))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        let bytes = try XCTUnwrap(rep.bitmapData)
        return Data((0..<(36 * 36)).map { bytes[$0 * 4 + 3] })
    }
}

private struct MenuBarInventory: ProcessInventoryProviding {
    var processes: [AppProcess]
    func load(fetchExtendedStats: Bool) async -> Result<[AppProcess], ProcessInventoryError> {
        .success(processes)
    }
}

private struct MenuBarInertSignaler: ProcessSignaling {
    func send(_ signal: Int32, to pid: Int32) -> Bool { false }
    func isAlive(_ pid: Int32) -> Bool { false }
}
