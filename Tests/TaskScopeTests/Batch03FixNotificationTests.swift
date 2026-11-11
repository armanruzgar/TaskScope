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
                                     lifecycle: ManagerTestLifecycle(), settleAfterProcessChange: {})
        manager.watchedAppsProvider = { presets }
        var baseline = ProcessNotificationBaseline()
        var started: [Set<String>] = [], stopped: [Set<String>] = []
        manager.primeNotificationBaseline = { baseline.rebaseline($0) }
        manager.notifyTransitions = {
            let transitions = baseline.transitions(to: $0, canNotify: true)
            started.append(transitions.started)
            stopped.append(transitions.stopped)
        }

        await manager.refreshWatchedStatus()
        await manager.refreshWatchedStatus()
        await manager.refreshWatchedStatus()

        let slackHelper = "Slack: chrome_crashpad_handler"
        XCTAssertEqual(stopped, [[slackHelper], []], "Slack's helper stopping while Discord's runs must notify")
        XCTAssertEqual(started, [[], [slackHelper]], "Slack's helper starting again must notify")
    }
}
