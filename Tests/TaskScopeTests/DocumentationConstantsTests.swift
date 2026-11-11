import Carbon.HIToolbox
import Foundation
import XCTest
@testable import TaskScope

/// L07-17: the documents restate some of the code's values (how long Stop
/// waits, how long TaskScope watches GlobalProtect disconnect, how many events
/// and samples it keeps, the default shortcut, the one accepted URL). Each
/// phrase below is built from the code value and must appear in its document,
/// so changing a value fails here until every copy says the same. Phrases are
/// short on purpose, so rewording around them does not break the test.
/// Released CHANGELOG sections are history and are not checked.
@MainActor
final class DocumentationConstantsTests: XCTestCase {
    func testDocumentsStateTheCodeValues() throws {
        for (file, phrases) in Self.expectations() {
            let text = try Self.document(file)
            for phrase in phrases {
                XCTAssertTrue(text.contains(phrase), "\(file) does not say “\(phrase)”; update the document or the code value")
            }
        }
    }

    func testPhrasesFollowTheCodeValues() {
        // Guards the helpers below, so a check cannot pass by building every
        // phrase from a wrong value.
        XCTAssertEqual(Self.words(3), "three")
        XCTAssertEqual(Self.words(5), "five")
        XCTAssertEqual(Self.seconds(0.5), "0.5")
        XCTAssertEqual(Self.seconds(90), "90")
        XCTAssertEqual(Self.spokenShortcut, "Control-Option-Command-T")
        XCTAssertEqual(HotkeyManager.defaultDisplayString, "⌃⌥⌘T")
    }

    // MARK: Expectations

    private static func expectations() -> [(file: String, phrases: [String])] {
        let grace = Int(ProcessTerminationController.gracefulExitWindowSeconds)
        let observations = GlobalProtectDisconnectController.defaultObservationLimit
        let streak = GlobalProtectDisconnectController.requiredDisconnectedObservations
        let wait = GlobalProtectAccessibilityRuntime.observationInterval
        let window = Int((Double(observations) * wait).rounded())
        let deadline = seconds(GlobalProtectDisconnectDeadline.defaultTimeLimit)
        let events = AutoStopRulesStore.defaultEventLimit
        let samples = ProcessHistory.defaultMaxSamples
        let shortcut = HotkeyManager.defaultDisplayString
        let url = TaskScopeURLParser.refreshURL
        return [
            ("README.md", [
                "Stop waits up to \(words(grace)) seconds",
                "\(spokenShortcut) (\(shortcut))",
                "`\(url)`"
            ]),
            ("docs/USING_TASKSCOPE.md", [
                "wait up to \(words(grace)) seconds",
                "at most \(events) records",
                "holds \(samples) samples",
                "\(spokenShortcut) by default",
                "shortcut is \(shortcut)"
            ]),
            ("docs/AUTOMATION.md", [
                "\(words(grace)) seconds after the stop request",
                "open \"\(url)\""
            ]),
            ("docs/GLOBALPROTECT.md", [
                "\(words(streak)) consecutive disconnected observations",
                "about \(window) seconds",
                "up to \(observations) observations",
                "waits of \(seconds(wait)) seconds",
                "\(deadline)-second overall deadline"
            ]),
            ("THREAT_MODEL.md", [
                "graceful window (\(grace) seconds)",
                "\(words(streak).capitalized) consecutive disconnected observations",
                "Up to \(observations) observations",
                "\(seconds(wait))-second waits",
                "about \(window) seconds",
                "\(deadline)-second overall deadline",
                "`\(url)`"
            ]),
            ("PRIVACY.md", [
                "newest \(events) records",
                "at most \(samples) samples"
            ]),
            ("SUPPORT.md", [
                "\(events)-record limit",
                "default \(shortcut) shortcut"
            ])
        ]
    }

    // MARK: Helpers

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The document with every run of whitespace, line breaks included, made
    /// one space, so a phrase may wrap across lines.
    private static func document(_ path: String) throws -> String {
        let text = try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func words(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    /// 90 → "90", 0.5 → "0.5".
    private static func seconds(_ value: TimeInterval) -> String {
        value.rounded() == value ? "\(Int(value))" : "\(value)"
    }

    /// The default shortcut as the documents spell it out.
    private static var spokenShortcut: String {
        let modifiers = HotkeyManager.defaultModifiers
        var names: [String] = []
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        names.append(HotkeyManager.keyName(for: HotkeyManager.defaultKeyCode) ?? "?")
        return names.joined(separator: "-")
    }
}
