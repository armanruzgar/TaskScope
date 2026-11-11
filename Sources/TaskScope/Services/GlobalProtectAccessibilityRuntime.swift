import AppKit
import ApplicationServices
import Darwin
import Foundation

enum GlobalProtectAccessibilityDisconnect {
    static let executable = "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"

    struct Runtime: Sendable {
        var lifecycle: ProcessLifecycleRuntime
        var requestAccessibility: @Sendable () -> Bool
        var application: @Sendable () async -> (pid: Int32, launched: Bool)?
        var disconnect: @Sendable (Int32, Bool) async -> GlobalProtectDisconnectResult
    }

    static let liveRuntime = Runtime(
        lifecycle: .live,
        requestAccessibility: {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        application: { await applicationPID(openIfNeeded: true) },
        disconnect: { pid, launched in
            await GlobalProtectDisconnectController.disconnect(
                using: GlobalProtectAccessibilityRuntime(pid: pid),
                startupUnavailableObservations: launched ? 20 : 0
            )
        }
    )

    static func disconnectIfNeeded(runtime: Runtime = liveRuntime) async -> GlobalProtectDisconnectResult {
        guard case .success(let processes) = await runtime.lifecycle.loadProcessInventory() else {
            return .failed("The process list is unavailable. GlobalProtect's services were left running.")
        }
        let snapshot = WatchedSnapshotBuilder(excludedPID: getpid(), currentUID: runtime.lifecycle.userID)
            .snapshot(for: .globalProtect, in: processes)
        let services = await GlobalProtectServiceObservation.read(runtime: runtime.lifecycle)
        guard services.session != .unknown, services.system != .unknown else {
            return .failed("TaskScope could not verify GlobalProtect's login-session or system VPN service. Its services were left running.")
        }
        guard snapshot.isMainRunning || snapshot.hasHelpers
                || services.session == .running || services.system == .running else { return .disconnected }

        // Check permission before touching the vendor app, so a denied request
        // never leaves an interface running that was not running before.
        let trusted = runtime.requestAccessibility()
        guard trusted else {
            return .failed("Allow TaskScope in System Settings → Privacy & Security → Accessibility, then choose Quit All again. This lets TaskScope disconnect the VPN for you. Its services were left running.")
        }
        // UI control is confined to the fixed vendor executable, never a name
        // supplied by a preset. A running service without a UI gets its UI opened.
        let application = await runtime.application()
        guard let pid = application?.pid, runtime.lifecycle.executablePathForPID(pid) == executable else {
            return .failed("GlobalProtect's interface could not be opened to disconnect. Its services were left running.")
        }
        return await runtime.disconnect(pid, application?.launched == true)
    }

    @MainActor
    private static func applicationPID(openIfNeeded: Bool) async -> (pid: Int32, launched: Bool)? {
        func currentPID() -> Int32? {
            NSWorkspace.shared.runningApplications.first {
                $0.executableURL?.path == executable && !$0.isTerminated
            }?.processIdentifier
        }
        if let pid = currentPID() { return (pid, false) }
        guard openIfNeeded else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // `runningApplications` refreshes only as the main run loop turns, so use
        // the launched app's own PID rather than re-reading that list at once.
        let launched = try? await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/GlobalProtect.app"), configuration: configuration
        )
        guard let pid = launched.map(\.processIdentifier) ?? currentPID() else { return nil }
        return (pid, true)
    }
}

/// Thin queue-confined AX boundary. Tests supply in-memory elements while the
/// adapter retains the same traversal, deadlines and identity checks.
enum GlobalProtectAXValue {
    case element(any GlobalProtectAXElement)
    case elements([any GlobalProtectAXElement])
    case string(String)
    case boolean(Bool)
}

protocol GlobalProtectAXElement {
    func copyAttribute(_ attribute: String) -> (AXError, GlobalProtectAXValue?)
    func perform(_ action: String) -> AXError
    func setFrontmost() -> AXError
    func setMessagingTimeout(_ seconds: Float)
}

private struct SystemGlobalProtectAXElement: GlobalProtectAXElement {
    let element: AXUIElement
    func copyAttribute(_ attribute: String) -> (AXError, GlobalProtectAXValue?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return (error, nil) }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (error, .element(Self(element: unsafeBitCast(value, to: AXUIElement.self))))
        }
        if let elements = value as? [AXUIElement] {
            return (error, .elements(elements.map { Self(element: $0) }))
        }
        if let text = value as? String { return (error, .string(text)) }
        if let boolean = value as? Bool { return (error, .boolean(boolean)) }
        return (error, nil)
    }
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(element, action as CFString) }
    func setFrontmost() -> AXError { AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
    func setMessagingTimeout(_ seconds: Float) { AXUIElementSetMessagingTimeout(element, seconds) }
}

/// AX elements never leave this worker's serial queue; slow vendor responses
/// cannot block SwiftUI or reorder the lifecycle mutation gate.
final class GlobalProtectAccessibilityRuntime: GlobalProtectDisconnectRuntime, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TaskScope.GlobalProtectDisconnect", qos: .userInitiated)
    private let pid: Int32
    /// Set when an Accessibility request times out. Queue-confined. A hung
    /// vendor UI then fails the current observation quickly instead of costing
    /// one messaging timeout per element in a tree walk.
    private var isUnresponsive = false
    private var deadline = GlobalProtectDisconnectDeadline(timeLimit: 0)

    struct Environment: Sendable {
        var executablePath: @Sendable (Int32) -> String? = { ProcessListReader.executablePath(for: $0) }
        var application: @Sendable (Int32) -> any GlobalProtectAXElement = {
            SystemGlobalProtectAXElement(element: AXUIElementCreateApplication($0))
        }
        var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }
    private let environment: Environment

    init(pid: Int32, environment: Environment = Environment()) {
        self.pid = pid
        self.environment = environment
    }

    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isUnresponsive = false
                self.deadline = deadline
                guard let item = statusItem() else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                var observation = GlobalProtectConnectionObservation(status: string(item, kAXHelpAttribute))
                if observation.status == "Error", let app = application() {
                    revealControls(app: app, item: item, role: kAXStaticTextRole, title: "Connection Failed")
                    // All controls must belong to the same vendor window.
                    for window in elements(app, kAXWindowsAttribute) {
                        let roots = [window]
                        guard find(in: roots, role: kAXStaticTextRole, title: "Connection Failed") != nil else { continue }
                        observation.showsConnectionFailed = true
                        observation.canConnect = find(in: roots, role: kAXButtonRole, title: "Connect")
                            .map { boolean($0, kAXEnabledAttribute) } == true
                        observation.hasDisconnect = find(in: roots, role: kAXButtonRole, title: "Disconnect") != nil
                        break
                    }
                    // Do not accept an idle view if the status changed while
                    // its controls were being read.
                    observation.status = string(item, kAXHelpAttribute)
                }
                continuation.resume(returning: isUnresponsive || !hasVendorIdentity ? .unavailable : observation.state)
            }
        }
    }

    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectDisconnectPressResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isUnresponsive = false
                self.deadline = deadline
                guard let app = application(), let item = statusItem() else {
                    continuation.resume(returning: .notPressable)
                    return
                }
                func button() -> (any GlobalProtectAXElement)? {
                    find(in: elements(app, kAXWindowsAttribute), role: kAXButtonRole, title: "Disconnect")
                }
                revealControls(app: app, item: item, role: kAXButtonRole, title: "Disconnect")
                guard let disconnectButton = button(), boolean(disconnectButton, kAXEnabledAttribute),
                      application() != nil, prepareRequest(disconnectButton) else {
                    continuation.resume(returning: .notPressable)
                    return
                }
                let result = disconnectButton.perform(kAXPressAction)
                continuation.resume(returning: result == .success ? .pressed : (result == .cannotComplete ? .unconfirmed : .notPressable))
            }
        }
    }

    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async {
        try? await Task.sleep(nanoseconds: UInt64(min(0.5, deadline.remainingTime) * 1_000_000_000))
    }

    private func revealControls(app: any GlobalProtectAXElement, item: any GlobalProtectAXElement, role: String, title: String) {
        // AXPress can succeed without leaving a usable popover when another
        // app owns focus. Activate the fixed vendor app before opening it.
        // Reacquire on every observation: a one-time reveal is invalidated by
        // TaskScope's window handoff or a user switching applications.
        guard application() != nil, prepareRequest(app) else { return }
        _ = app.setFrontmost()
        if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        guard prepareRequest(item), item.perform(kAXPressAction) == .success else { return }
        for _ in 0..<20 {
            guard !isUnresponsive, deadline.remainingTime > 0 else { return }
            environment.sleep(min(0.1, deadline.remainingTime))
            if find(in: elements(app, kAXWindowsAttribute), role: role, title: title) != nil { return }
        }
    }

    private var hasVendorIdentity: Bool {
        environment.executablePath(pid) == GlobalProtectAccessibilityDisconnect.executable
    }

    private func application() -> (any GlobalProtectAXElement)? {
        guard !isUnresponsive, deadline.remainingTime > 0,
              hasVendorIdentity else { return nil }
        let app = environment.application(pid)
        guard prepareRequest(app) else { return nil }
        return app
    }

    private func statusItem() -> (any GlobalProtectAXElement)? {
        guard let app = application(),
              case .element(let menuBar) = copyAttribute(app, kAXExtrasMenuBarAttribute) else { return nil }
        return find(in: elements(menuBar, kAXChildrenAttribute), role: kAXMenuBarItemRole)
    }

    /// Every AX request shares the controller's deadline, including tree walks
    /// within one observation. Zero would restore the global messaging timeout.
    private func prepareRequest(_ element: any GlobalProtectAXElement) -> Bool {
        let remaining = deadline.remainingTime
        guard !isUnresponsive, remaining > 0, hasVendorIdentity else { return false }
        element.setMessagingTimeout(Float(min(1, remaining)))
        return true
    }

    /// Reads one attribute, recording a timeout so callers stop walking a
    /// vendor UI that has stopped answering.
    private func copyAttribute(_ element: any GlobalProtectAXElement, _ attribute: String) -> GlobalProtectAXValue? {
        guard prepareRequest(element) else { return nil }
        let (error, value) = element.copyAttribute(attribute)
        if error == .cannotComplete { isUnresponsive = true }
        return error == .success ? value : nil
    }

    private func elements(_ element: any GlobalProtectAXElement, _ attribute: String) -> [any GlobalProtectAXElement] {
        if case .elements(let values) = copyAttribute(element, attribute) { return values }
        return []
    }

    private func string(_ element: any GlobalProtectAXElement, _ attribute: String) -> String? {
        if case .string(let value) = copyAttribute(element, attribute) { return value }
        return nil
    }

    private func boolean(_ element: any GlobalProtectAXElement, _ attribute: String) -> Bool {
        if case .boolean(let value) = copyAttribute(element, attribute) { return value }
        return false
    }

    private func find(in roots: [any GlobalProtectAXElement], role: String, title: String? = nil) -> (any GlobalProtectAXElement)? {
        var pending = roots.map { ($0, 0) }
        var inspected = 0
        while !isUnresponsive, deadline.remainingTime > 0,
              let (element, depth) = pending.popLast(), inspected < 100 {
            inspected += 1
            if string(element, kAXRoleAttribute) == role,
               title == nil || string(element, kAXTitleAttribute) == title || string(element, kAXDescriptionAttribute) == title
                || (role == kAXStaticTextRole && string(element, kAXValueAttribute) == title) {
                return element
            }
            if depth < 8 {
                pending += elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }
            }
        }
        return nil
    }
}
