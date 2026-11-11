import XCTest
@testable import TaskScope

@MainActor
final class Batch01PresetValidationTests: XCTestCase {
    private let suiteName = "TaskScope.Batch01.validation.\(UUID().uuidString)"
    nonisolated(unsafe) private var defaults: InMemoryUserDefaults!
    private let key = "presets"

    override func setUp() {
        super.setUp()
        defaults = InMemoryUserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testUnsafeLabelsAreRejectedByAddEditImportAndStoredRecovery() throws {
        for label in ["/", "/x", "//", "a/b", "/Users/test/Library/LaunchAgents/a.plist",
                      ".agent", "-agent", "_agent", "a b", "a:agent", "é.agent",
                      String(repeating: "a", count: 256)] {
            defaults.removePersistentDomain(forName: suiteName)
            let store = WatchedAppsStore(userDefaults: defaults, key: key)
            var invalid = preset()
            invalid.userLaunchAgentJobs[0].label = label
            let preview = store.previewImport([invalid])
            XCTAssertEqual(preview.importableCount, 0, label)
            XCTAssertTrue(preview.items.first?.rejectionReason?.contains("label") == true, label)
            XCTAssertEqual(store.importPresets([invalid]).importedCount, 0, label)
            XCTAssertFalse(store.add(invalid), label)
            let form = WatchedPresetFormState()
            form.prepareForEditing(invalid)
            XCTAssertThrowsError(try form.makePreset(existing: invalid).get(), label)
            var valid = preset()
            valid.id = invalid.id
            XCTAssertTrue(store.add(valid), label)
            XCTAssertFalse(store.update(invalid), label)
            XCTAssertEqual(store.presets.last, valid)

            let payload = try JSONEncoder().encode([invalid])
            defaults.set(payload, forKey: key)
            let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
            XCTAssertTrue(reloaded.isReadOnlyAfterCorruption, label)
            XCTAssertTrue(reloaded.presets.isEmpty, label)
            XCTAssertEqual(defaults.data(forKey: key), payload)
            XCTAssertEqual(defaults.data(forKey: "\(key).rejectedMigrationBackup"), payload)
        }
    }

    func testControlFormatAndSeparatorScalarsAreRejectedInEveryFieldBeforeNormalization() throws {
        // Inside the value, where trimming cannot remove them.
        let mutations: [(String, (inout WatchedAppPreset, String) -> Void)] = [
            ("Display name", { $0.displayName = "Exa" + $1 + "mple" }),
            ("Main process name", { $0.mainProcessName = "Exa" + $1 + "mple" }),
            ("Helper process name", { $0.helperProcessNames = ["Hel" + $1 + "per"] }),
            ("Protected process name", { $0.protectedProcessNames = ["Pro" + $1 + "tected"] }),
            ("App path", { $0.appPath = "/nonexistent-batch01/Ex" + $1 + "ample.app" }),
            ("Launch agent label", { $0.userLaunchAgentJobs[0].label = "com.example." + $1 + "agent" }),
            ("Launch agent plist path", { $0.userLaunchAgentJobs[0].plistPath = "/nonexistent-batch01/a" + $1 + "gent.plist" })
        ]
        for scalar in ["\0", "\n", "\t", "\u{200B}", "\u{202E}", "\u{2028}", "\u{2029}"] {
            for (field, mutate) in mutations {
                defaults.removePersistentDomain(forName: suiteName)
                let store = WatchedAppsStore(userDefaults: defaults, key: key)
                var invalid = preset()
                mutate(&invalid, scalar)
                let reason = try XCTUnwrap(store.previewImport([invalid]).items.first?.rejectionReason, field)
                XCTAssertTrue(reason.contains(field), reason)
                XCTAssertFalse(store.add(invalid), field)
                XCTAssertEqual(store.importPresets([invalid]).importedCount, 0, field)
                let form = WatchedPresetFormState()
                form.prepareForEditing(invalid)
                XCTAssertThrowsError(try form.makePreset(existing: invalid).get(), field)
                let payload = try JSONEncoder().encode([invalid])
                defaults.set(payload, forKey: key)
                let reloaded = WatchedAppsStore(userDefaults: defaults, key: key)
                XCTAssertTrue(reloaded.isReadOnlyAfterCorruption, field)
                XCTAssertTrue(reloaded.presets.isEmpty, field)
                XCTAssertEqual(defaults.data(forKey: key), payload)
            }
        }
    }

    func testNamesHaveABoundedLengthAndOrdinaryUnicodeAndPathsRemainValid() {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        for field in [\WatchedAppPreset.displayName, \.mainProcessName] {
            var invalid = preset()
            invalid[keyPath: field] = String(repeating: "x", count: 256)
            XCTAssertFalse(store.add(invalid))
        }
        for protected in [false, true] {
            var invalid = preset()
            if protected { invalid.protectedProcessNames = [String(repeating: "x", count: 256)] }
            else { invalid.helperProcessNames = [String(repeating: "x", count: 256)] }
            XCTAssertFalse(store.add(invalid))
        }
        var valid = preset()
        valid.displayName = "Café 工作"
        valid.mainProcessName = String(repeating: "x", count: 255)
        valid.appPath = "/nonexistent-batch01/Work Files/Café.app"
        valid.userLaunchAgentJobs[0].label = "A" + String(repeating: "a", count: 254)
        valid.userLaunchAgentJobs[0].plistPath = "/nonexistent-batch01/Work Files/agent.plist"
        XCTAssertTrue(store.add(valid))
        XCTAssertEqual(store.presets.last, valid)
    }

    func testSurroundingWhitespaceIsStillTrimmedRatherThanRejected() throws {
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var padded = preset()
        padded.displayName = " Example\n"
        padded.mainProcessName = "\tExample "
        padded.helperProcessNames = ["Helper\n"]
        padded.appPath = "/nonexistent-batch01/Example.app\n"
        padded.userLaunchAgentJobs = [.init(label: " com.example.agent\t", plistPath: "/nonexistent-batch01/agent.plist\r\n")]
        XCTAssertTrue(store.add(padded), store.validationError ?? "")
        let stored = try XCTUnwrap(store.presets.last)
        XCTAssertEqual(stored.displayName, "Example")
        XCTAssertEqual(stored.mainProcessName, "Example")
        XCTAssertEqual(stored.helperProcessNames, ["Helper"])
        XCTAssertEqual(stored.appPath, "/nonexistent-batch01/Example.app")
        XCTAssertEqual(stored.userLaunchAgentJobs.map(\.label), ["com.example.agent"])
        XCTAssertEqual(stored.userLaunchAgentJobs.map(\.plistPath), ["/nonexistent-batch01/agent.plist"])
    }

    func testLabelsAcceptLaunchdNamesIncludingVersionedHomebrewServices() {
        for label in ["com.example.Agent_1-2", "homebrew.mxcl.postgresql@14", "0x.agent", "A"] {
            XCTAssertTrue(PresetFieldValidation.isValidLaunchAgentLabel(label), label)
        }
        let store = WatchedAppsStore(userDefaults: defaults, key: key)
        var versioned = preset()
        versioned.userLaunchAgentJobs[0].label = "homebrew.mxcl.postgresql@14"
        XCTAssertTrue(store.add(versioned), store.validationError ?? "")
        XCTAssertEqual(store.presets.last?.userLaunchAgentJobs.map(\.label), ["homebrew.mxcl.postgresql@14"])
    }

    private func preset() -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: "Example", mainProcessName: "Example",
            helperProcessNames: [], protectedProcessNames: [],
            appPath: "/nonexistent-batch01/Example.app",
            userLaunchAgentJobs: [.init(label: "com.example.Agent_1-2", plistPath: "/nonexistent-batch01/agent.plist")]
        )
    }
}
