import AppKit
import OSLog
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

// Regression tests for audit batch 2: the URL scheme, accessibility labels, the
// Keep Off card in settings recovery, scene titles, persisted list options,
// the registry of running shell commands, and the action log.

// MARK: - URL scheme (A01-15, T05-3)

@MainActor
final class Batch02URLSchemeTests: XCTestCase {
    private var submitted: [TaskScopeCommand] = []
    private var prepared: [TaskScopeCommand] = []

    private func makeHandler() -> URLSchemeHandler {
        URLSchemeHandler(
            submitCommand: { [unowned self] command in
                submitted.append(command)
                return TaskScopeCommandResult(status: .completed, message: "done")
            },
            willHandleCommand: { [unowned self] in prepared.append($0) }
        )
    }

    /// A01-15: only the literal string the docs and the error text promise is
    /// accepted. Case, percent-encoded, empty-port and IDNA-mapped spellings
    /// (which `URL(string:)` would normalize to the host "refresh") are refused.
    func testOnlyTheExactRefreshURLReachesTheCommandBus() async throws {
        let handler = makeHandler()
        let variants = [
            "TASKSCOPE://refresh",
            "TaskScope://refresh",
            "taskscope://%72efresh",
            "taskscope://%72%65%66%72%65%73%68",
            "taskscope://refresh:",
            "taskscope://\u{FF52}efresh",
            "taskscope://\u{FF32}\u{FF25}\u{FF26}\u{FF32}\u{FF25}\u{FF33}\u{FF28}",
            "taskscope://re\u{00AD}fresh"
        ]
        for value in variants {
            try Self.deliverGetURLEvent(value, to: handler)
            // URL(string:) already maps the IDNA spellings to the canonical URL,
            // so for those only the raw string the Apple Event carries can tell.
            if value.unicodeScalars.allSatisfy(\.isASCII), let url = URL(string: value) {
                XCTAssertNotEqual(TaskScopeURLParser.command(from: url), .success(.refresh), Self.escaped(value))
            }
        }
        try Self.deliverGetURLEvent("taskscope://refresh", to: handler)
        for _ in 0..<200 where submitted.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(submitted, [.refresh], "Only the canonical URL submits refresh")
        XCTAssertEqual(prepared, [.refresh])
        XCTAssertEqual(
            TaskScopeURLParser.command(from: try XCTUnwrap(URL(string: "taskscope://refresh"))),
            .success(.refresh)
        )
    }

    /// T05-3: the handler, not only the parser, refuses destructive, foreign and
    /// malformed URLs without submitting a command or touching launch policy.
    func testHandlerRejectsDestructiveForeignAndMalformedURLsWithoutSideEffects() async throws {
        let handler = makeHandler()
        for value in [
            "taskscope://stop/GlobalProtect",
            "taskscope://open/GlobalProtect",
            "taskscope://quit",
            "taskscope://refresh/GlobalProtect",
            "http://refresh",
            "https://refresh",
            "x-taskscope://refresh"
        ] {
            let result = await handler.handle(try XCTUnwrap(URL(string: value)))
            XCTAssertNil(result, "handle(\(value)) must reject")
        }
        XCTAssertEqual(
            TaskScopeURLParser.command(from: try XCTUnwrap(URL(string: "http://refresh"))),
            .failure(.invalidScheme)
        )
        XCTAssertEqual(submitted, [], "A rejected URL must not submit a command")
        XCTAssertEqual(prepared, [], "A rejected URL must not reach the launch policy")

        try Self.deliverGetURLEvent("", to: handler)
        try Self.deliverGetURLEvent(nil, to: handler)
        try Self.deliverGetURLEvent("taskscope://stop/GlobalProtect", to: handler)
        try Self.deliverGetURLEvent("http://refresh", to: handler)
        try Self.deliverGetURLEvent("taskscope://refresh", to: handler)
        for _ in 0..<200 where submitted.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(submitted, [.refresh])
        XCTAssertEqual(prepared, [.refresh])
    }

    private static func escaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            scalar.isASCII ? String(scalar) : String(format: "\\u{%04X}", scalar.value)
        }.joined()
    }

    /// Calls the selector `register()` installs for kAEGetURL, with an event
    /// built the way Launch Services delivers a URL open. Nothing leaves this
    /// test process.
    private static func deliverGetURLEvent(_ value: String?, to handler: URLSchemeHandler) throws {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let value {
            event.setParam(NSAppleEventDescriptor(string: value), forKeyword: keyDirectObject)
        }
        let selector = NSSelectorFromString("handleURLEvent:replyEvent:")
        let method = try XCTUnwrap(class_getInstanceMethod(URLSchemeHandler.self, selector))
        typealias EventHandler = @convention(c) (
            AnyObject, Selector, NSAppleEventDescriptor, NSAppleEventDescriptor
        ) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: EventHandler.self)
        implementation(handler, selector, event, NSAppleEventDescriptor.null())
    }
}
