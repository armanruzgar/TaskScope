import XCTest
@testable import TaskScope

@MainActor
final class Batch04ManagerFixTests: XCTestCase {
    func testOpenFailsBeforeLaunchingForMissingUserAndSystemPlists() async {
        let example = WatchedAppPreset(displayName: "Batch04", mainProcessName: "Batch04NeverRunning", helperProcessNames: [], protectedProcessNames: [],
            appPath: "/Applications/Batch04NeverInstalled.app", userLaunchAgentJobs: [.init(label: "batch04.agent", plistPath: "/fake/batch04.plist")])
        for preset in [example, .globalProtect] {
            let fake = LifecycleRuntimeHarness(existingPaths: [preset.appPath], commandResults: [])
            let inventory = P7QueuedInventory(results: [.success([])])
            let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory, processSignaler: P7NoopSignaler(),
                lifecycle: SystemProcessLifecycleService(runtime: fake.runtime), settleAfterProcessChange: {})
            manager.enableNotifications = false
            let result = await manager.openApp(preset)
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(result.message.contains("Missing plist"), result.message)
            XCTAssertFalse(fake.commands.contains { $0.contains("/usr/bin/open") })
            XCTAssertEqual(manager.lifecycleReport?.jobs.filter { $0.state == .missing }.count, 1)
        }
    }

    func testOpenForwardsLaunchServicesFailureToUser() async {
        let preset = WatchedAppPreset(displayName: "Batch04", mainProcessName: "Batch04NeverRunning", helperProcessNames: [], protectedProcessNames: [], appPath: "/Applications/Batch04NeverInstalled.app")
        let fake = LifecycleRuntimeHarness(existingPaths: [preset.appPath], commandResults: [batch04Result(error: "Launch Services refused", code: 1)])
        let inventory = P7QueuedInventory(results: [.success([])])
        let manager = ProcessManager(processInventory: inventory, verificationInventory: inventory, processSignaler: P7NoopSignaler(),
            lifecycle: SystemProcessLifecycleService(runtime: fake.runtime), settleAfterProcessChange: {})
        manager.enableNotifications = false
        let result = await manager.openApp(preset)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Could not open Batch04: Launch Services refused.")
    }
}
