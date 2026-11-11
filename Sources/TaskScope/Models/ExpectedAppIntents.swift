import Foundation

/// The App Intents types and App Shortcut phrases a correctly packaged
/// TaskScope declares. `script/expected_intents.json` is the one list: the
/// packaging scripts check every staged, installed and released bundle against
/// it, and the app embeds the same file as `sourceJSON`
/// (`script/generate_expected_intents.sh` writes it) for Settings > Health.
struct ExpectedAppIntents: Decodable, Equatable, Sendable {
    struct Shortcut: Decodable, Equatable, Sendable {
        /// The type name of the intent the App Shortcut runs.
        let action: String
        /// Phrase templates as the metadata records them, with
        /// `${applicationName}` and `${<parameter>}` placeholders.
        let phrases: [String]
    }

    /// The `version` that Metadata.appintents/version.json must report.
    let metadataVersion: String
    let actions: [String]
    let entities: [String]
    let queries: [String]
    let shortcuts: [Shortcut]

    /// The embedded list. Nil only if the embedded JSON were malformed, which
    /// ExpectedAppIntentsTests rules out; Health then reports the metadata as
    /// unverified.
    static let current: ExpectedAppIntents? = try? decode(sourceJSON)

    static func decode(_ json: String) throws -> ExpectedAppIntents {
        try JSONDecoder().decode(ExpectedAppIntents.self, from: Data(json.utf8))
    }

    /// Whether extracted metadata (version.json and extract.actionsdata)
    /// matches this list exactly, by the rules that
    /// `taskscope_verify_app_intents_metadata` in script/packaging_common.sh
    /// applies: the format version, exactly the listed actions, entities and
    /// queries, and exactly the listed App Shortcuts, each with its phrases.
    func matches(version: [String: Any], actions extracted: [String: Any]) -> Bool {
        guard version["version"] as? String == metadataVersion,
              let tools = version["toolsVersion"] as? String, !tools.isEmpty else { return false }
        for (group, names) in [("actions", actions), ("entities", entities), ("queries", queries)] {
            let declared = extracted[group] as? [String: Any] ?? [:]
            guard Set(declared.keys) == Set(names) else { return false }
        }
        guard let declared = extracted["autoShortcuts"] as? [[String: Any]],
              declared.count == shortcuts.count else { return false }
        return shortcuts.allSatisfy { shortcut in
            guard let entry = declared.first(where: { $0["actionIdentifier"] as? String == shortcut.action }) else {
                return false
            }
            let templates = entry["phraseTemplates"] as? [[String: Any]] ?? []
            return Set(templates.compactMap { $0["key"] as? String }) == Set(shortcut.phrases)
        }
    }
}
