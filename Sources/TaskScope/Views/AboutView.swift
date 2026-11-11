import SwiftUI

struct AboutView: View {
    /// The bundle's version and build, or nil for a bare SwiftPM executable,
    /// which embeds no Info.plist.
    var versionInfo: (version: String, build: String)? = AboutView.bundledAppInfo

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("TaskScope")
                .font(.title2.bold())

            // Selectable: bug reports ask for the exact version and build.
            Text(versionLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Native macOS menu bar utility for monitoring running processes and stopping selected tasks.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Spacer()
        }
        .padding(32)
        .frame(width: 360, height: 280)
    }

    private var versionLine: String {
        guard let versionInfo else { return "Development build (no bundle version)" }
        return "Version \(versionInfo.version) (\(versionInfo.build))"
    }

    private static var bundledAppInfo: (version: String, build: String)? {
        guard
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            !build.isEmpty
        else {
            return nil
        }
        return (version, build)
    }
}
