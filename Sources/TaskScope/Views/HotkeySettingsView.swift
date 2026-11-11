import Carbon.HIToolbox
import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject private var hotkey: HotkeyManager
    @State private var recording = false

    @MainActor
    init(hotkey: HotkeyManager? = nil) {
        self.hotkey = hotkey ?? .shared
    }

    var body: some View {
        Form {
            Section("Global Hotkey") {
                Toggle("Enable global Show TaskScope hotkey", isOn: $hotkey.hotkeyEnabled)

                HStack {
                    Text("Current Hotkey")
                    Spacer()
                    Text(hotkey.displayString)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                Button(recording ? "Press a key combination…" : "Record New Hotkey") {
                    hotkey.clearRecordingError()
                    recording = true
                }
                .disabled(!hotkey.hotkeyEnabled)
                .buttonStyle(.bordered)

                if recording {
                    Text("Press the key combination you want to use. Esc to cancel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let notice = hotkey.migrationNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Dismiss Shortcut Notice") {
                        hotkey.dismissMigrationNotice()
                    }
                }

                if let error = hotkey.lastRecordingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(hotkey.registrationStatus.message)
                    .font(.caption)
                    .foregroundStyle(
                        hotkey.registrationStatus == .registered
                            ? Color.secondary
                            : Color.orange
                    )

                Text("Default: \(HotkeyManager.defaultDisplayString) shows the TaskScope window. A hotkey needs Command or Control. Standard ⌘ app shortcuts (letters, digits, arrows, Delete, Return), ⌃-letter control keys, ⌘Tab, and ⌘Space are reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(hotkey.isReadOnlyAfterCorruption)

            if let recoveryMessage = hotkey.recoveryMessage {
                Section("Recovered Hotkey Settings") {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("The hotkey is disabled until you reset its settings. Reset enables the default \(HotkeyManager.defaultDisplayString) shortcut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RecoveryResetButton(
                        subject: "Hotkey Settings",
                        isBackupPreserved: hotkey.isRecoveryBackupPreserved
                    ) {
                        hotkey.resetAfterCorruption()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .background {
            RecordingListenerView(
                isRecording: $recording,
                onRecord: { keyCode, modifiers in
                    _ = hotkey.updateShortcut(keyCode: keyCode, modifiers: modifiers)
                    recording = false
                },
                onCancel: {
                    recording = false
                },
                // Recording starts and ends inside a view update; pausing and
                // resuming the hotkey publishes status, so it runs right after
                // the update, in the order the sessions started and ended.
                onStart: { [hotkey] in
                    Task { @MainActor in hotkey.beginRecording() }
                },
                onFinish: { [hotkey] in
                    Task { @MainActor in hotkey.endRecording() }
                }
            )
        }
    }
}

private struct RecordingListenerView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt32, UInt32) -> Void
    let onCancel: () -> Void
    let onStart: () -> Void
    let onFinish: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            context.coordinator.start(
                recorderWindow: nsView.window,
                onRecord: onRecord,
                onCancel: onCancel,
                onStart: onStart,
                onFinish: onFinish
            )
        } else {
            context.coordinator.stop()
        }
    }

    func makeCoordinator() -> HotkeyRecorderCoordinator { HotkeyRecorderCoordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: HotkeyRecorderCoordinator) {
        coordinator.stop()
    }
}

/// One recording session: the key monitors and the observers that end it.
/// Recording belongs to the window that shows the recorder. Keystrokes typed
/// in any other TaskScope window pass through, and the recording is cancelled
/// when that window stops being key or closes, or TaskScope stops being active.
@MainActor
final class HotkeyRecorderCoordinator: NSObject {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var onCancel: (() -> Void)?
    private var onFinish: (() -> Void)?
    private(set) var isRecording = false

    func start(
        recorderWindow: NSWindow?,
        onRecord: @escaping (UInt32, UInt32) -> Void,
        onCancel: @escaping () -> Void,
        onStart: () -> Void = {},
        onFinish: @escaping () -> Void = {},
        installsEventMonitors: Bool = true
    ) {
        guard !isRecording else { return }
        isRecording = true
        self.onCancel = onCancel
        self.onFinish = onFinish
        onStart()

        if installsEventMonitors {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak recorderWindow] event in
                switch HotkeyRecordingInput.action(
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags,
                    eventWindow: event.window,
                    recorderWindow: recorderWindow
                ) {
                case .passThrough:
                    return event
                case .cancel:
                    onCancel()
                    return nil
                case .record(let keyCode, let modifiers):
                    onRecord(keyCode, modifiers)
                    return nil
                }
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
                onCancel()
            }
        }

        let center = NotificationCenter.default
        if let recorderWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(cancelRecording), name: name, object: recorderWindow)
            }
        }
        center.addObserver(
            self,
            selector: #selector(cancelRecording),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// Ends the session on every path (recorded, cancelled, view torn down)
    /// and lets the owner resume the paused hotkey.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
        let finish = onFinish
        onCancel = nil
        onFinish = nil
        finish?()
    }

    @objc func cancelRecording() {
        onCancel?()
    }
}

/// What the recorder does with one keyDown event.
enum HotkeyRecordingInput {
    enum Action: Equatable {
        case passThrough
        case cancel
        case record(keyCode: UInt32, modifiers: UInt32)
    }

    static func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventWindow: NSWindow?,
        recorderWindow: NSWindow?
    ) -> Action {
        // Only keystrokes typed in the recorder's own window are captured.
        guard let recorderWindow, eventWindow === recorderWindow else { return .passThrough }
        if Int(keyCode) == kVK_Escape { return .cancel }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        // A bare key is ordinary typing. Everything else is handed to the
        // manager, which validates it (Command or Control required, reserved
        // combinations refused) and explains a rejection in the status line.
        guard carbonModifiers != 0 else { return .passThrough }
        return .record(keyCode: UInt32(keyCode), modifiers: carbonModifiers)
    }
}
