import Carbon.HIToolbox
@testable import TaskScope

/// A hotkey backend that registers nothing with Carbon: it records the
/// registration traffic and hands out distinct fake references.
@MainActor
final class RecordingHotkeyBackend: HotkeyRegistrationBackend {
    private(set) var events: [String] = []
    /// Key codes whose registration fails as if another app owned them.
    var refusedKeyCodes: Set<UInt32> = []
    /// What installing the event handler returns.
    var installStatus: OSStatus = noErr
    private var nextReference = 1

    func installEventHandler(for manager: HotkeyManager) -> OSStatus {
        events.append("install")
        return installStatus
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (status: OSStatus, reference: EventHotKeyRef?) {
        events.append("register:\(HotkeyManager.keyName(for: keyCode) ?? "?"):\(modifiers)")
        guard !refusedKeyCodes.contains(keyCode) else {
            return (OSStatus(eventHotKeyExistsErr), nil)
        }
        let reference = OpaquePointer(bitPattern: nextReference)!
        nextReference += 1
        return (noErr, reference)
    }

    func unregister(_ reference: EventHotKeyRef) {
        events.append("unregister:\(Int(bitPattern: UnsafeRawPointer(reference)))")
    }
}
