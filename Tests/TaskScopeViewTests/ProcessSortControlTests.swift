import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L09-21: the column titles and the Sort menu, on the popover installed in a
/// window (`hosted`), so its own state behaves as in the app.
@MainActor
final class ProcessSortControlTests: XCTestCase {
    func testEverySortableTitleIsABorderlessButtonThatSortsAndReverses() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let titles: [(String, ProcessSortKey)] = [
            ("PID", .pid), ("PPID", .parentPID), ("USER", .user), ("NET KB/S", .network),
            ("DISK MB/S", .disk), ("CPU", .cpu), ("MEM MB", .memory)
        ]
        let view = try await hosted(Batch10.popover(fixture))
        for (title, key) in titles {
            let button = try view.find(button: title)
            XCTAssertTrue(try button.buttonStyle() is BorderlessButtonStyle, title)
            XCTAssertEqual(try button.accessibilityHint().string(), "Sorts the process list by this column", title)
            try button.tap()
            XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: key), title)
            XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: key), title)

            let active = try view.find(button: title)
            XCTAssertEqual(try active.accessibilityValue().string(), key.defaultDirection.accessibilityValue, title)
            XCTAssertEqual(try active.accessibilityHint().string(), "Reverses the sort order", title)
            let chevron = key.defaultDirection == .descending ? "chevron.down" : "chevron.up"
            XCTAssertNoThrow(try active.find(ViewType.Image.self) { try $0.actualImage().name() == chevron }, title)
            try active.tap()
            let reversed = ProcessSortOrder(key: key, direction: key.defaultDirection.reversed)
            XCTAssertEqual(fixture.stores.settings.sortOrder, reversed, title)
            XCTAssertEqual(fixture.manager.sortOrder, reversed, title)
            XCTAssertEqual(try view.find(button: title).accessibilityValue().string(), reversed.direction.accessibilityValue, title)
        }
        // Only the active column is marked.
        XCTAssertEqual(try view.find(button: "CPU").accessibilityValue().string(), "")
        XCTAssertEqual(try view.find(button: "CPU").help().string(), "Click to sort by CPU.")
        XCTAssertEqual(try view.find(button: "MEM MB").help().string(), "Sorted by Memory, ascending; click to reverse.")
    }

    func testCompactPopoverTitlesSortToo() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let view = try await hosted(Batch10.popover(fixture, style: .menuBarCompact))
        XCTAssertThrowsError(try view.find(button: "PPID"), "the popover has no PPID column")
        try view.find(button: "MEM MB").tap()
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .memory))
    }

    func testSortMenuOffersEveryKeyAndBothDirections() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let view = try await hosted(Batch10.popover(fixture))
        func menu() throws -> InspectableView<ViewType.Menu> {
            try view.find(ViewType.Menu.self) { try $0.accessibilityLabel().string() == "Sort" }
        }
        func picker(_ label: String) throws -> InspectableView<ViewType.Picker> {
            try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == label }
        }
        for key in ProcessSortKey.allCases { XCTAssertNoThrow(try picker("Sort By").find(text: key.label)) }
        XCTAssertNoThrow(try picker("Order").find(text: "Ascending"))
        XCTAssertNoThrow(try picker("Order").find(text: "Descending"))
        XCTAssertEqual(try menu().labelView().text().string(), "CPU ↓")

        try picker("Sort By").select(value: ProcessSortKey.user)
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .ascending))
        try picker("Order").select(value: ProcessSortDirection.descending)
        XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .descending))

        // Choosing the current key again keeps its direction.
        try picker("Sort By").select(value: ProcessSortKey.user)
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        XCTAssertEqual(try menu().labelView().text().string(), "User ↓")
        XCTAssertEqual(try menu().accessibilityValue().string(), "User, descending")
    }

    func testOnlyAPopoverSortedByNetworkOrDiskReadsThoseCounters() {
        for key in ProcessSortKey.allCases {
            XCTAssertEqual(
                TaskScopePopoverView.needsSortMetrics(isExpandedWindow: false, isOnScreen: true, sortKey: key),
                key == .network || key == .disk, "\(key)"
            )
            XCTAssertFalse(TaskScopePopoverView.needsSortMetrics(isExpandedWindow: false, isOnScreen: false, sortKey: key))
            XCTAssertFalse(
                TaskScopePopoverView.needsSortMetrics(isExpandedWindow: true, isOnScreen: true, sortKey: key),
                "the window reads them whenever it is open"
            )
        }
    }
}
