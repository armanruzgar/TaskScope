import XCTest
import TaskScopeTestEnvironment

/// L15-14: XCTest builds its test list by enumerating every class in the process,
/// and ViewInspector links AuthenticationServices, which loads ContactsUI. That
/// enumeration initializes CNContactStore, whose background address-book warm-up
/// asks tccd for Contacts access and tries to open the user's Contacts database
/// unless CN_UNIT_TESTING is set before it runs.
final class TestEnvironmentTests: XCTestCase {
    func testContactsWarmUpIsSwitchedOffWhenTheTestBundleLoads() {
        XCTAssertTrue(
            taskscope_test_environment_was_prepared_at_load(),
            "The setup must run while the bundle loads, before XCTest enumerates classes"
        )
        // Contacts reads the variable through NSProcessInfo, as this does.
        XCTAssertEqual(ProcessInfo.processInfo.environment["CN_UNIT_TESTING"], "YES")
    }
}
