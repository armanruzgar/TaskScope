import XCTest
@testable import TaskScope

/// A helper name two presets share (Electron's crashpad handler, Sparkle's
/// updater) is diffed per preset, so one copy stopping or starting notifies
/// while the other keeps running, and the text names the preset.
@MainActor
final class Batch03NotificationTests: XCTestCase {
    func testSharedHelperTransitionsAreScopedToPresetAndNameTheApp() async {
        let presets = ["Slack", "Discord"].map {
            WatchedAppPreset(displayName: $0, mainProcessName: $0,
                             helperProcessNames: ["chrome_crashpad_handler"], protectedProcessNames: [],
                             appPath: "/Applications/\($0).app")
        }
        let helpers = zip([Int32(42), 43], ["Slack", "Discord"]).map { pid, app -> AppProcess in
            var row = batch03Process(pid: pid, name: "chrome_crashpad_handler")
            row.command = "/Applications/\(app).app/Contents/Helpers/chrome_crashpad_handler"
            row.executablePath = row.command
            return row
        }
        let inventory = ManagerTestInventory(results: [.success(helpers), .success([helpers[1]]), .success(helpers)])
        let manager = ProcessManager(processInventory: inventory, processSignaler: ManagerTestSignaler(),
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {}, dependencies: .inert)
        manager.dependencies.watchedPresets = { presets }
        // The manager's seams carry the watched snapshots to the service, which
        // diffs each preset on its own; this service records instead of posting.
        var delivered: [String] = []
        let service = NotificationService(
            isAvailable: true, authorizationState: .authorized,
            readAuthorization: { .authorized }, deliver: { delivered.append($0.content.body) }
        )
        manager.primeNotificationBaseline = { service.prime($0) }
        manager.notifyTransitions = { service.diffAndNotify($0) }
        manager.refreshNotificationAuthorization = {}

        await manager.refreshWatchedStatus()
        await manager.refreshWatchedStatus()
        XCTAssertEqual(
            delivered, ["Slack: chrome_crashpad_handler is no longer running."],
            "Slack's helper stopping while Discord's runs must notify"
        )
        await manager.refreshWatchedStatus()
        XCTAssertEqual(
            delivered.last, "Slack: chrome_crashpad_handler is now running.",
            "Slack's helper starting again must notify"
        )
        XCTAssertEqual(delivered.count, 2)
    }
}
