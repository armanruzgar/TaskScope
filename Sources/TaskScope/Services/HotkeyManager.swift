import AppKit
import Carbon.HIToolbox

/// The Carbon calls behind hotkey registration, injectable for tests.
protocol HotkeyRegistrationBackend {
    @MainActor func installEventHandler(for manager: HotkeyManager) -> OSStatus
    @MainActor func register(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (status: OSStatus, reference: EventHotKeyRef?)
    @MainActor func unregister(_ reference: EventHotKeyRef)
}

/// The real Carbon registration calls. Stateless, so it is safe to share.
struct CarbonHotkeyRegistrationBackend: HotkeyRegistrationBackend {
    @MainActor func installEventHandler(for manager: HotkeyManager) -> OSStatus {
        manager.installCarbonEventHandlerIfNeeded()
    }

    @MainActor func register(
        keyCode: UInt32,
        modifiers: UInt32,
        identifier: EventHotKeyID
    ) -> (status: OSStatus, reference: EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        return (status, reference)
    }

    @MainActor func unregister(_ reference: EventHotKeyRef) {
        UnregisterEventHotKey(reference)
    }
}

@MainActor
final class HotkeyManager: ObservableObject {
    /// The shortcut TaskScope starts with, and returns to after a reset or an
    /// unsupported saved shortcut: ⌃⌥⌘T. README.md, SUPPORT.md and
    /// docs/USING_TASKSCOPE.md state it.
    nonisolated static let defaultKeyCode = UInt32(kVK_ANSI_T)
    nonisolated static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    nonisolated static var defaultDisplayString: String {
        displayString(keyCode: defaultKeyCode, modifiers: defaultModifiers)
    }

    enum RegistrationStatus: Equatable {
        case disabled
        case registered
        case conflict(OSStatus, previousShortcutRemainsActive: Bool)
        case handlerUnavailable(OSStatus, previousShortcutRemainsActive: Bool)
        /// The combination was refused; the payload explains why.
        case unsupported(String)

        var message: String {
            switch self {
            case .disabled: "Hotkey is disabled."
            case .registered: "Hotkey is registered."
            case .conflict(_, let previousShortcutRemainsActive):
                previousShortcutRemainsActive
                    ? "That shortcut is unavailable. The previous shortcut remains active."
                    : "That shortcut is unavailable. No global hotkey is currently active."
            case .handlerUnavailable(_, let previousShortcutRemainsActive):
                previousShortcutRemainsActive
                    ? "TaskScope could not activate the new hotkey handler. The previous shortcut remains active."
                    : "TaskScope could not activate the global hotkey handler."
            case .unsupported(let reason): reason
            }
        }
    }

    static let shared = HotkeyManager()

    @Published var hotkeyEnabled: Bool {
        didSet {
            save()
            register()
        }
    }
    @Published private(set) var keyCode: UInt32
    @Published private(set) var modifiers: UInt32
    @Published private(set) var registrationStatus: RegistrationStatus = .disabled
    @Published private(set) var migrationNotice: String?
    @Published private(set) var lastRecordingError: String?
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var isReadOnlyAfterCorruption = false

    var onShow: (() -> Void)?

    nonisolated(unsafe) private var hotkeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private let defaults: UserDefaults
    private let defaultsKey: String
    private let backend: any HotkeyRegistrationBackend
    /// True while the Settings recorder listens for a new combination. The
    /// registered hotkey is paused, so pressing it is recorded instead of
    /// showing the main window.
    private var recordingPaused = false
    /// Carbon refused the combination recorded while paused.
    private var registrationRefusedWhileRecording = false
    private var nextRegistrationID: UInt32 = 1
    /// The combination `hotkeyRef` currently stands for.
    private var registeredShortcut: (keyCode: UInt32, modifiers: UInt32)?

    init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "TaskScope.hotkey.v1",
        backend: any HotkeyRegistrationBackend = CarbonHotkeyRegistrationBackend()
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.backend = backend
        let stored = defaults.object(forKey: defaultsKey)
        let saved = stored as? [String: Any]
        hotkeyEnabled = saved?["enabled"] as? Bool ?? true
        keyCode = (saved?["keyCode"] as? UInt32) ?? Self.defaultKeyCode
        modifiers = (saved?["modifiers"] as? UInt32) ?? Self.defaultModifiers
        migrationNotice = saved?["migrationNotice"] as? String
        // A field that is present with the wrong type is unreadable data, like
        // a value that is not a dictionary: it is backed up and the hotkey
        // stays off until an explicit reset. Absent fields take defaults.
        if let stored, saved.map(Self.hasWrongTypedField) ?? true {
            isReadOnlyAfterCorruption = true
            hotkeyEnabled = false
            let baseKey = "\(defaultsKey).corruptBackup"
            if let data = try? PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0) {
                let backupKey = PersistenceRecovery.preserveBackup(data, in: defaults, baseKey: baseKey)
                recoveryMessage = PersistenceRecovery.unreadableDataMessage(
                    backupKey: backupKey ?? baseKey,
                    isPreserved: backupKey != nil
                )
            } else {
                recoveryMessage = "Unreadable hotkey settings remain at \(defaultsKey); a backup could not be created."
            }
        } else if let reason = Self.validationFailure(keyCode: keyCode, modifiers: modifiers) {
            let previousShortcut = displayString
            keyCode = Self.defaultKeyCode
            modifiers = Self.defaultModifiers
            migrationNotice = "Your saved shortcut \(previousShortcut) is no longer supported. \(reason) TaskScope changed it to \(Self.defaultDisplayString)."
            save()
        }
    }

    static func hasWrongTypedField(_ saved: [String: Any]) -> Bool {
        func isBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        func isUInt32(_ value: Any) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return UInt32(exactly: number.doubleValue) != nil
        }
        if let value = saved["enabled"], !isBoolean(value) { return true }
        if let value = saved["keyCode"], !isUInt32(value) { return true }
        if let value = saved["modifiers"], !isUInt32(value) { return true }
        if let value = saved["migrationNotice"], !(value is String) { return true }
        return false
    }

    deinit {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register() {
        lastRecordingError = nil
        guard hotkeyEnabled, !isReadOnlyAfterCorruption, !recordingPaused else {
            unregister()
            registrationStatus = .disabled
            return
        }
        if let reason = Self.validationFailure(keyCode: keyCode, modifiers: modifiers) {
            registrationStatus = .unsupported(reason)
            return
        }
        _ = registerCandidate(keyCode: keyCode, modifiers: modifiers)
    }

    @discardableResult
    func updateShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        lastRecordingError = nil
        guard !isReadOnlyAfterCorruption else { return false }
        if let reason = Self.validationFailure(keyCode: keyCode, modifiers: modifiers) {
            lastRecordingError = reason
            return false
        }

        if hotkeyEnabled, !registerCandidate(keyCode: keyCode, modifiers: modifiers) {
            if recordingPaused { registrationRefusedWhileRecording = true }
            return false
        }

        self.keyCode = keyCode
        self.modifiers = modifiers
        migrationNotice = nil
        save()
        return true
    }

    /// Called when a new recording starts. A refused recording left the
    /// previous shortcut active with an orange conflict status; that status is
    /// stale once the user moves on, like the recording error itself.
    func clearRecordingError() {
        lastRecordingError = nil
        guard hotkeyRef != nil else { return }
        switch registrationStatus {
        case .conflict(_, true), .handlerUnavailable(_, true):
            registrationStatus = .registered
        default:
            break
        }
    }

    /// Pauses the registered hotkey while the recorder listens.
    func beginRecording() {
        recordingPaused = true
        registrationRefusedWhileRecording = false
        unregister()
    }

    /// Ends a recording on every exit path: the recorded combination stays
    /// registered, or the previous one is registered again.
    func endRecording() {
        guard recordingPaused else { return }
        recordingPaused = false
        let refused = registrationRefusedWhileRecording
        registrationRefusedWhileRecording = false
        let error = lastRecordingError
        register()
        if refused, registrationStatus == .registered {
            lastRecordingError = "That shortcut is unavailable. The previous shortcut remains active."
        } else {
            lastRecordingError = error
        }
    }

    func dismissMigrationNotice() {
        migrationNotice = nil
        save()
    }

    /// False while the unreadable hotkey payload a reset would replace exists in
    /// no recovery slot, so the reset would destroy its only copy.
    var isRecoveryBackupPreserved: Bool {
        guard let stored = defaults.object(forKey: defaultsKey) else { return true }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: stored, format: .binary, options: 0
        ) else { return false }
        return PersistenceRecovery.slotHolding(
            data, in: defaults, baseKey: "\(defaultsKey).corruptBackup"
        ) != nil
    }

    /// Replacing an unreadable primary value requires this explicit user action.
    func resetAfterCorruption() {
        guard isReadOnlyAfterCorruption else { return }
        isReadOnlyAfterCorruption = false
        recoveryMessage = nil
        keyCode = Self.defaultKeyCode
        modifiers = Self.defaultModifiers
        hotkeyEnabled = true
    }

    func unregister() {
        if let ref = hotkeyRef {
            backend.unregister(ref)
            hotkeyRef = nil
            registeredShortcut = nil
        }
    }

    /// True while a Carbon registration is active. Tests use it to observe
    /// that an unchanged shortcut is not re-registered.
    var isRegistered: Bool {
        hotkeyRef != nil
    }

    var displayString: String {
        Self.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    nonisolated static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyName(for: keyCode) ?? "Unsupported"
        return result
    }

    static func isSupported(keyCode: UInt32, modifiers: UInt32) -> Bool {
        validationFailure(keyCode: keyCode, modifiers: modifiers) == nil
    }

    /// Why a combination is refused as a global hotkey, or nil when it is
    /// acceptable. Shift or Option alone would intercept ordinary typing in
    /// every app, and standard app and system shortcuts must remain available.
    static func validationFailure(keyCode: UInt32, modifiers: UInt32) -> String? {
        let supportedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        let flags = modifiers & supportedModifiers
        if let reserved = reservedShortcutDescription(keyCode: keyCode, modifiers: flags) {
            return "\(reserved) is reserved by macOS. Choose another combination."
        }
        guard keyName(for: keyCode) != nil else {
            return "Choose a supported key (letters, digits, function keys, arrows, Space, Return, Tab, or Delete)."
        }
        guard flags & UInt32(cmdKey | controlKey) != 0 else {
            return "A global hotkey needs Command or Control. Shift or Option alone would intercept ordinary typing in every app."
        }
        return nil
    }

    /// Standard app and system combinations; registering them either fails or
    /// hijacks a shortcut in every app.
    static func reservedShortcutDescription(keyCode: UInt32, modifiers: UInt32) -> String? {
        let command = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        let option = UInt32(optionKey)
        let control = UInt32(controlKey)
        let name = keyName(for: keyCode) ?? ""
        // A global hotkey is delivered to TaskScope instead of the frontmost
        // app: Control-letters are terminal and text-editing control keys
        // (⌃C interrupts, ⌃A/⌃E move the cursor), and Command with an arrow,
        // Delete, Return or a digit is a standard editing or app shortcut.
        if modifiers == control, name.count == 1, name.first?.isLetter == true {
            return "⌃\(name) (terminal and text-editing control key)"
        }
        let commandEditingKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                  kVK_Delete, kVK_ForwardDelete, kVK_Return,
                                  kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                  kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        if modifiers == command, commandEditingKeys.contains(Int(keyCode)) {
            return "⌘\(name) (standard app shortcut)"
        }
        switch (Int(keyCode), modifiers) {
        case (kVK_ANSI_Q, control | command):
            return "⌃⌘Q (Lock Screen)"
        case (kVK_ANSI_F, control | command):
            return "⌃⌘F (Full Screen)"
        case (kVK_Space, control | command):
            return "⌃⌘Space (Emoji & Symbols)"
        case (kVK_LeftArrow, control), (kVK_RightArrow, control),
             (kVK_UpArrow, control), (kVK_DownArrow, control):
            return "⌃\(keyName(for: keyCode) ?? "") (Spaces/Mission Control)"
        case (kVK_Space, control):
            return "⌃Space (input source)"
        case (kVK_ANSI_Q, command):
            return "⌘Q (Quit)"
        case (kVK_ANSI_A, command), (kVK_ANSI_B, command), (kVK_ANSI_C, command),
             (kVK_ANSI_D, command), (kVK_ANSI_E, command), (kVK_ANSI_F, command),
             (kVK_ANSI_G, command), (kVK_ANSI_H, command), (kVK_ANSI_I, command),
             (kVK_ANSI_J, command), (kVK_ANSI_K, command), (kVK_ANSI_L, command),
             (kVK_ANSI_M, command), (kVK_ANSI_N, command), (kVK_ANSI_O, command),
             (kVK_ANSI_P, command), (kVK_ANSI_R, command), (kVK_ANSI_S, command),
             (kVK_ANSI_T, command), (kVK_ANSI_U, command), (kVK_ANSI_V, command),
             (kVK_ANSI_W, command), (kVK_ANSI_X, command), (kVK_ANSI_Y, command),
             (kVK_ANSI_Z, command):
            return "⌘\(keyName(for: keyCode) ?? "") (standard app shortcut)"
        case (kVK_ANSI_Z, command | shift):
            return "⌘⇧Z (Redo)"
        case (kVK_ANSI_Comma, command):
            return "⌘, (Settings)"
        case (kVK_ANSI_Q, command | shift):
            return "⌘⇧Q (Log Out)"
        case (kVK_Tab, command):
            return "⌘Tab (app switcher)"
        case (kVK_Tab, command | shift):
            return "⌘⇧Tab (app switcher)"
        case (kVK_Space, command):
            return "⌘Space (Spotlight)"
        case (kVK_Space, command | option):
            return "⌘⌥Space (Finder search)"
        case (kVK_ANSI_3, command | shift), (kVK_ANSI_4, command | shift), (kVK_ANSI_5, command | shift):
            return "⌘⇧\(keyName(for: keyCode) ?? "") (screenshots)"
        default:
            return nil
        }
    }

    nonisolated static func keyName(for code: UInt32) -> String? {
        switch Int(code) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_Tab: "Tab"
        case kVK_Delete: "Delete"
        case kVK_ForwardDelete: "Forward Delete"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "Page Up"
        case kVK_PageDown: "Page Down"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: nil
        }
    }

    /// Registers `keyCode`/`modifiers`. An unchanged, already registered
    /// combination is left alone (re-registering it would conflict with
    /// itself). Otherwise the previous combination is unregistered first; if
    /// the new one is refused, the previous one is registered again so the
    /// user is not left without a hotkey, and the status says whether that
    /// restoration succeeded.
    private func registerCandidate(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let requested = carbonModifierFlags(modifiers)
        if hotkeyRef != nil,
           let registeredShortcut,
           registeredShortcut.keyCode == keyCode,
           registeredShortcut.modifiers == requested {
            registrationStatus = .registered
            return true
        }

        let previousShortcutRemainsActive = hotkeyRef != nil
        let handlerStatus = backend.installEventHandler(for: self)
        guard handlerStatus == noErr else {
            registrationStatus = .handlerUnavailable(
                handlerStatus,
                previousShortcutRemainsActive: previousShortcutRemainsActive
            )
            return false
        }

        let previous = registeredShortcut
        if let old = hotkeyRef {
            backend.unregister(old)
            hotkeyRef = nil
            registeredShortcut = nil
        }

        let registration = backend.register(keyCode: keyCode, modifiers: requested, identifier: nextIdentifier())
        guard registration.status == noErr, let candidate = registration.reference else {
            var restored = false
            if let previous {
                let restoration = backend.register(
                    keyCode: previous.keyCode,
                    modifiers: previous.modifiers,
                    identifier: nextIdentifier()
                )
                if restoration.status == noErr, let reference = restoration.reference {
                    hotkeyRef = reference
                    registeredShortcut = previous
                    restored = true
                }
            }
            registrationStatus = .conflict(
                registration.status,
                previousShortcutRemainsActive: restored
            )
            return false
        }

        hotkeyRef = candidate
        registeredShortcut = (keyCode, requested)
        registrationStatus = .registered
        return true
    }

    private func nextIdentifier() -> EventHotKeyID {
        let identifier = EventHotKeyID(signature: OSType(0x54534350), id: nextRegistrationID)
        nextRegistrationID &+= 1
        return identifier
    }

    private func carbonModifierFlags(_ flags: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if flags & UInt32(cmdKey) != 0 { carbon |= UInt32(cmdKey) }
        if flags & UInt32(shiftKey) != 0 { carbon |= UInt32(shiftKey) }
        if flags & UInt32(optionKey) != 0 { carbon |= UInt32(optionKey) }
        if flags & UInt32(controlKey) != 0 { carbon |= UInt32(controlKey) }
        return carbon
    }

    private func save() {
        guard !isReadOnlyAfterCorruption else { return }
        var saved = defaults.dictionary(forKey: defaultsKey) ?? [:]
        saved["enabled"] = hotkeyEnabled
        saved["keyCode"] = keyCode
        saved["modifiers"] = modifiers
        saved["migrationNotice"] = migrationNotice
        defaults.set(saved, forKey: defaultsKey)
    }

    func installCarbonEventHandlerIfNeeded() -> OSStatus {
        guard eventHandler == nil else { return noErr }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onShow?()
                }
                return noErr
            },
            1,
            &eventSpec,
            pointer,
            &eventHandler
        )
        guard status == noErr, eventHandler != nil else {
            eventHandler = nil
            return status == noErr ? OSStatus(eventNotHandledErr) : status
        }
        return noErr
    }
}

// MARK: - Configuration backup

extension HotkeyManager {
    /// The hotkey a configuration backup carries.
    struct Backup: Codable, Equatable, Sendable {
        var isEnabled: Bool
        var keyCode: UInt32
        var modifiers: UInt32

        var displayString: String {
            HotkeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// Nil while the stored hotkey is unreadable: the values in memory are
    /// then defaults, not the user's shortcut.
    var backup: Backup? {
        isReadOnlyAfterCorruption ? nil : Backup(isEnabled: hotkeyEnabled, keyCode: keyCode, modifiers: modifiers)
    }

    /// Why an imported hotkey cannot be used here, or nil.
    func backupProblem(_ backup: Backup) -> String? {
        if isReadOnlyAfterCorruption {
            return "Hotkey settings are in recovery mode; reset them in Settings > Hotkey first."
        }
        return Self.validationFailure(keyCode: backup.keyCode, modifiers: backup.modifiers)
    }

    /// Applies an imported hotkey: the shortcut through the same validation
    /// and registration a recording uses, then whether it is on. A shortcut
    /// another app holds leaves the current one in place and returns false.
    @discardableResult
    func applyBackup(_ backup: Backup) -> Bool {
        guard backupProblem(backup) == nil else { return false }
        if keyCode != backup.keyCode || modifiers != backup.modifiers {
            guard updateShortcut(keyCode: backup.keyCode, modifiers: backup.modifiers) else { return false }
        }
        if hotkeyEnabled != backup.isEnabled {
            hotkeyEnabled = backup.isEnabled
        }
        return true
    }
}
