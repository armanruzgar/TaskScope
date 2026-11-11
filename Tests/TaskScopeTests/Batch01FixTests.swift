import XCTest
@testable import TaskScope

/// A05-11 and L15-11: every test keeps its settings in its own in-memory
/// domain, so concurrent test processes cannot share fixtures and no test run
/// leaves a TaskScope.*.plist file in ~/Library/Preferences.
final class Batch01DefaultsTests: XCTestCase {
    func testDomainsAreIsolatedAndNeverReachThePreferencesDaemon() throws {
        let firstName = "TaskScope.Batch01.first.\(UUID().uuidString)"
        let secondName = "TaskScope.Batch01.second.\(UUID().uuidString)"
        let first = try XCTUnwrap(InMemoryUserDefaults(suiteName: firstName))
        let second = try XCTUnwrap(InMemoryUserDefaults(suiteName: secondName))
        first.set(Data([1, 2]), forKey: "payload")
        first.set(true, forKey: "enabled")
        second.set("independent", forKey: "payload")
        XCTAssertEqual(first.data(forKey: "payload"), Data([1, 2]))
        XCTAssertTrue(first.bool(forKey: "enabled"))
        XCTAssertEqual(second.string(forKey: "payload"), "independent")

        first.removePersistentDomain(forName: firstName)
        XCTAssertTrue(first.dictionaryRepresentation().isEmpty)
        XCTAssertEqual(second.string(forKey: "payload"), "independent")

        // Reading a domain does not create it: neither instance may have
        // written through to cfprefsd.
        XCTAssertNil(UserDefaults(suiteName: firstName)?.persistentDomain(forName: firstName))
        XCTAssertNil(UserDefaults(suiteName: secondName)?.persistentDomain(forName: secondName))
    }

    func testValuesReadBackAsPropertyListsLikeRealDefaults() throws {
        let name = "TaskScope.Batch01.plist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: name))
        defaults.set(["enabled": true, "keyCode": UInt32(17)], forKey: "hotkey")
        let stored = try XCTUnwrap(defaults.dictionary(forKey: "hotkey"))
        // cfprefsd returns NSNumber, which bridges to any numeric type.
        XCTAssertEqual(stored["keyCode"] as? Int, 17)
        XCTAssertEqual(stored["enabled"] as? Bool, true)
        XCTAssertTrue(stored["keyCode"] is NSNumber)

        defaults.set(nil as Any?, forKey: "hotkey")
        XCTAssertNil(defaults.object(forKey: "hotkey"))
    }
}
