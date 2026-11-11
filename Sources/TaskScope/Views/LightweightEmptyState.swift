import SwiftUI

struct LightweightEmptyState: View {
    var loadAction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "leaf")
                .accessibilityHidden(true)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Idle Until Needed")
                    .font(.headline)

                Text("Load a lightweight top-process snapshot when you need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }

            Button {
                loadAction()
            } label: {
                Label("Load Processes", systemImage: "bolt")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
