import AppIntents
import XCTest
@testable import TaskScope

extension ExpectedAppIntents {
    /// Extracted metadata in the format Metadata.appintents uses, declaring
    /// exactly this list: what a correctly packaged bundle contains.
    func extractedMetadata(toolsVersion: String = "fixture") -> (version: [String: Any], actions: [String: Any]) {
        func entries(_ names: [String]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: names.map { ($0, ["identifier": $0] as [String: Any]) })
        }
        let shortcutEntries: [[String: Any]] = shortcuts.map { shortcut in
            [
                "actionIdentifier": shortcut.action,
                "phraseTemplates": shortcut.phrases.map { ["alternatives": [String](), "key": $0] as [String: Any] }
            ]
        }
        return (
            ["version": metadataVersion, "toolsVersion": toolsVersion],
            ["actions": entries(actions), "entities": entries(entities), "queries": entries(queries),
             // Metadata lists enums as an array of descriptions, not by key.
             "enums": enums.map { ["identifier": $0, "cases": [Any]()] as [String: Any] },
             "autoShortcuts": shortcutEntries]
        )
    }
}

/// L07-15: script/expected_intents.json is the one list of App Intents names
/// and App Shortcut phrases. The packaging scripts read it; the app embeds it.
@available(macOS 13.0, *)
final class ExpectedAppIntentsTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEmbeddedListIsTheCheckedInJSONFile() throws {
        let file = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("script/expected_intents.json"), encoding: .utf8
        )
        XCTAssertEqual(ExpectedAppIntents.sourceJSON + "\n", file,
                       "Run script/generate_expected_intents.sh after changing script/expected_intents.json.")
    }

    func testListIsWellFormed() throws {
        let expected = try XCTUnwrap(ExpectedAppIntents.current, "The embedded list does not decode.")
        XCTAssertEqual(expected, try ExpectedAppIntents.decode(ExpectedAppIntents.sourceJSON))
        XCTAssertFalse(expected.metadataVersion.isEmpty)
        for (group, names) in [("actions", expected.actions), ("entities", expected.entities),
                               ("queries", expected.queries), ("enums", expected.enums)] {
            XCTAssertFalse(names.isEmpty, group)
            XCTAssertEqual(Set(names).count, names.count, "\(group) lists a name twice")
        }
        XCTAssertEqual(Set(expected.shortcuts.map(\.action)).count, expected.shortcuts.count,
                       "Each action has one App Shortcut")
        for shortcut in expected.shortcuts {
            XCTAssertTrue(expected.actions.contains(shortcut.action), shortcut.action)
            XCTAssertFalse(shortcut.phrases.isEmpty, shortcut.action)
            for phrase in shortcut.phrases {
                // App Intents rejects an App Shortcut phrase without the app's name.
                XCTAssertTrue(phrase.contains("${applicationName}"), phrase)
            }
        }
    }

    func testListMatchesTheDeclaredAppShortcuts() throws {
        let expected = try XCTUnwrap(ExpectedAppIntents.current)
        let declared = try TaskScopeShortcuts.appShortcuts.map(Self.reflect)
        XCTAssertEqual(declared.map(\.action), expected.shortcuts.map(\.action))
        XCTAssertEqual(declared.map(\.phrases), expected.shortcuts.map(\.phrases))
        for (action, _) in declared {
            XCTAssertTrue(expected.actions.contains(action), "\(action) runs from an App Shortcut but is not listed")
        }
    }

    func testMatchingAcceptsExactlyTheListedNamesAndPhrases() throws {
        let expected = try XCTUnwrap(ExpectedAppIntents.current)
        let metadata = expected.extractedMetadata()
        XCTAssertTrue(expected.matches(version: metadata.version, actions: metadata.actions))
        XCTAssertTrue(InstallationHealthProbe.validMetadata(version: metadata.version, actions: metadata.actions))
        XCTAssertFalse(InstallationHealthProbe.validMetadata(
            version: metadata.version, actions: metadata.actions, expected: nil
        ))

        var version = metadata.version
        version["version"] = "4.0"
        XCTAssertFalse(expected.matches(version: version, actions: metadata.actions), "other format version")
        version = metadata.version
        version["toolsVersion"] = ""
        XCTAssertFalse(expected.matches(version: version, actions: metadata.actions), "no tools version")

        func rejects(_ description: String, _ change: (inout [String: Any]) -> Void) {
            var actions = metadata.actions
            change(&actions)
            XCTAssertFalse(expected.matches(version: metadata.version, actions: actions), description)
        }
        func group(_ name: String, _ change: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
            { actions in
                var entries = actions[name] as? [String: Any] ?? [:]
                change(&entries)
                actions[name] = entries
            }
        }
        rejects("missing action", group("actions") { $0.removeValue(forKey: expected.actions[0]) })
        rejects("unlisted action", group("actions") { $0["UnlistedIntent"] = [String: Any]() })
        rejects("unlisted entity", group("entities") { $0["UnlistedEntity"] = [String: Any]() })
        let enums = try XCTUnwrap(metadata.actions["enums"] as? [[String: Any]])
        rejects("missing enum") { $0["enums"] = Array(enums.dropFirst()) }
        rejects("unlisted enum") { $0["enums"] = enums + [["identifier": "UnlistedEnum"]] }
        rejects("enum without an identifier") { $0["enums"] = enums + [["cases": [Any]()]] }
        rejects("a group of the wrong type") { $0["actions"] = "not a group" }
        rejects("missing query", group("queries") { $0.removeValue(forKey: expected.queries[0]) })
        rejects("no queries") { $0.removeValue(forKey: "queries") }
        rejects("no App Shortcuts") { $0.removeValue(forKey: "autoShortcuts") }

        let shortcuts = try XCTUnwrap(metadata.actions["autoShortcuts"] as? [[String: Any]])
        func shortcutsChange(_ change: @escaping (inout [[String: Any]]) -> Void) -> (inout [String: Any]) -> Void {
            { actions in
                var entries = shortcuts
                change(&entries)
                actions["autoShortcuts"] = entries
            }
        }
        rejects("missing App Shortcut", shortcutsChange { $0.removeLast() })
        rejects("extra App Shortcut", shortcutsChange { $0.append($0[0]) })
        rejects("missing phrase", shortcutsChange { $0[0]["phraseTemplates"] = [[String: Any]]() })
        rejects("extra phrase", shortcutsChange {
            var templates = $0[0]["phraseTemplates"] as? [[String: Any]] ?? []
            templates.append(["key": "Extra ${applicationName}"])
            $0[0]["phraseTemplates"] = templates
        })
        if shortcuts.count > 1 {
            rejects("phrases swapped between actions", shortcutsChange {
                let first = $0[0]["phraseTemplates"]
                $0[0]["phraseTemplates"] = $0[1]["phraseTemplates"]
                $0[1]["phraseTemplates"] = first
            })
        }
    }

    private struct ReflectionFailure: Error, CustomStringConvertible {
        var description: String {
            "AppShortcut no longer exposes its intent and phrase templates by reflection; update ExpectedAppIntentsTests.reflect."
        }
    }

    func testGroupsDeclareNamesByKeyOrByIdentifier() {
        XCTAssertEqual(ExpectedAppIntents.declaredNames(nil), [])
        XCTAssertEqual(ExpectedAppIntents.declaredNames(["A": [String: Any](), "B": 1]), ["A", "B"])
        XCTAssertEqual(ExpectedAppIntents.declaredNames([["identifier": "A"], ["identifier": "B"]]), ["A", "B"])
        XCTAssertEqual(ExpectedAppIntents.declaredNames([[String: Any]]()), [])
        XCTAssertNil(ExpectedAppIntents.declaredNames([["identifier": "A"], ["name": "B"]]))
        XCTAssertNil(ExpectedAppIntents.declaredNames("A"))
    }

    /// AppShortcut has no public accessors, so read the intent type and phrase
    /// templates by reflection. A failure here means the AppIntents layout
    /// changed; update this helper rather than the list.
    private static func reflect(_ shortcut: AppShortcut) throws -> (action: String, phrases: [String]) {
        guard let intent = firstDescendant(of: shortcut, matching: { $0 is any AppIntent }),
              let phrases = firstDescendant(of: shortcut, labelled: "basePhraseTemplates") as? [String] else {
            throw ReflectionFailure()
        }
        return (String(describing: type(of: intent)), phrases)
    }

    private static func firstDescendant(of value: Any, labelled label: String) -> Any? {
        firstDescendant(of: value, depth: 4, where: { child in child.label == label })
    }

    private static func firstDescendant(of value: Any, matching predicate: (Any) -> Bool) -> Any? {
        firstDescendant(of: value, depth: 4, where: { child in predicate(child.value) })
    }

    /// Breadth first by level, so a shallow match wins over a nested one.
    private static func firstDescendant(
        of value: Any, depth: Int, where matches: (Mirror.Child) -> Bool
    ) -> Any? {
        let children = Mirror(reflecting: value).children
        if let match = children.first(where: matches) {
            return match.value
        }
        guard depth > 0 else { return nil }
        for child in children {
            if let match = firstDescendant(of: child.value, depth: depth - 1, where: matches) {
                return match
            }
        }
        return nil
    }
}
