import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

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

            VStack(alignment: .leading, spacing: 14) {
                OnboardingRow(
                    icon: "scope",
                    title: "Watch Apps",
                    description: "TaskScope watches apps like GlobalProtect. Notifications stay off until you explicitly enable them in Settings."
                )
                OnboardingRow(
                    icon: "stop.circle",
                    title: "Stop Processes",
                    description: "Right-click a row to inspect it or copy its command, then use its Stop button or context menu. Force Stop is an explicit immediate kill."
                )
                OnboardingRow(
                    icon: "gearshape",
                    title: "Customize",
                    description: "Open Settings to add your own watched apps, adjust thresholds, and configure auto-stop rules."
                )
                OnboardingRow(
                    icon: "keyboard",
                    title: "Keyboard",
                    description: "Use ↑/↓ to navigate visible rows, Return to review Stop, Cmd+A to select visible rows, and Cmd+Shift+A to clear."
                )
            }
            .padding(.horizontal, 8)

            Spacer()

            Button("Get Started") {
                onComplete()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 460, height: 560)
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
