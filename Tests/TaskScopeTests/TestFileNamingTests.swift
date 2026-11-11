import Foundation
import XCTest

/// L07-8: `swift test --filter <file name>` selects every test in a file, and
/// no file silently runs zero tests. Every Swift file in a test target outside
/// `Support/` declares at least one `XCTestCase` subclass, the name of each such
/// class contains its file's name, and `Support/` holds no tests.
final class TestFileNamingTests: XCTestCase {
    private static var testClass: NSRegularExpression {
        try! NSRegularExpression(
            pattern: #"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|public|internal|open)\s+)*class\s+(\w+)\s*:\s*XCTestCase\b"#,
            options: [.anchorsMatchLines]
        )
    }

    func testEveryTestClassIsSelectedByItsFileName() throws {
        let files = try testSourceFiles()
        XCTAssertGreaterThan(files.count, 50, "The scan must see the test sources")
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let classes = try testClasses(in: file)
            if file.pathComponents.contains("Support") {
                XCTAssertEqual(classes, [], "\(file.lastPathComponent) is support code and must not declare tests")
                continue
            }
            XCTAssertFalse(classes.isEmpty, "\(file.lastPathComponent) declares no tests, so filtering by its name runs nothing")
            for testClass in classes {
                XCTAssertTrue(
                    testClass.contains(name),
                    "\(testClass) in \(file.lastPathComponent): `swift test --filter \(name)` would not select it"
                )
            }
        }
    }

    func testTheScanFindsTestClassesInEveryDeclarationForm() throws {
        let source = """
        final class PlainTests: XCTestCase {}
        @MainActor
        final class IsolatedTests: XCTestCase {
        }
        @MainActor final class SameLineTests: XCTestCase {}
        private final class HelperTests: NSObject {}
        """
        let range = NSRange(source.startIndex..., in: source)
        let names = Self.testClass.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertEqual(names, ["PlainTests", "IsolatedTests", "SameLineTests"])
    }

    /// Swift files of every test target: the folders beside this one in Tests/,
    /// except the C target that prepares the test environment.
    private func testSourceFiles() throws -> [URL] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = FileManager.default
        var files: [URL] = []
        for target in try manager.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil)
        where target.lastPathComponent != "TaskScopeTestEnvironment" && target.hasDirectoryPath {
            let enumerator = manager.enumerator(at: target, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "swift" { files.append(url) }
            }
        }
        return files
    }

    private func testClasses(in file: URL) throws -> [String] {
        let source = try String(contentsOf: file, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        return Self.testClass.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
