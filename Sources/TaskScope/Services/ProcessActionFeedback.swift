import Combine
import SwiftUI

@MainActor
final class ProcessActionFeedback {
    private var observation: AnyCancellable?

    init(manager: ProcessManager, announce: @escaping @MainActor (String) -> Void = {
        AccessibilityNotification.Announcement($0).post()
    }) {
        observation = manager.$message.dropFirst().removeDuplicates().sink { message in
            MainActor.assumeIsolated { announce(message) }
        }
    }
}
