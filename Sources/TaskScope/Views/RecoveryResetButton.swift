import Foundation
import SwiftUI

/// The reset button shown while a store is read-only after recovery. Its label
/// promises a backup only when the unreadable payload really is preserved;
/// otherwise it says the data is discarded and asks for confirmation first.
struct RecoveryResetButton: View {
    let subject: String
    let isBackupPreserved: Bool
    /// Internal so a test can inspect the confirmation as presented.
    @State var isConfirmingDiscard = false
    let onReset: () -> Void

    var body: some View {
        Button(title, role: .destructive) {
            if isBackupPreserved {
                onReset()
            } else {
                isConfirmingDiscard = true
            }
        }
        .confirmationDialog(
            "Discard the unreadable \(subject.lowercased())?",
            isPresented: $isConfirmingDiscard
        ) {
            Button("Discard and Reset", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.discardWarning(domain: Bundle.main.bundleIdentifier ?? "com.local.TaskScope"))
        }
    }

    var title: String {
        isBackupPreserved
            ? "Reset \(subject) After Backup"
            : "Discard Unreadable \(subject) and Reset"
    }

    static func discardWarning(domain: String) -> String {
        "Nothing was backed up: every recovery slot already holds an earlier payload. "
            + "Resetting replaces the unreadable data, and it cannot be recovered afterwards. "
            + "To keep a copy, first run this in Terminal: "
            + "defaults export \(domain) ~/Desktop/TaskScope-preferences.plist"
    }
}
