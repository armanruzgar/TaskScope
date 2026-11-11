import AppKit
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the composition root and runtime
// (TaskScopeRuntime), the command coordinator's Open and Stop routing, and the
// Stop Watched App intent. Lifecycle, inventory and signaler are fakes: nothing
// is signalled and no launchctl, Accessibility or notification call is made.

// MARK: - Stop Watched App intent (T05-4, L12-1)

@MainActor
final class Batch02StopIntentTests: XCTestCase {
    /// T05-4: perform() asks the system to confirm before anything is
    /// submitted, and a declined confirmation submits nothing.
    func testPerformAsksForConfirmationBeforeSubmittingAndDeclineStopsNothing() async throws {
        let savedBus = StopWatchedAppIntent.commandBus
        let savedConfirmation = StopWatchedAppIntent.requestStopConfirmation
        defer {
            StopWatchedAppIntent.commandBus = savedBus
            StopWatchedAppIntent.requestStopConfirmation = savedConfirmation
        }
        var events: [String] = []
        let bus = AppCommandBus()
        bus.install { command in
            events.append("submitted \(command)")
            return .init(status: .completed, message: "Stopped Example.")
        }
        StopWatchedAppIntent.commandBus = bus
        StopWatchedAppIntent.requestStopConfirmation = { intent, message in
            XCTAssertTrue(message.contains("force stopped"), message)
            events.append("confirm \(intent.app.displayName)")
        }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(id: UUID(), displayName: "Example")

        _ = try await intent.perform()

        XCTAssertEqual(events, ["confirm Example", "submitted \(TaskScopeCommand.stopPresetEntity(intent.app.commandTarget))"])

        StopWatchedAppIntent.requestStopConfirmation = { _, _ in throw CancellationError() }
        do {
            _ = try await intent.perform()
            XCTFail("A declined confirmation must throw")
        } catch is CancellationError {}
        XCTAssertEqual(events.count, 2, "A declined confirmation submits nothing")
    }

    /// T05-4: on macOS 14 a declined confirmation comes back as false.
    func testADeclinedMacOS14ConfirmationCancels() {
        XCTAssertNoThrow(try StopWatchedAppIntent.requireConfirmed(true))
        XCTAssertThrowsError(try StopWatchedAppIntent.requireConfirmed(false)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    /// L12-1: the Shortcuts confirmation discloses what the stop does, like the
    /// in-app Close confirmation: the agents it unloads and the force stop.
    func testTheConfirmationDisclosesAgentUnloadsAndTheForceStop() async throws {
        let custom = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["ExampleHelper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(
                label: "com.example.batch02.agent",
                plistPath: "/Library/LaunchAgents/com.example.batch02.agent.plist"
            )]
        )
        let customMessage = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(preset: custom), preset: custom
        )
        XCTAssertTrue(customMessage.hasPrefix("Stop Example and its eligible watched processes?"), customMessage)
        XCTAssertTrue(customMessage.contains("com.example.batch02.agent"), customMessage)
        XCTAssertTrue(customMessage.contains(PresetStopScope.forceStopDisclosure), customMessage)
        XCTAssertTrue(customMessage.contains("3 seconds"), customMessage)

        let globalProtect = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(preset: .globalProtect), preset: .globalProtect
        )
        XCTAssertTrue(globalProtect.contains("com.paloaltonetworks.gp.pangpa"), globalProtect)
        XCTAssertFalse(globalProtect.contains("pangps"), "Shortcuts Stop never unloads the VPN service")

        let unknown = StopWatchedAppIntent.stopConfirmationMessage(
            for: WatchedPresetEntity(id: UUID(), displayName: "Gone"), preset: nil
        )
        XCTAssertTrue(unknown.contains(PresetStopScope.forceStopDisclosure), unknown)

        // The intent looks the preset up in the stored catalog.
        let bus = AppCommandBus()
        bus.install { _ in .init(status: .completed, message: "Stopped.") }
        let intent = StopWatchedAppIntent()
        intent.app = WatchedPresetEntity(preset: .globalProtect)
        var shown: String?
        _ = try await intent.executeStop(
            bus: bus, catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: batch02Defaults().objectReader)
        ) { shown = $0 }
        XCTAssertEqual(shown, globalProtect)
    }
}
