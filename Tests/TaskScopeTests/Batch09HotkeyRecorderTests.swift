import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TaskScope

/// The recorder's event decisions and the observers that end a recording.
@MainActor
final class Batch09HotkeyRecorderTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    // A02-1: only keystrokes in the recorder's own window are captured.
    func testKeystrokesInOtherWindowsPassThrough() {
        let recorder = makeWindow()
        let other = makeWindow()
        let commandLeft = HotkeyRecordingInput.action(
            keyCode: UInt16(kVK_LeftArrow), modifierFlags: [.command], eventWindow: other, recorderWindow: recorder
        )
        let escape = HotkeyRecordingInput.action(
            keyCode: UInt16(kVK_Escape), modifierFlags: [], eventWindow: other, recorderWindow: recorder
        )
        let noWindow = HotkeyRecordingInput.action(
            keyCode: UInt16(kVK_ANSI_A), modifierFlags: [.control], eventWindow: nil, recorderWindow: recorder
        )
        let unknownRecorder = HotkeyRecordingInput.action(
            keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.command], eventWindow: other, recorderWindow: nil
        )
        XCTAssertEqual(commandLeft, .passThrough)
        XCTAssertEqual(escape, .passThrough)
        XCTAssertEqual(noWindow, .passThrough)
        XCTAssertEqual(unknownRecorder, .passThrough)
    }

    func testKeystrokesInTheRecorderWindowAreRecordedOrCancel() {
        let recorder = makeWindow()
        func action(_ key: Int, _ flags: NSEvent.ModifierFlags) -> HotkeyRecordingInput.Action {
            HotkeyRecordingInput.action(
                keyCode: UInt16(key), modifierFlags: flags, eventWindow: recorder, recorderWindow: recorder
            )
        }
        XCTAssertEqual(action(kVK_Escape, []), .cancel)
        XCTAssertEqual(action(kVK_ANSI_A, []), .passThrough, "ordinary typing is not a shortcut")
        XCTAssertEqual(action(kVK_ANSI_A, [.shift]), .record(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)))
        XCTAssertEqual(
            action(kVK_ANSI_K, [.command, .shift, .capsLock]),
            .record(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
        )
        XCTAssertEqual(
            action(kVK_ANSI_T, [.control, .option, .command]),
            .record(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey | cmdKey))
        )
    }

    // A02-1: the recorder window resigning key or closing cancels recording;
    // other windows do not, and stopping always resumes the hotkey once.
    func testRecorderWindowLosingFocusOrClosingCancelsRecording() {
        let recorder = makeWindow()
        let other = makeWindow()
        let coordinator = HotkeyRecorderCoordinator()
        var events: [String] = []

        coordinator.start(
            recorderWindow: recorder,
            onRecord: { _, _ in events.append("record") },
            onCancel: { events.append("cancel") },
            onStart: { events.append("start") },
            onFinish: { events.append("finish") },
            installsEventMonitors: false
        )
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertEqual(events, ["start"])

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: recorder)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: recorder)
        XCTAssertEqual(events, ["start", "cancel", "cancel"])

        coordinator.stop()
        coordinator.stop()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: recorder)
        XCTAssertEqual(events, ["start", "cancel", "cancel", "finish"])
        XCTAssertFalse(coordinator.isRecording)
    }

    func testStartingTwiceDoesNotPauseTwice() {
        let coordinator = HotkeyRecorderCoordinator()
        var starts = 0
        for _ in 0..<2 {
            coordinator.start(
                recorderWindow: makeWindow(), onRecord: { _, _ in }, onCancel: {},
                onStart: { starts += 1 }, installsEventMonitors: false
            )
        }
        coordinator.stop()
        XCTAssertEqual(starts, 1)
    }

    // The recorder wiring end to end: starting pauses the hotkey, stopping
    // resumes it.
    func testCoordinatorPausesAndResumesTheManager() throws {
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.Batch09.Recorder.\(UUID().uuidString)"))
        let backend = Batch09HotkeyBackend()
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
        defer { manager.unregister() }
        manager.register()
        let coordinator = HotkeyRecorderCoordinator()

        coordinator.start(
            recorderWindow: makeWindow(), onRecord: { _, _ in }, onCancel: {},
            onStart: { manager.beginRecording() }, onFinish: { manager.endRecording() },
            installsEventMonitors: false
        )
        XCTAssertFalse(manager.isRegistered)
        coordinator.stop()

        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(backend.events, ["register:T", "unregister", "register:T"])
    }
}
