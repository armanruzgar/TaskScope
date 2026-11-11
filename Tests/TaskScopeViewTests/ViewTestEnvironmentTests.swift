import XCTest
import TaskScopeTestEnvironment

/// L15-14 for this target: it links ViewInspector, and with it the Contacts UI
/// frameworks, so Contacts' address-book warm-up must be off here as well.
final class ViewTestEnvironmentTests: XCTestCase {
    func testContactsWarmUpIsSwitchedOffWhenTheViewTestBundleLoads() {
        XCTAssertTrue(
            taskscope_test_environment_was_prepared_at_load(),
            "The setup must run while the bundle loads, before XCTest enumerates classes"
        )
        XCTAssertEqual(ProcessInfo.processInfo.environment["CN_UNIT_TESTING"], "YES")
    }
}
