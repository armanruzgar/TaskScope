import XCTest
@testable import TaskScope

final class PresetInputParserTests: XCTestCase {
    func testListTrimsWhitespaceAndDropsEmptyItems() {
        XCTAssertEqual(
            PresetInputParser.list(from: " GlobalProtect, PanGPA, , PanGPS "),
            ["GlobalProtect", "PanGPA", "PanGPS"]
        )
    }

    func testUserLaunchAgentJobsPairLabelsAndPaths() {
        let jobs = PresetInputParser.parseUserLaunchAgentJobs(
            labels: "com.example.agent, com.example.second",
            paths: "/Library/LaunchAgents/com.example.agent.plist, /Library/LaunchAgents/com.example.second.plist"
        )

        XCTAssertEqual(jobs.value, [
            UserLaunchAgentJob(
                label: "com.example.agent",
                plistPath: "/Library/LaunchAgents/com.example.agent.plist"
            ),
            UserLaunchAgentJob(
                label: "com.example.second",
                plistPath: "/Library/LaunchAgents/com.example.second.plist"
            )
        ])
    }

    func testEmptyLaunchAgentListsAreAccepted() {
        let result = PresetInputParser.parseUserLaunchAgentJobs(labels: " ", paths: " ")
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.value.isEmpty)
    }

    func testMissingPathsAreRejectedInsteadOfSilentlyDroppingJobs() {
        let result = PresetInputParser.parseUserLaunchAgentJobs(
            labels: "com.example.agent, com.example.second",
            paths: "/Library/LaunchAgents/com.example.agent.plist"
        )

        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testExtraPathsAreRejectedInsteadOfSilentlyDroppingJobs() {
        let result = PresetInputParser.parseUserLaunchAgentJobs(labels: "one", paths: "/one.plist, /two.plist")
        XCTAssertTrue(result.value.isEmpty)
        XCTAssertEqual(result.errors, ["Launch-agent labels and plist paths must have the same item count."])
    }
}
