import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

// View-test support that needs ViewInspector, so it lives in this target only
// (Support/ is shared with TaskScopeTests, which does not link ViewInspector).

extension Inspection: InspectionEmissary {}

/// A view with an `inspection` hook, so a test can inspect it while SwiftUI
/// has it installed in a window.
@MainActor
protocol HostedInspectable: View {
    var inspection: Inspection<Self> { get }
}

extension TaskScopePopoverView: HostedInspectable {}
extension SettingsView: HostedInspectable {}

/// What one inspection saw, read after it finishes.
@MainActor
private final class InstalledView<V> {
    var value: V?
}

extension XCTestCase {
    /// Installs `view` in a window until the test ends and returns the
    /// installed view to inspect. Unlike `inspect()` on the bare struct, the
    /// view's own state, focus and environment behave as in the app: a tap
    /// changes state that later inspections see, `onAppear`, `task` and
    /// `onChange` run, and no warning about state read outside an installed
    /// view is logged. Each call installs a separate copy of the view.
    @MainActor
    func hosted<V: HostedInspectable>(
        _ view: V,
        function: String = #function
    ) async throws -> InspectableView<ViewType.ClassifiedView> {
        try await installed(view, function: function).inspect()
    }

    /// Installs `view` like `hosted` and returns the copy SwiftUI installed,
    /// for calling the view's own methods (a row's context menu, say) with
    /// its installed state.
    @MainActor
    func installed<V: HostedInspectable>(_ view: V, function: String = #function) async throws -> V {
        let key = "\(function).\(UUID().uuidString)"
        TestWindows.install(view, key: key)
        addTeardownBlock { await MainActor.run { TestWindows.remove(key: key) } }
        // The hook hands back the copy SwiftUI installed. Its state lives in
        // the window, so inspecting it later reads the current values.
        let installed = InstalledView<V>()
        try await view.inspection.inspect(function: key) { hostedView in
            installed.value = try hostedView.actualView()
        }
        guard let installedView = installed.value else {
            throw InspectionError.notSupported("The installed view never answered its inspection.")
        }
        return installedView
    }
}

/// The windows test views are installed in. Each sits far off every display,
/// is transparent and lets clicks pass through. A sheet or alert a test view
/// presents is a window of its own that AppKit places on screen, so every
/// window of the test process is made transparent and click-through as soon
/// as it appears or moves. A test run shows nothing, and a click meant for
/// another app never reaches a test's view.
@MainActor
enum TestWindows {
    private static var windows: [String: NSWindow] = [:]
    private static var isHidingNewWindows = false

    /// AppKit would move a titled window onto a display when it is shown.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    static func install<V: View>(_ view: V, key: String) {
        _ = NSApplication.shared
        hideNewWindows()
        let origin = NSPoint(x: -20_000, y: -20_000)
        let window = OffscreenWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 800, height: 600)),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // The hosting controller sizes the window to the view, so each view is
        // laid out at its own size and never squeezed.
        window.contentViewController = NSHostingController(rootView: view)
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        windows[key] = window
    }

    static func remove(key: String) {
        guard let window = windows.removeValue(forKey: key) else { return }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private static func hideNewWindows() {
        guard !isHidingNewWindows else { return }
        isHidingNewWindows = true
        let names = [
            NSWindow.didUpdateNotification, NSWindow.willBeginSheetNotification,
            NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { hideAll() }
            }
        }
    }

    private static func hideAll() {
        for window in NSApplication.shared.windows where window.alphaValue != 0 || !window.ignoresMouseEvents {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
    }
}
