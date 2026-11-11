import AppKit

struct MenuBarConfirmationRequest: Equatable {
    var title: String
    var message: String
    var confirmTitle: String
    var cancelTitle: String = "Cancel"
    /// Shown in a scrolling, selectable list below the message, for content
    /// that must be reviewed in full, such as every target of a batch stop.
    var details: String? = nil
}

/// Asks for confirmation outside the menu-bar window. A dialog attached to that
/// window stops accepting clicks once another app takes keyboard focus while
/// the window stays on screen, which GlobalProtect does whenever it launches.
@MainActor
protocol MenuBarConfirming: Sendable {
    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool
}

/// Brings TaskScope forward and asks in a standard app-modal alert, which takes
/// keyboard focus whatever state the menu-bar window is in.
@MainActor
struct AppModalMenuBarConfirmation: MenuBarConfirming {
    /// Shows the alert and returns the button the user chose. Replaceable so
    /// tests can check the alert and the answer mapping without a modal loop.
    var runAlert: @MainActor @Sendable (NSAlert) -> NSApplication.ModalResponse = { alert in
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    func confirm(_ request: MenuBarConfirmationRequest) async -> Bool {
        // Enter AppKit's modal loop from a run-loop callout, not from inside a
        // main-actor job: libdispatch does not drain the main queue re-entrantly,
        // so a modal loop entered from a job would stop every other main-actor
        // task (polling, Auto Stop, commands, the SIGTERM handler) until the
        // alert closes. The default mode also keeps a second alert from opening
        // inside the first one's modal loop.
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    let response = runAlert(Self.makeAlert(request))
                    continuation.resume(returning: Self.consents(response))
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// One of the alert's buttons, in the order the alert adds them.
    struct AlertButton: Equatable {
        var title: String
        var keyEquivalent: String
        var isDestructive: Bool
    }

    /// The confirmation comes first and is marked destructive. AppKit would
    /// give the first button Return, and a destructive answer must be chosen
    /// deliberately, so it has no key equivalent; Cancel answers Escape.
    static func alertButtons(for request: MenuBarConfirmationRequest) -> [AlertButton] {
        [
            AlertButton(title: request.confirmTitle, keyEquivalent: "", isDestructive: true),
            AlertButton(title: request.cancelTitle, keyEquivalent: "\u{1b}", isDestructive: false)
        ]
    }

    /// Only the first button, the confirmation, consents. Cancel, Escape and
    /// any other way the alert ends do not.
    static func consents(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    static func makeAlert(_ request: MenuBarConfirmationRequest) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.message
        if let details = request.details {
            alert.accessoryView = scrollingText(details)
        } else if request.message.count > 500 {
            alert.accessoryView = scrollingText(request.message)
            alert.informativeText = "Review the details below."
        }
        for button in alertButtons(for: request) {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.isDestructive
            added.keyEquivalent = button.keyEquivalent
        }
        return alert
    }

    private static func scrollingText(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }
}
