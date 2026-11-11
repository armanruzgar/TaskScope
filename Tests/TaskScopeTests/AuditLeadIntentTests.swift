import Darwin
import XCTest
@testable import TaskScope

@MainActor
final class AuditLeadIntentTests: XCTestCase {
    // T05-2: Open Watched App hard-coded the shared bus, so no test could
    // check what it submits.
    func testOpenWatchedAppSubmitsAnOpenForTheChosenPreset() async throws {
        let savedBus = OpenWatchedAppIntent.commandBus
        defer { OpenWatchedAppIntent.commandBus = savedBus }
        var submitted: [TaskScopeCommand] = []
        let bus = AppCommandBus()
        bus.install { command in
            submitted.append(command)
            return .init(status: .completed, message: "Opened Example.")
        }
        OpenWatchedAppIntent.commandBus = bus
        let intent = OpenWatchedAppIntent()
        intent.app = WatchedPresetEntity(id: UUID(), displayName: "Example")

        _ = try await intent.perform()

        XCTAssertEqual(submitted, [.openPresetEntity(intent.app.commandTarget)])
    }
}
