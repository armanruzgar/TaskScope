import Combine

/// The one app-level owner of Auto Stop prompts. A Prompt rule must be asked
/// even when no TaskScope window or menu-bar popover is open (for example after
/// a login-item launch), so prompts are not tied to a mounted view; and with one
/// owner the window and the popover can no longer show the same prompt twice.
@MainActor
final class AutoStopPromptCoordinator {
    private let rules: AutoStopRulesStore
    private let confirmation: any MenuBarConfirming
    private var observation: AnyCancellable?
    private(set) var task: Task<Void, Never>?

    init(rules: AutoStopRulesStore, confirmation: any MenuBarConfirming) {
        self.rules = rules
        self.confirmation = confirmation
        rules.hasAppPromptPresenter = true
        observation = rules.$pendingPrompts.sink { [weak self] _ in
            // `@Published` emits before the new value is stored; look once the
            // write has completed.
            Task { @MainActor [weak self] in self?.presentIfNeeded() }
        }
    }

    private func presentIfNeeded() {
        guard task == nil, rules.currentPrompt != nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while let prompt = rules.currentPrompt {
                let confirmed = await confirmation.confirm(Self.request(for: prompt))
                guard !Task.isCancelled else { break }
                // The process may have exited, or the prompt been answered
                // elsewhere, while the alert was open: never act on a prompt
                // that is no longer queued.
                guard rules.pendingPrompts.contains(where: { $0.id == prompt.id }) else { continue }
                if confirmed {
                    if let claimed = rules.claimPrompt(prompt) { await rules.finishStop(claimed) }
                } else {
                    rules.dismissPrompt(prompt)
                }
            }
            task = nil
        }
    }

    static func request(for prompt: AutoStopPrompt) -> MenuBarConfirmationRequest {
        MenuBarConfirmationRequest(
            title: "Auto-Stop: \(prompt.process.name)",
            message: AutoStopPromptAlert.message(for: prompt),
            confirmTitle: "Stop Now",
            cancelTitle: "Dismiss"
        )
    }
}
