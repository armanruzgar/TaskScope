import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TaskScope

@MainActor
final class Batch09HotkeyBackend: HotkeyRegistrationBackend {
    private(set) var events: [String] = []
    var refusedKeyCodes: Set<UInt32> = []
    var handlerStatus: OSStatus = noErr
    private var nextReference = 1

    func installEventHandler(for manager: HotkeyManager) -> OSStatus {
        handlerStatus
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (status: OSStatus, reference: EventHotKeyRef?) {
        events.append("register:\(HotkeyManager.keyName(for: keyCode) ?? "?")")
        guard !refusedKeyCodes.contains(keyCode) else {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        let reference = OpaquePointer(bitPattern: nextReference)!
        nextReference += 1
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) {
        events.append("unregister")
    }
}
