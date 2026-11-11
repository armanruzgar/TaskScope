import Darwin
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// The row shows and announces a command-line match without showing the
/// command line.
@MainActor
final class CommandLineSearchRowTests: XCTestCase {
    func testRowMarksACommandLineMatch() throws {
        let process = Batch10.process(60, name: "Worker")
        func row(_ matched: Bool) -> ProcessRow {
            ProcessRow(process: process, isCurrentProcess: false, isSelected: false, isKeyboardSelected: false,
                       isHighlightedCPU: false, isHighlightedMEM: false, matchedByCommandLine: matched,
                       stopAction: {}, toggleSelection: {})
        }
        let marked = try row(true).inspect()
        XCTAssertNoThrow(try marked.find(ViewType.Image.self) { try $0.actualImage().name() == "text.magnifyingglass" })
        XCTAssertTrue(try marked.find(ViewType.VStack.self).accessibilityValue().string()
            .contains("matches the search in its command line"))
        let plain = try row(false).inspect()
        XCTAssertThrowsError(try plain.find(ViewType.Image.self) { try $0.actualImage().name() == "text.magnifyingglass" })
        XCTAssertFalse(try plain.find(ViewType.VStack.self).accessibilityValue().string().contains("command line"))
    }
}
