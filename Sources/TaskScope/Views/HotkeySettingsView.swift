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

                Text("Default: ⌃⌥⌘T shows the TaskScope window. A hotkey needs Command or Control. Standard ⌘-letter app shortcuts, ⌘Tab, and ⌘Space are reserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(hotkey.isReadOnlyAfterCorruption)

            if let recoveryMessage = hotkey.recoveryMessage {
                Section("Recovered Hotkey Settings") {
                    Text(recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("The hotkey is disabled until you reset its settings. Reset enables the default ⌃⌥⌘T shortcut.")
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
                }
            )
        }
    }
}

private struct RecordingListenerView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt32, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            guard context.coordinator.localMonitor == nil else { return }

            context.coordinator.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                var carbonMods: UInt32 = 0
                if mods.contains(.command) { carbonMods |= UInt32(cmdKey) }
                if mods.contains(.shift) { carbonMods |= UInt32(shiftKey) }
                if mods.contains(.option) { carbonMods |= UInt32(optionKey) }
                if mods.contains(.control) { carbonMods |= UInt32(controlKey) }
                // A bare key is ordinary typing. Everything else is handed to
                // the manager, which validates it (Command or Control required,
                // system-reserved combinations refused) and explains a rejection
                // in the status line.
                if carbonMods == 0 { return event }
                onRecord(UInt32(event.keyCode), carbonMods)
                return nil
            }

            context.coordinator.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
                onCancel()
            }

            context.coordinator.onCancel = onCancel
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        } else {
            context.coordinator.removeMonitors()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var localMonitor: Any?
        var globalMonitor: Any?
        var onCancel: (() -> Void)?

        @objc func applicationDidResignActive() {
            onCancel?()
        }

        func removeMonitors() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
            onCancel = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitors()
    }
}
