import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

/// L09-21: the column titles and the Sort menu.
@MainActor
final class ProcessSortControlTests: XCTestCase {
    func testEverySortableTitleIsABorderlessButtonThatSortsAndReverses() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let titles: [(String, ProcessSortKey)] = [
            ("PID", .pid), ("PPID", .parentPID), ("USER", .user), ("NET KB/S", .network),
            ("DISK MB/S", .disk), ("CPU", .cpu), ("MEM MB", .memory)
        ]
        for (title, key) in titles {
            let button = try Batch10.popover(fixture).inspect().find(button: title)
            XCTAssertTrue(try button.buttonStyle() is BorderlessButtonStyle, title)
            XCTAssertEqual(try button.accessibilityHint().string(), "Sorts the process list by this column", title)

            try button.tap()
            XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: key), title)
            XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: key), title)
            let active = try Batch10.popover(fixture).inspect().find(button: title)
            XCTAssertEqual(try active.accessibilityValue().string(), key.defaultDirection.accessibilityValue, title)
            XCTAssertEqual(try active.accessibilityHint().string(), "Reverses the sort order", title)
            let chevron = key.defaultDirection == .descending ? "chevron.down" : "chevron.up"
            XCTAssertNoThrow(try active.find(ViewType.Image.self) { try $0.actualImage().name() == chevron }, title)

            try active.tap()
            let reversed = ProcessSortOrder(key: key, direction: key.defaultDirection.reversed)
            XCTAssertEqual(fixture.stores.settings.sortOrder, reversed, title)
            XCTAssertEqual(fixture.manager.sortOrder, reversed, title)
            XCTAssertEqual(
                try Batch10.popover(fixture).inspect().find(button: title).accessibilityValue().string(),
                reversed.direction.accessibilityValue, title
            )
        }
        // Only the active column is marked.
        let inspected = try Batch10.popover(fixture).inspect()
        XCTAssertEqual(try inspected.find(button: "CPU").accessibilityValue().string(), "")
        XCTAssertEqual(
            try inspected.find(button: "CPU").help().string(),
            "Click to sort by CPU."
        )
        XCTAssertEqual(
            try inspected.find(button: "MEM MB").help().string(),
            "Sorted by Memory, ascending; click to reverse."
        )
    }

    func testCompactPopoverTitlesSortToo() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        let popover = try Batch10.popover(fixture, style: .menuBarCompact).inspect()
        XCTAssertThrowsError(try popover.find(button: "PPID"), "the popover has no PPID column")
        try popover.find(button: "MEM MB").tap()
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .memory))
    }

    func testSortMenuOffersEveryKeyAndBothDirections() async throws {
        let fixture = await Batch10.fixture(processes: [Batch10.process(51)])
        defer { fixture.stores.cleanup() }
        func menu() throws -> InspectableView<ViewType.Menu> {
            try Batch10.popover(fixture).inspect().find(ViewType.Menu.self) { try $0.accessibilityLabel().string() == "Sort" }
        }
        let keys = try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Sort By" }
        let directions = try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Order" }
        for key in ProcessSortKey.allCases { XCTAssertNoThrow(try keys.find(text: key.label)) }
        XCTAssertNoThrow(try directions.find(text: "Ascending"))
        XCTAssertNoThrow(try directions.find(text: "Descending"))
        XCTAssertEqual(try menu().labelView().text().string(), "CPU ↓")

        try keys.select(value: ProcessSortKey.user)
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .ascending))
        try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Order" }
            .select(value: ProcessSortDirection.descending)
        XCTAssertEqual(fixture.stores.settings.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        XCTAssertEqual(fixture.manager.sortOrder, ProcessSortOrder(key: .user, direction: .descending))
        // Choosing the current key again keeps its direction.
        try menu().find(ViewType.Picker.self) { try $0.labelView().text().string() == "Sort By" }
            .select(value: ProcessSortKey.user)
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
