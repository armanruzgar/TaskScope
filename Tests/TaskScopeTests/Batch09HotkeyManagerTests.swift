import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TaskScope

/// Hotkey fixes. A fake backend stands in for Carbon, so no global hotkey is
/// ever registered, and every manager uses its own in-memory defaults.
@MainActor
final class Batch09HotkeyManagerTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.Batch09.Hotkey.\(UUID().uuidString)"))
    }

    // A02-4: a present field with the wrong type is unreadable data, not an
    // absent field: it is backed up, kept on disk and leaves the hotkey off.
    func testWrongTypedHotkeyFieldsEnterReadOnlyRecovery() throws {
        let valid: [String: Any] = [
            "enabled": false, "keyCode": UInt32(kVK_ANSI_K), "modifiers": UInt32(cmdKey | controlKey)
        ]
        let wrongTyped: [(String, Any)] = [
            ("enabled", "no"), ("enabled", 1), ("keyCode", "40"), ("keyCode", -1),
            ("modifiers", 4352.5), ("modifiers", true), ("migrationNotice", 5)
        ]
        for (key, value) in wrongTyped {
            let defaults = try makeDefaults()
            var stored = valid
            stored[key] = value
            defaults.set(stored, forKey: "hotkey")
            let backend = Batch09HotkeyBackend()
            let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
            manager.register()

            XCTAssertTrue(manager.isReadOnlyAfterCorruption, "\(key) = \(value)")
            XCTAssertFalse(manager.hotkeyEnabled, "\(key) = \(value)")
            XCTAssertFalse(manager.isRegistered, "\(key) = \(value)")
            XCTAssertTrue(backend.events.isEmpty, "\(key) = \(value)")
            XCTAssertNotNil(manager.recoveryMessage, "\(key) = \(value)")
            XCTAssertNotNil(defaults.data(forKey: "hotkey.corruptBackup"), "\(key) = \(value)")
            XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | controlKey)))
            let onDisk = try XCTUnwrap(defaults.dictionary(forKey: "hotkey"))
            XCTAssertTrue((onDisk[key] as? NSObject)?.isEqual(value) == true, "the unreadable value stays: \(key)")
        }

        let defaults = try makeDefaults()
        defaults.set(valid, forKey: "hotkey")
        let readable = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: Batch09HotkeyBackend())
        XCTAssertFalse(readable.isReadOnlyAfterCorruption)
        XCTAssertEqual(readable.displayString, "⌃⌘K")
        XCTAssertFalse(HotkeyManager.hasWrongTypedField(["enabled": true]))
        XCTAssertFalse(HotkeyManager.hasWrongTypedField(["keyCode": 4352.0]))
    }

    // T05-10 (a): the Command-Shift reservations nothing else pinned.
    func testCommandShiftTabAndScreenshotShortcutsAreRefused() {
        let command = UInt32(cmdKey), shift = UInt32(shiftKey)
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_Tab), modifiers: command | shift),
            // T05-10 (lead): the refusal names the combination that was pressed.
            "⌘⇧Tab (app switcher) is reserved by macOS. Choose another combination."
        )
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_Tab), modifiers: command),
            "⌘Tab (app switcher) is reserved by macOS. Choose another combination."
        )
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_3), modifiers: command | shift),
            "⌘⇧3 (screenshots) is reserved by macOS. Choose another combination."
        )
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_5), modifiers: command | shift),
            "⌘⇧5 (screenshots) is reserved by macOS. Choose another combination."
        )
        XCTAssertNil(HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_6), modifiers: command | shift))
    }

    // T05-10 (b): recording while the hotkey is disabled saves the shortcut
    // without registering anything.
    func testRecordingWhileDisabledRegistersNothing() throws {
        let defaults = try makeDefaults()
        defaults.set(["enabled": false], forKey: "hotkey")
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
        manager.register()

        XCTAssertTrue(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))

        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(manager.registrationStatus, .disabled)
        XCTAssertEqual(manager.displayString, "⌃⌘K")
    }

    // T05-10 (c) and A02-11 (4): the handler-install failure branch.
    func testHandlerInstallFailureOnFirstRegistrationLeavesNoHotkey() throws {
        let backend = Batch09HotkeyBackend()
        backend.handlerStatus = OSStatus(eventNotHandledErr)
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)

        manager.register()

        XCTAssertEqual(
            manager.registrationStatus,
            .handlerUnavailable(OSStatus(eventNotHandledErr), previousShortcutRemainsActive: false)
        )
        XCTAssertFalse(manager.isRegistered)
        XCTAssertEqual(backend.events, [])
        XCTAssertEqual(manager.registrationStatus.message, "TaskScope could not activate the global hotkey handler.")
    }

    func testHandlerInstallFailureAfterARegistrationKeepsThePreviousShortcut() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()
        XCTAssertTrue(manager.isRegistered)
        backend.handlerStatus = OSStatus(eventNotHandledErr)

        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))

        XCTAssertEqual(
            manager.registrationStatus,
            .handlerUnavailable(OSStatus(eventNotHandledErr), previousShortcutRemainsActive: true)
        )
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(backend.events, ["register:T"], "the previous registration is never unregistered")
        XCTAssertEqual(manager.displayString, "⌃⌥⌘T")
    }

    // T05-17: combinations every app or terminal relies on are refused.
    func testStandardEditingAndControlKeysAreRefused() {
        let command = UInt32(cmdKey), control = UInt32(controlKey)
        for key in [kVK_ANSI_C, kVK_ANSI_A, kVK_ANSI_E, kVK_ANSI_K, kVK_ANSI_T, kVK_ANSI_Q] {
            XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(key), modifiers: control), "⌃\(key)")
        }
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_ANSI_C), modifiers: control),
            "⌃C (terminal and text-editing control key) is reserved by macOS. Choose another combination."
        )
        for key in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Delete, kVK_ForwardDelete,
                    kVK_Return, kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_9] {
            XCTAssertFalse(HotkeyManager.isSupported(keyCode: UInt32(key), modifiers: command), "⌘\(key)")
        }
        XCTAssertEqual(
            HotkeyManager.validationFailure(keyCode: UInt32(kVK_Delete), modifiers: command),
            "⌘Delete (standard app shortcut) is reserved by macOS. Choose another combination."
        )
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_C), modifiers: control | UInt32(shiftKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_LeftArrow), modifiers: command | control))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_1), modifiers: command | UInt32(optionKey)))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_F5), modifiers: control))
        XCTAssertTrue(HotkeyManager.isSupported(keyCode: UInt32(kVK_ANSI_T), modifiers: control | UInt32(optionKey) | command))
    }

    func testASavedControlLetterHotkeyMigratesWithANotice() throws {
        let defaults = try makeDefaults()
        defaults.set(["enabled": true, "keyCode": UInt32(kVK_ANSI_C), "modifiers": UInt32(controlKey)], forKey: "hotkey")

        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: Batch09HotkeyBackend())

        XCTAssertEqual(manager.displayString, "⌃⌥⌘T")
        XCTAssertTrue(manager.migrationNotice?.contains("Your saved shortcut ⌃C is no longer supported.") == true)
        XCTAssertTrue(manager.migrationNotice?.contains("terminal and text-editing control key") == true)
    }

    // A02-3: starting a new recording clears a conflict status that only
    // described an earlier, refused recording.
    func testStartingANewRecordingClearsTheStaleConflictStatus() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()
        backend.refusedKeyCodes = [UInt32(kVK_ANSI_K)]
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))
        XCTAssertEqual(
            manager.registrationStatus,
            .conflict(OSStatus(eventHotKeyExistsErr), previousShortcutRemainsActive: true)
        )

        manager.clearRecordingError()

        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertTrue(manager.isRegistered)
    }

    func testStartingARecordingKeepsAConflictWhenNoShortcutIsActive() throws {
        let backend = Batch09HotkeyBackend()
        backend.refusedKeyCodes = [UInt32(kVK_ANSI_T)]
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        manager.register()
        XCTAssertEqual(
            manager.registrationStatus,
            .conflict(OSStatus(eventHotKeyExistsErr), previousShortcutRemainsActive: false)
        )

        manager.clearRecordingError()

        XCTAssertEqual(
            manager.registrationStatus,
            .conflict(OSStatus(eventHotKeyExistsErr), previousShortcutRemainsActive: false),
            "the status still describes the real state"
        )
    }

    // A02-1: the registered hotkey is paused while recording and comes back
    // on every exit path.
    func testRecordingPausesTheHotkeyAndCancellingRestoresIt() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()

        manager.beginRecording()
        XCTAssertFalse(manager.isRegistered, "pressing the current shortcut must reach the recorder")
        manager.register()
        XCTAssertFalse(manager.isRegistered, "nothing re-registers while the recorder listens")
        manager.endRecording()

        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertNil(manager.lastRecordingError)
        XCTAssertEqual(backend.events, ["register:T", "unregister", "register:T"])
        manager.endRecording()
        XCTAssertEqual(backend.events.count, 3, "ending twice changes nothing")
    }

    func testRecordingANewShortcutWhilePausedKeepsIt() throws {
        let backend = Batch09HotkeyBackend()
        let defaults = try makeDefaults()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()

        manager.beginRecording()
        XCTAssertTrue(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))
        manager.endRecording()

        XCTAssertEqual(manager.displayString, "⌃⌘K")
        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertEqual(backend.events, ["register:T", "unregister", "register:K"])
        XCTAssertEqual(defaults.dictionary(forKey: "hotkey")?["keyCode"] as? UInt32, UInt32(kVK_ANSI_K))
    }

    func testRecordingTheCurrentShortcutWhilePausedKeepsIt() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()

        manager.beginRecording()
        XCTAssertTrue(manager.updateShortcut(
            keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey)
        ))
        manager.endRecording()

        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertEqual(backend.events, ["register:T", "unregister", "register:T"])
    }

    func testARefusedRecordingRestoresThePreviousShortcutAndSaysWhy() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()
        backend.refusedKeyCodes = [UInt32(kVK_ANSI_K)]

        manager.beginRecording()
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | controlKey)))
        manager.endRecording()

        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(manager.displayString, "⌃⌥⌘T")
        XCTAssertEqual(manager.registrationStatus, .registered)
        XCTAssertEqual(manager.lastRecordingError, "That shortcut is unavailable. The previous shortcut remains active.")
        XCTAssertEqual(backend.events, ["register:T", "unregister", "register:K", "register:T"])
    }

    func testAValidationRefusalWhilePausedIsKeptAfterResuming() throws {
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: try makeDefaults(), defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()

        manager.beginRecording()
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey)))
        manager.endRecording()

        XCTAssertTrue(manager.isRegistered)
        XCTAssertTrue(manager.lastRecordingError?.contains("⌃C") == true)
    }
}
