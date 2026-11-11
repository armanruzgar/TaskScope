import Foundation

/// Character rules for preset fields, shared by the store and the preset form.
/// Each value is checked with its leading and trailing whitespace and newlines
/// removed, because the store trims those before it uses or saves a value.
enum PresetFieldValidation {
    static let maximumNameLength = 255
    static let launchAgentLabelError = "Launch agent labels must start with an ASCII letter or digit, contain only ASCII letters, digits, '.', '-', '_' and '@', and be 255 characters or fewer."

    /// launchctl reads the service name in `gui/<uid>/<label>` only up to the
    /// next '/': a label containing '/' addresses a different service, and one
    /// that starts with '/' addresses the whole login domain. Allow only the
    /// characters launchd labels use ('@' appears in versioned Homebrew
    /// services such as homebrew.mxcl.postgresql@14).
    static func isValidLaunchAgentLabel(_ label: String) -> Bool {
        let bytes = Array(label.utf8)
        guard (1...255).contains(bytes.count), isASCIIAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-")
                || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "@")
        }
    }

    /// Control characters (NUL ends the C string a launchctl command is built
    /// from), invisible format characters such as zero-width spaces and bidi
    /// overrides (text that reads differently from its bytes), and line or
    /// paragraph separators.
    static func textError(in fields: [(name: String, value: String)]) -> String? {
        for field in fields where field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.contains(where: isDisallowed) {
            return "\(field.name) cannot contain control, invisible formatting, or line or paragraph separator characters."
        }
        return nil
    }

    static func error(in preset: WatchedAppPreset) -> String? {
        let names: [(name: String, value: String)] = [
            ("Display name", preset.displayName), ("Main process name", preset.mainProcessName)
        ]
            + preset.helperProcessNames.map { ("Helper process name", $0) }
            + preset.protectedProcessNames.map { ("Protected process name", $0) }
            + preset.systemLaunchDaemonJobs.map { ("Daemon process name", $0.processName) }
        let fields = names + [("App path", preset.appPath)]
            + preset.userLaunchAgentJobs.flatMap { [("Launch agent label", $0.label), ("Launch agent plist path", $0.plistPath)] }
            + preset.systemLaunchDaemonJobs.flatMap { [("Daemon label", $0.label), ("Daemon plist path", $0.plistPath)] }
        if let error = textError(in: fields) { return error }
        for field in names
        where field.value.trimmingCharacters(in: .whitespacesAndNewlines).count > maximumNameLength {
            return "\(field.name) must be \(maximumNameLength) characters or fewer."
        }
        let labels = preset.userLaunchAgentJobs.map(\.label) + preset.systemLaunchDaemonJobs.map(\.label)
        guard labels.allSatisfy({ isValidLaunchAgentLabel($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
            return launchAgentLabelError
        }
        return nil
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
