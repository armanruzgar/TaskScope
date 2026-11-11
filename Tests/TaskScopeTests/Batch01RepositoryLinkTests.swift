import XCTest

/// L14-3: the account that owns the repository was renamed from 38st to
/// armanruzgar. Links to the old name resolve only through GitHub's rename
/// redirect, which anyone can take over by registering 38st and creating a
/// TaskScope repository there: the clone command and the private
/// vulnerability-report links would then lead to their copy.
final class Batch01RepositoryLinkTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Tracked files people read on GitHub. An explicit list, because a
    /// checkout may hold untracked notes that quote the old links.
    private static let publishedFiles = [
        "README.md", "SECURITY.md", "SUPPORT.md", "CODE_OF_CONDUCT.md", "CONTRIBUTING.md",
        "CHANGELOG.md", "PRIVACY.md", "RELEASE.md", "ROADMAP.md", "THREAT_MODEL.md",
        "GLOBALPROTECT_COMPATIBILITY.md", "docs/AUTOMATION.md", "docs/GLOBALPROTECT.md",
        "docs/USING_TASKSCOPE.md", ".github/pull_request_template.md",
        ".github/ISSUE_TEMPLATE/config.yml", ".github/ISSUE_TEMPLATE/bug_report.yml",
        ".github/ISSUE_TEMPLATE/feature_request.yml"
    ]

    func testPublishedFilesLinkOnlyToTheCurrentAccount() throws {
        for path in Self.publishedFiles {
            XCTAssertFalse(try text(path).contains("github.com/38st/"), "\(path) links to the renamed account")
        }
        let advisoryForm = "https://github.com/armanruzgar/TaskScope/security/advisories/new"
        for path in ["SECURITY.md", "CODE_OF_CONDUCT.md", ".github/ISSUE_TEMPLATE/config.yml",
                     ".github/ISSUE_TEMPLATE/bug_report.yml"] {
            XCTAssertTrue(try text(path).contains(advisoryForm), "\(path) must link to the private advisory form")
        }
        XCTAssertTrue(try text("README.md").contains("git clone https://github.com/armanruzgar/TaskScope.git"))
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
