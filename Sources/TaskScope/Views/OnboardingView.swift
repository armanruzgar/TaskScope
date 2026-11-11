import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    /// The global shortcut that shows the main window, or nil while it is off.
    var hotkeyShortcut: String? = HotkeyManager.defaultDisplayString
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            Text("Welcome to TaskScope")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingRow(
                        icon: "scope",
                        title: "Watch Apps",
                        description: "TaskScope watches apps like GlobalProtect. Notifications stay off until you explicitly enable them in Settings."
                    )
                    OnboardingRow(
                        icon: "menubar.rectangle",
                        title: "Menu Bar and Shortcut",
                        description: menuBarDescription
                    )
                    OnboardingRow(
                        icon: "stop.circle",
                        title: "Stop Processes",
                        description: "Right-click a row to inspect it or copy its executable path, then use its Stop button or context menu. Force Stop is an explicit immediate kill."
                    )
                    OnboardingRow(
                        icon: "gearshape",
                        title: "Customize",
                        description: "Open Settings to add your own watched apps, adjust thresholds, and configure auto-stop rules."
                    )
                    OnboardingRow(
                        icon: "lock.shield",
                        title: "GlobalProtect Permissions",
                        description: "Quit All and Keep GlobalProtect Off use Accessibility to press Disconnect, so macOS may ask you to allow TaskScope. Stopping or restoring the VPN service may ask for administrator approval. Settings > Health shows the Accessibility status."
                    )
                    OnboardingRow(
                        icon: "keyboard",
                        title: "Keyboard",
                        description: "Use ↑/↓ to navigate visible rows, Return to review Stop, Cmd+A to select visible rows, and Cmd+Shift+A to clear."
                    )
                }
                .padding(.horizontal, 8)
            }

            Text("Show this page again with Help > Welcome to TaskScope.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Get Started") {
                onComplete()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 460, height: 600)
    }

    private var menuBarDescription: String {
        let base = "TaskScope keeps running in the menu bar after you close its window. Click its menu bar icon for a compact process list"
        guard let hotkeyShortcut else {
            return base + ". Turn on a global shortcut in Settings > Hotkey."
        }
        return base + ", or press \(hotkeyShortcut) anywhere to show the main window. Change the shortcut in Settings > Hotkey."
    }
}

private struct OnboardingRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
