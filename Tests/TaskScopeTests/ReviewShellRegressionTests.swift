import XCTest
@testable import TaskScope

final class ReviewShellRegressionTests: XCTestCase {
    @MainActor
    func testActivityMonitorHandoffAcceptsAnotherUsersInventoryIdentity() async throws {
        // Read-only integration coverage: ps and kernel identity reads are real;
        // opening Activity Monitor and Accessibility selection are always faked.
        let processes = try await ProcessListReader.currentProcessList(fetchExtendedStats: false).get()
        let process = try XCTUnwrap(processes.first {
            $0.uid != getuid() && $0.executablePath == "/usr/libexec/logd"
        }, "The system log daemon must provide a stable other-user inventory row")
        let opener = ReviewShellActivityOpener()
        let selector = ReviewShellActivitySelector()
        let coordinator = ActivityMonitorCoordinator(
            opener: opener, processChecker: SystemActivityMonitorProcessChecker(),
            selector: selector, sleep: { _ in }
        )

        let identityOutcome = await coordinator.openAndSelect(identity: process.identity)
        XCTAssertEqual(identityOutcome, .success, "A visible other-user process must pass identity verification")
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(selector.requestedPIDs, [process.pid])
    }

    func testIntentQueriesDoNotPublishDefaultsForWrongTypePresets() async throws {
        let suite = "TaskScope.ReviewShell.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = WatchedAppsStore.defaultPersistenceKey
        let query = WatchedPresetEntityQuery(catalog: WatchedPresetCatalog(key: WatchedAppsStore.defaultPersistenceKey, objectForKey: defaults.objectReader))
        for payload: Any in ["unreadable", ["unexpected": "dictionary"], ["unexpected", "array"]] {
            defaults.set(payload, forKey: key)
            let suggested = try await query.suggestedEntities()
            let matching = try await query.entities(matching: "Global")
            let identified = try await query.entities(for: [WatchedAppPreset.globalProtectID])
            XCTAssertTrue(suggested.isEmpty, "Wrong-type presets must not publish a default target")
            XCTAssertTrue(matching.isEmpty)
            XCTAssertTrue(identified.isEmpty)
            XCTAssertTrue((defaults.object(forKey: key) as? NSObject)?.isEqual(payload) == true)
        }
    }
}

@MainActor
private final class ReviewShellActivityOpener: ActivityMonitorOpening {
    var openCount = 0
    func open() async throws { openCount += 1 }
}

@MainActor
private final class ReviewShellActivitySelector: ActivityMonitorProcessSelecting {
    var requestedPIDs: [Int32] = []
    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        requestedPIDs.append(pid)
        return .selected
    }
}
