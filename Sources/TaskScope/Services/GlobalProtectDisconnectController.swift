import Foundation

enum GlobalProtectDisconnectResult: Equatable, Sendable {
    case disconnected
    case failed(String)
}

enum GlobalProtectConnectionState: Equatable, Sendable {
    case connected
    case disconnected
    case busy
    case unavailable
}

/// An Error tooltip alone is ambiguous. The vendor's Connection Failed view
/// with an enabled Connect control and no Disconnect control is an idle VPN.
struct GlobalProtectConnectionObservation {
    var status: String?
    var showsConnectionFailed = false
    var canConnect = false
    var hasDisconnect = false

    var state: GlobalProtectConnectionState {
        switch status {
        case "Not Connected": .disconnected
        case "Connected": .connected
        case "Connecting...", "Disconnecting...": .busy
        case "Error" where showsConnectionFailed && canConnect && !hasDisconnect: .disconnected
        default: .unavailable
        }
    }
}

struct GlobalProtectDisconnectDeadline: Sendable {
    private let expiresAt: TimeInterval
    private let now: @Sendable () -> TimeInterval

    init(
        timeLimit: TimeInterval = 90,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        expiresAt = now() + max(0, timeLimit)
    }

    var remainingTime: TimeInterval { max(0, expiresAt - now()) }
}

enum GlobalProtectDisconnectPressResult: Sendable {
    case pressed, notPressable, unconfirmed
}

protocol GlobalProtectDisconnectRuntime: Sendable {
    func connectionState(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectConnectionState
    func pressDisconnect(deadline: GlobalProtectDisconnectDeadline) async -> GlobalProtectDisconnectPressResult
    func waitForNextObservation(deadline: GlobalProtectDisconnectDeadline) async
}

/// Never shuts down the service on a timeout, failed click, or an unknown state.
/// Consecutive disconnected observations give the vendor time to restore DNS.
enum GlobalProtectDisconnectController {
    /// `startupUnavailableObservations` extends the unreadable-state budget
    /// until the first readable observation, for an interface that was just
    /// launched and has not yet created its menu bar item.
    static func disconnect(
        using runtime: any GlobalProtectDisconnectRuntime,
        observationLimit: Int = 60,
        startupUnavailableObservations: Int = 0,
        deadline: GlobalProtectDisconnectDeadline = GlobalProtectDisconnectDeadline()
    ) async -> GlobalProtectDisconnectResult {
        let timedOut = GlobalProtectDisconnectResult.failed("GlobalProtect did not finish disconnecting. Complete any request in GlobalProtect and try Quit All again; its services were left running.")
        var requested = false
        var disconnectedObservations = 0
        var unavailableObservations = 0
        var hasReadState = false
        for _ in 0..<observationLimit {
            guard !Task.isCancelled else {
                return .failed("GlobalProtect shutdown was cancelled before its services were stopped.")
            }
            guard deadline.remainingTime > 0 else { return timedOut }
            let state = await runtime.connectionState(deadline: deadline)
            guard deadline.remainingTime > 0 else { return timedOut }
            if state != .unavailable {
                unavailableObservations = 0
                hasReadState = true
            }
            switch state {
            case .disconnected:
                disconnectedObservations += 1
                if disconnectedObservations >= 5 { return .disconnected }
            case .connected:
                disconnectedObservations = 0
                if !requested {
                    let pressed = await runtime.pressDisconnect(deadline: deadline)
                    guard deadline.remainingTime > 0 else { return timedOut }
                    guard pressed != .notPressable else {
                        return .failed("GlobalProtect's Disconnect control is unavailable. Its services were left running.")
                    }
                    requested = true
                }
            case .busy:
                disconnectedObservations = 0
            case .unavailable:
                disconnectedObservations = 0
                unavailableObservations += 1
                // A menu can disappear during a focus change. Give the runtime
                // a bounded chance to reopen it; unreadable state is never idle.
                let allowed = hasReadState ? 3 : 3 + max(0, startupUnavailableObservations)
                if unavailableObservations >= allowed {
                    return .failed("TaskScope could not verify GlobalProtect's connection state. Its services were left running.")
                }
            }
            await runtime.waitForNextObservation(deadline: deadline)
        }
        return timedOut
    }
}
