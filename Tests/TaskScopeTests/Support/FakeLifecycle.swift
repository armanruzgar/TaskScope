import Foundation
import XCTest
@testable import TaskScope

/// The lifecycle service for tests (L07-8). Every method records its call and
/// answers with its stub. A method whose stub is unset fails the test and
/// answers with a failure, so a test states each lifecycle call it expects.
/// `allSucceeding()` sets every stub explicitly, for tests about something
/// other than which lifecycle calls happen.
final class FakeLifecycle: ProcessLifecycleServicing, @unchecked Sendable {
    typealias Batch = @Sendable (WatchedAppPreset) async -> LifecycleBatchResult

    private let lock = NSLock()
    private let file: StaticString
    private let line: UInt
    private var callLog: [String] = []
    private var presetLog: [String: [WatchedAppPreset]] = [:]
    private var preservedPIDLog: [Set<Int32>] = []
    private var preservedVPNServiceLog: [Bool] = []
    private var openedPathLog: [String] = []

    private var _settle: (@Sendable () async -> Void)?
    private var _terminateMain: (@Sendable (WatchedAppPreset) async -> ProcessTerminationOutcome)?
    private var _terminateHelper: (@Sendable (String, WatchedAppPreset) async -> ProcessTerminationOutcome)?
    private var _waitForMain: (@Sendable (WatchedAppPreset, TimeInterval) async -> Bool)?
    private var _unloadAgents: Batch?
    private var _bootstrapAgents: Batch?
    private var _disableAgents: (@Sendable (WatchedAppPreset, Bool) async -> LifecycleBatchResult)?
    private var _enableAgents: Batch?
    private var _ensureDaemons: Batch?
    private var _disableDaemons: (@Sendable (WatchedAppPreset, Bool) async -> LifecycleBatchResult)?
    private var _enableDaemons: Batch?
    private var _appBundleExists: (@Sendable (String) -> Bool)?
    private var _openAppBundle: (@Sendable (String) async -> AppBundleOpenResult)?
    private var _disconnect: (@Sendable () async -> GlobalProtectDisconnectResult)?
    private var _onBootstrapAgents: (@Sendable () async -> Void)?
    private var _onDisableAgents: (@Sendable () async -> Void)?
    private var _onDisconnect: (@Sendable () async -> Void)?
    private var _terminateScope: (@Sendable (WatchedAppPreset, PresetStopScope) async -> [ProcessTerminationOutcome])?
    private var _fixed_terminationOutcome: ProcessTerminationOutcome = .signalled
    private var _fixed_waitResult: Bool = true
    private var _fixed_agentsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_daemonsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_appExists: Bool = true
    private var _fixed_openResult: AppBundleOpenResult = .opened
    private var _fixed_unloadAgentsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_bootstrapAgentsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_disableAgentsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_enableAgentsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_ensureDaemonsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_disableDaemonsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_enableDaemonsResult: LifecycleBatchResult = .notNeeded
    private var _fixed_disconnectResult: GlobalProtectDisconnectResult = .disconnected

    /// What an unstubbed launchd change answers: one failed job.
    static let unstubbed = LifecycleBatchResult(jobs: [
        LifecycleJobResult(label: "test.unstubbed", state: .failed, detail: "The test set no stub for this call.")
    ])

    init(file: StaticString = #filePath, line: UInt = #line) {
        self.file = file
        self.line = line
    }

    /// Every stub set: stops signal, waits succeed, launchd changes are not
    /// needed, the app exists and opens, and the VPN disconnects.
    static func allSucceeding(file: StaticString = #filePath, line: UInt = #line) -> FakeLifecycle {
        let lifecycle = FakeLifecycle(file: file, line: line)
        lifecycle.settle = {}
        lifecycle.terminationOutcome = .signalled
        lifecycle.waitResult = true
        lifecycle.agentsResult = .notNeeded
        lifecycle.daemonsResult = .notNeeded
        lifecycle.appExists = true
        lifecycle.openResult = .opened
        lifecycle.disconnect = { .disconnected }
        return lifecycle
    }

    /// The lifecycle view tests start from: every call succeeds except the
    /// GlobalProtect disconnect, which is unavailable, as the protocol's
    /// default answers.
    static func forViewTests(file: StaticString = #filePath, line: UInt = #line) -> FakeLifecycle {
        let lifecycle = allSucceeding(file: file, line: line)
        lifecycle.disconnectResult = .failed("Automatic GlobalProtect disconnect is unavailable. Its services were left running.")
        return lifecycle
    }

    // MARK: Stubs

    var settle: (@Sendable () async -> Void)? {
        get { lock.withLock { _settle } } set { lock.withLock { _settle = newValue } }
    }
    var terminateMain: (@Sendable (WatchedAppPreset) async -> ProcessTerminationOutcome)? {
        get { lock.withLock { _terminateMain } } set { lock.withLock { _terminateMain = newValue } }
    }
    var terminateHelper: (@Sendable (String, WatchedAppPreset) async -> ProcessTerminationOutcome)? {
        get { lock.withLock { _terminateHelper } } set { lock.withLock { _terminateHelper = newValue } }
    }
    var waitForMain: (@Sendable (WatchedAppPreset, TimeInterval) async -> Bool)? {
        get { lock.withLock { _waitForMain } } set { lock.withLock { _waitForMain = newValue } }
    }
    var unloadAgents: Batch? {
        get { lock.withLock { _unloadAgents } } set { lock.withLock { _unloadAgents = newValue } }
    }
    var bootstrapAgents: Batch? {
        get { lock.withLock { _bootstrapAgents } } set { lock.withLock { _bootstrapAgents = newValue } }
    }
    var disableAgents: (@Sendable (WatchedAppPreset, Bool) async -> LifecycleBatchResult)? {
        get { lock.withLock { _disableAgents } } set { lock.withLock { _disableAgents = newValue } }
    }
    var enableAgents: Batch? {
        get { lock.withLock { _enableAgents } } set { lock.withLock { _enableAgents = newValue } }
    }
    var ensureDaemons: Batch? {
        get { lock.withLock { _ensureDaemons } } set { lock.withLock { _ensureDaemons = newValue } }
    }
    var disableDaemons: (@Sendable (WatchedAppPreset, Bool) async -> LifecycleBatchResult)? {
        get { lock.withLock { _disableDaemons } } set { lock.withLock { _disableDaemons = newValue } }
    }
    var enableDaemons: Batch? {
        get { lock.withLock { _enableDaemons } } set { lock.withLock { _enableDaemons = newValue } }
    }
    var appBundleExists: (@Sendable (String) -> Bool)? {
        get { lock.withLock { _appBundleExists } } set { lock.withLock { _appBundleExists = newValue } }
    }
    var openAppBundle: (@Sendable (String) async -> AppBundleOpenResult)? {
        get { lock.withLock { _openAppBundle } } set { lock.withLock { _openAppBundle = newValue } }
    }
    var disconnect: (@Sendable () async -> GlobalProtectDisconnectResult)? {
        get { lock.withLock { _disconnect } } set { lock.withLock { _disconnect = newValue } }
    }

    /// Runs before each agent bootstrap answers, for a test that changes the
    /// world while launchd works.
    var onBootstrapAgents: (@Sendable () async -> Void)? {
        get { lock.withLock { _onBootstrapAgents } } set { lock.withLock { _onBootstrapAgents = newValue } }
    }
    /// Runs before the GlobalProtect disconnect answers.
    var onDisconnect: (@Sendable () async -> Void)? {
        get { lock.withLock { _onDisconnect } } set { lock.withLock { _onDisconnect = newValue } }
    }
    /// Answers a whole preset stop in one call, recorded as `terminate.scope:<scope>`.
    /// Unset, a preset stop runs `terminateMain` and `terminateHelper` per name,
    /// as the production default does.
    var terminateScope: (@Sendable (WatchedAppPreset, PresetStopScope) async -> [ProcessTerminationOutcome])? {
        get { lock.withLock { _terminateScope } } set { lock.withLock { _terminateScope = newValue } }
    }
    /// Runs before each agent disable answers.
    var onDisableAgents: (@Sendable () async -> Void)? {
        get { lock.withLock { _onDisableAgents } } set { lock.withLock { _onDisableAgents = newValue } }
    }

    // MARK: Fixed answers (each sets the stubs it names and keeps its value)

    /// Main and helper stops answer `terminationOutcome`.
    var terminationOutcome: ProcessTerminationOutcome {
        get { lock.withLock { _fixed_terminationOutcome } }
        set {
            lock.withLock { _fixed_terminationOutcome = newValue }
            terminateMain = { _ in newValue }
            terminateHelper = { _, _ in newValue }
        }
    }
    /// Waits for the main process answer `waitResult`.
    var waitResult: Bool {
        get { lock.withLock { _fixed_waitResult } }
        set {
            lock.withLock { _fixed_waitResult = newValue }
            waitForMain = { _, _ in newValue }
        }
    }
    /// Every user launch agent change answers `agentsResult`.
    var agentsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_agentsResult } }
        set {
            lock.withLock { _fixed_agentsResult = newValue }
            unloadAgentsResult = newValue
            bootstrapAgentsResult = newValue
            disableAgentsResult = newValue
            enableAgentsResult = newValue
        }
    }
    /// Every system launch daemon change answers `daemonsResult`.
    var daemonsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_daemonsResult } }
        set {
            lock.withLock { _fixed_daemonsResult = newValue }
            ensureDaemonsResult = newValue
            disableDaemonsResult = newValue
            enableDaemonsResult = newValue
        }
    }
    /// `appBundleExists` answers `appExists` for every path.
    var appExists: Bool {
        get { lock.withLock { _fixed_appExists } }
        set {
            lock.withLock { _fixed_appExists = newValue }
            appBundleExists = { _ in newValue }
        }
    }
    /// `openAppBundle` answers `openResult` for every path.
    var openResult: AppBundleOpenResult {
        get { lock.withLock { _fixed_openResult } }
        set {
            lock.withLock { _fixed_openResult = newValue }
            openAppBundle = { _ in newValue }
        }
    }
    /// Agent unloads answer `unloadAgentsResult`.
    var unloadAgentsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_unloadAgentsResult } }
        set {
            lock.withLock { _fixed_unloadAgentsResult = newValue }
            unloadAgents = { _ in newValue }
        }
    }
    /// Agent bootstraps answer `bootstrapAgentsResult`.
    var bootstrapAgentsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_bootstrapAgentsResult } }
        set {
            lock.withLock { _fixed_bootstrapAgentsResult = newValue }
            bootstrapAgents = { _ in newValue }
        }
    }
    /// Agent disables answer `disableAgentsResult`.
    var disableAgentsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_disableAgentsResult } }
        set {
            lock.withLock { _fixed_disableAgentsResult = newValue }
            disableAgents = { _, _ in newValue }
        }
    }
    /// Agent enables answer `enableAgentsResult`.
    var enableAgentsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_enableAgentsResult } }
        set {
            lock.withLock { _fixed_enableAgentsResult = newValue }
            enableAgents = { _ in newValue }
        }
    }
    /// Daemon checks (`ensureSystemLaunchDaemons`) answer `ensureDaemonsResult`.
    var ensureDaemonsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_ensureDaemonsResult } }
        set {
            lock.withLock { _fixed_ensureDaemonsResult = newValue }
            ensureDaemons = { _ in newValue }
        }
    }
    /// Daemon disables answer `disableDaemonsResult`.
    var disableDaemonsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_disableDaemonsResult } }
        set {
            lock.withLock { _fixed_disableDaemonsResult = newValue }
            disableDaemons = { _, _ in newValue }
        }
    }
    /// Daemon enables answer `enableDaemonsResult`.
    var enableDaemonsResult: LifecycleBatchResult {
        get { lock.withLock { _fixed_enableDaemonsResult } }
        set {
            lock.withLock { _fixed_enableDaemonsResult = newValue }
            enableDaemons = { _ in newValue }
        }
    }
    /// The GlobalProtect disconnect answers `disconnectResult`.
    var disconnectResult: GlobalProtectDisconnectResult {
        get { lock.withLock { _fixed_disconnectResult } }
        set {
            lock.withLock { _fixed_disconnectResult = newValue }
            disconnect = { newValue }
        }
    }

    // MARK: What happened

    /// Each call in order: `settle`, `terminate:<main>`, `terminate.helper:<name>`,
    /// `wait`, `agents.unload`, `agents.load`, `agents.disable`, `agents.enable`,
    /// `daemon`, `daemon.disable:<allow prompt>`, `daemon.enable`, `exists`,
    /// `open`, `vpn.disconnect`.
    var calls: [String] { lock.withLock { callLog } }
    /// The presets each kind of call received, keyed like `calls` without arguments.
    var presetsByCall: [String: [WatchedAppPreset]] { lock.withLock { presetLog } }
    /// The PIDs each agent unload that preserves processes was asked to keep.
    var preservedPIDs: [Set<Int32>] { lock.withLock { preservedPIDLog } }
    /// The bundle path of each `openAppBundle` call.
    var openedPaths: [String] { lock.withLock { openedPathLog } }
    /// Whether each agent disable was asked to preserve the VPN service.
    var preservedVPNServices: [Bool] { lock.withLock { preservedVPNServiceLog } }

    private func record(_ call: String, key: String? = nil, preset: WatchedAppPreset? = nil) {
        lock.withLock {
            callLog.append(call)
            if let key, let preset { presetLog[key, default: []].append(preset) }
        }
    }

    private func unexpected(_ call: String) {
        XCTFail("Unexpected lifecycle call \(call): the test set no stub for it", file: file, line: line)
    }

    // MARK: ProcessLifecycleServicing

    func settleAfterProcessChange() async {
        record("settle")
        guard let settle else { return unexpected("settleAfterProcessChange") }
        await settle()
    }

    func terminateProcesses(for preset: WatchedAppPreset, scope: PresetStopScope) async -> [ProcessTerminationOutcome] {
        if let terminateScope {
            record("terminate.scope:\(scope)", key: "terminate.scope", preset: preset)
            return await terminateScope(preset, scope)
        }
        var outcomes: [ProcessTerminationOutcome] = []
        if scope != .helpers {
            outcomes.append(await terminateMainProcess(for: preset))
        }
        if scope != .app {
            for name in preset.helperProcessNames {
                outcomes.append(await terminateHelperProcess(named: name, for: preset))
            }
        }
        return outcomes
    }

    func terminateMainProcess(for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminate:\(preset.mainProcessName)", key: "terminate", preset: preset)
        guard let terminateMain else {
            unexpected("terminateMainProcess(\(preset.mainProcessName))")
            return .inventoryUnavailable
        }
        return await terminateMain(preset)
    }

    func terminateHelperProcess(named name: String, for preset: WatchedAppPreset) async -> ProcessTerminationOutcome {
        record("terminate.helper:\(name)", key: "helper", preset: preset)
        guard let terminateHelper else {
            unexpected("terminateHelperProcess(\(name))")
            return .inventoryUnavailable
        }
        return await terminateHelper(name, preset)
    }

    func waitForMainProcess(for preset: WatchedAppPreset, timeoutSeconds: TimeInterval) async -> Bool {
        record("wait", key: "wait.main", preset: preset)
        guard let waitForMain else {
            unexpected("waitForMainProcess(\(preset.mainProcessName))")
            return false
        }
        return await waitForMain(preset, timeoutSeconds)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("agents.unload", key: "agents.unload", preset: preset)
        return await answerUnload(for: preset)
    }

    func unloadUserLaunchAgents(for preset: WatchedAppPreset, preservingPIDs: Set<Int32>) async -> LifecycleBatchResult {
        record("agents.unload", key: "agents.unload", preset: preset)
        lock.withLock { preservedPIDLog.append(preservingPIDs) }
        return await answerUnload(for: preset)
    }

    private func answerUnload(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        guard let unloadAgents else {
            unexpected("unloadUserLaunchAgents")
            return Self.unstubbed
        }
        return await unloadAgents(preset)
    }

    func bootstrapUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("agents.load", key: "agents.load", preset: preset)
        await onBootstrapAgents?()
        guard let bootstrapAgents else {
            unexpected("bootstrapUserLaunchAgents")
            return Self.unstubbed
        }
        return await bootstrapAgents(preset)
    }

    func disableUserLaunchAgents(for preset: WatchedAppPreset, preservingVPNService: Bool) async -> LifecycleBatchResult {
        record("agents.disable", key: "agents.disable", preset: preset)
        lock.withLock { preservedVPNServiceLog.append(preservingVPNService) }
        await onDisableAgents?()
        guard let disableAgents else {
            unexpected("disableUserLaunchAgents")
            return Self.unstubbed
        }
        return await disableAgents(preset, preservingVPNService)
    }

    func enableUserLaunchAgents(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("agents.enable", key: "agents.enable", preset: preset)
        guard let enableAgents else {
            unexpected("enableUserLaunchAgents")
            return Self.unstubbed
        }
        return await enableAgents(preset)
    }

    func ensureSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("daemon", key: "daemon", preset: preset)
        guard let ensureDaemons else {
            unexpected("ensureSystemLaunchDaemons")
            return Self.unstubbed
        }
        return await ensureDaemons(preset)
    }

    func disableSystemLaunchDaemons(for preset: WatchedAppPreset, allowAdministratorPrompt: Bool) async -> LifecycleBatchResult {
        record("daemon.disable:\(allowAdministratorPrompt)", key: "daemon.disable", preset: preset)
        guard let disableDaemons else {
            unexpected("disableSystemLaunchDaemons")
            return Self.unstubbed
        }
        return await disableDaemons(preset, allowAdministratorPrompt)
    }

    func enableSystemLaunchDaemons(for preset: WatchedAppPreset) async -> LifecycleBatchResult {
        record("daemon.enable", key: "daemon.enable", preset: preset)
        guard let enableDaemons else {
            unexpected("enableSystemLaunchDaemons")
            return Self.unstubbed
        }
        return await enableDaemons(preset)
    }

    func appBundleExists(at path: String) -> Bool {
        record("exists")
        guard let appBundleExists else {
            unexpected("appBundleExists(\(path))")
            return false
        }
        return appBundleExists(path)
    }

    func openAppBundle(at path: String) async -> AppBundleOpenResult {
        record("open")
        lock.withLock { openedPathLog.append(path) }
        guard let openAppBundle else {
            unexpected("openAppBundle(\(path))")
            return .failed("The test set no stub for this call.")
        }
        return await openAppBundle(path)
    }

    func disconnectGlobalProtectIfNeeded() async -> GlobalProtectDisconnectResult {
        record("vpn.disconnect")
        await onDisconnect?()
        guard let disconnect else {
            unexpected("disconnectGlobalProtectIfNeeded")
            return .failed("The test set no stub for this call.")
        }
        return await disconnect()
    }
}
