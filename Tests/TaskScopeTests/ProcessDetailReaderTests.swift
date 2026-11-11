import XCTest
@testable import TaskScope

final class ProcessDetailReaderTests: XCTestCase {
    func testCommandKeepsInternalSpacesAfterTheEighthField() throws {
        let line = "  42     1 alice   Sat Jul  6 11:20:17 2026 /Applications/Example  App.app/Contents/MacOS/Example  App"

        let detail = try XCTUnwrap(SystemProcessDetailReader.parseDetailLine(
            line,
            expectedStartTime: "Sat Jul 6 11:20:17 2026"
        ))

        XCTAssertEqual(detail.pid, 42)
        XCTAssertEqual(detail.parentPID, 1)
        XCTAssertEqual(detail.user, "alice")
        XCTAssertEqual(detail.startTime, "Sat Jul 6 11:20:17 2026")
        XCTAssertEqual(detail.command, "/Applications/Example  App.app/Contents/MacOS/Example  App")
    }

    func testDetailRejectsADifferentStartTimeAndShortRows() {
        XCTAssertNil(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6 11:20:17 2026 /bin/sh",
            expectedStartTime: "Sat Jul 6 11:20:18 2026"
        ))
        XCTAssertNil(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6",
            expectedStartTime: "Sat Jul 6"
        ))
    }

    func testEmptyCommandIsPreservedAsEmpty() throws {
        let detail = try XCTUnwrap(SystemProcessDetailReader.parseDetailLine(
            "42 1 alice Sat Jul 6 11:20:17 2026",
            expectedStartTime: "Sat Jul 6 11:20:17 2026"
        ))

        XCTAssertEqual(detail.command, "")
    }

    /// Substring checks let a lost UTC pin pass in UTC+0, UTC+2, UTC-10 and
    /// UTC+12, where the wrong answer also contains "1:04:47". Pin the instant
    /// itself, and the whole displayed string.
    func testStartTimeIsReadInUTCAndShownInTheViewersTimeZone() {
        XCTAssertEqual(
            ProcessDetail.parsedStartTime("Wed Oct 7 17:04:47 2026"),
            Date(timeIntervalSince1970: 1_791_392_687),
            "17:04:47 UTC on Oct 7, 2026, whatever this machine's time zone"
        )
        let detail = ProcessDetail(pid: 1, parentPID: 0, user: "me", startTime: "Wed Oct 7 17:04:47 2026", command: "")
        let shown = detail.displayStartTime(
            timeZone: TimeZone(identifier: "America/New_York")!,
            locale: Locale(identifier: "en_US")
        )

        // ICU versions differ in the space before PM (U+202F or U+0020).
        XCTAssertEqual(shown.replacingOccurrences(of: "\u{202F}", with: " "), "Oct 7, 2026 at 1:04:47 PM")

        let unparsed = ProcessDetail(pid: 1, parentPID: 0, user: "me", startTime: "unexpected", command: "")
        XCTAssertEqual(unparsed.displayStartTime(), "unexpected UTC")
    }
}
