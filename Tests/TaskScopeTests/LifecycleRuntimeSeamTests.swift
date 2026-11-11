import Darwin
import Foundation
import XCTest
@testable import TaskScope

/// The lifecycle runtime seam: `.live` names the real implementation of every
/// side effect, `liveSendSignal` maps kill(2)'s answers, and the production
/// lifecycle service sends every call through the runtime it was given.
final class LifecycleRuntimeSeamTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-runtime-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - .live

    func testLiveRuntimeReadsTheRealSystem() async throws {
        let live = ProcessLifecycleRuntime.live
        XCTAssertEqual(live.userID, getuid())

        let plist = temporaryDirectory.appendingPathComponent("com.example.taskscope-seam.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.taskscope-seam", "ProgramArguments": ["/usr/bin/true"]],
            format: .xml, options: 0
        )
        try data.write(to: plist)
        XCTAssertTrue(live.fileExists(plist.path))
        XCTAssertFalse(live.fileExists(temporaryDirectory.appendingPathComponent("absent.plist").path))
        XCTAssertEqual(live.launchAgentLabel(plist.path), "com.example.taskscope-seam")
        XCTAssertNil(live.launchAgentLabel(temporaryDirectory.appendingPathComponent("absent.plist").path))

        let bundle = temporaryDirectory.appendingPathComponent("Seam.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(live.isAppBundle(bundle.path))
        XCTAssertFalse(live.isAppBundle(temporaryDirectory.path))

        let ownPath = live.executablePathForPID(getpid())
        XCTAssertNotNil(ownPath)
        XCTAssertEqual(ownPath, ProcessListReader.executablePath(for: getpid()))
        XCTAssertTrue(live.isProcessAlive(getpid()))

        let before = ProcessInfo.processInfo.systemUptime
        let uptime = live.systemUptime()
        XCTAssertGreaterThanOrEqual(uptime, before)
        XCTAssertLessThan(uptime - before, 5)
        await live.sleep(1_000_000)
        XCTAssertGreaterThan(live.systemUptime(), uptime)
    }

    /// The only real signal here goes to a child this test started itself.
    func testLiveSignalReachesTheTestsOwnChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            if child.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
                child.waitUntilExit()
            }
        }

        XCTAssertTrue(ProcessLifecycleRuntime.live.isProcessAlive(pid))
        XCTAssertTrue(ProcessLifecycleRuntime.live.sendSignal(SIGTERM, pid))
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    // MARK: - liveSendSignal

    func testLiveSendSignalMapsKillAnswersWithoutSignalling() {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(pid: Int32, signal: Int32)] = []
            var all: [(pid: Int32, signal: Int32)] { lock.withLock { entries } }
            func append(_ pid: Int32, _ signal: Int32) { lock.withLock { entries.append((pid, signal)) } }
        }
        let calls = Calls()
        func kill(answering result: Int32, errno code: Int32) -> DarwinProcessSignaler.KillCall {
            { pid, signal in
                calls.append(pid, signal)
                return (result, code)
            }
        }

        for pid: Int32 in [1, 0, -1, -4242] {
            XCTAssertFalse(ProcessLifecycleRuntime.liveSendSignal(SIGTERM, to: pid, kill: kill(answering: 0, errno: 0)))
        }
        XCTAssertTrue(calls.all.isEmpty, "launchd, pid 0 and process groups never reach kill(2)")

        XCTAssertTrue(ProcessLifecycleRuntime.liveSendSignal(SIGTERM, to: 4242, kill: kill(answering: 0, errno: 0)))
        XCTAssertTrue(
            ProcessLifecycleRuntime.liveSendSignal(SIGKILL, to: 4243, kill: kill(answering: -1, errno: ESRCH)),
            "A target that no longer exists is already stopped"
        )
        XCTAssertFalse(ProcessLifecycleRuntime.liveSendSignal(SIGTERM, to: 4244, kill: kill(answering: -1, errno: EPERM)))
        XCTAssertEqual(calls.all.map(\.pid), [4242, 4243, 4244])
        XCTAssertEqual(calls.all.map(\.signal), [SIGTERM, SIGKILL, SIGTERM])
    }

    // MARK: - SystemProcessLifecycleService

    /// Every method of the production service acts through the injected
    /// runtime. Had one fallen back to `.live`, its fake effect would be
    /// missing here (and it would have touched the real system).
    func testServiceSendsEveryCallThroughItsRuntime() async {
        let recorder = SeamRecorder(appPath: "/Applications/SeamExample.app")
        let service = SystemProcessLifecycleService(runtime: recorder.runtime, disconnect: { .disconnected })
        let preset = WatchedAppPreset(
            displayName: "SeamExample",
            mainProcessName: "SeamExample",
            helperProcessNames: ["SeamHelper"],
            protectedProcessNames: [],
            appPath: "/Applications/SeamExample.app",
            userLaunchAgentJobs: [UserLaunchAgentJob(label: "com.example.seam", plistPath: "/Users/Shared/com.example.seam.plist")]
        )
        let agentTarget = "gui/\(recorder.runtime.userID)/com.example.seam"

        XCTAssertTrue(service.appBundleExists(at: preset.appPath))
        XCTAssertEqual(recorder.bundleChecks, [preset.appPath])

        await service.settleAfterProcessChange()
        XCTAssertEqual(recorder.sleeps, [300_000_000])

        var loads = recorder.inventoryLoads
        _ = await service.terminateMainProcess(for: preset)
        XCTAssertEqual(recorder.inventoryLoads, loads + 1)
        loads = recorder.inventoryLoads
        _ = await service.terminateHelperProcess(named: "SeamHelper", for: preset)
        XCTAssertEqual(recorder.inventoryLoads, loads + 1)
        loads = recorder.inventoryLoads
        _ = await service.terminateProcesses(for: preset, scope: .all)
        XCTAssertEqual(recorder.inventoryLoads, loads + 2, "One read for the main process, one for the helpers")
        loads = recorder.inventoryLoads
        _ = await service.waitForMainProcess(for: preset, timeoutSeconds: 0)
        XCTAssertEqual(recorder.inventoryLoads, loads + 1)

        recorder.clearCommands()
        _ = await service.unloadUserLaunchAgents(for: preset)
        XCTAssertEqual(recorder.commands, ["/bin/launchctl print \(ShellCommandRunner.shellQuoted(agentTarget))"])
        recorder.clearCommands()
        _ = await service.unloadUserLaunchAgents(for: preset, preservingPIDs: [4242])
        XCTAssertEqual(recorder.commands, ["/bin/launchctl print \(ShellCommandRunner.shellQuoted(agentTarget))"])
        recorder.clearCommands()
        _ = await service.disableUserLaunchAgents(for: preset, preservingVPNService: false)
        XCTAssertEqual(recorder.commands.first, "/bin/launchctl disable \(ShellCommandRunner.shellQuoted(agentTarget))")
        recorder.clearCommands()
        _ = await service.enableUserLaunchAgents(for: preset)
        XCTAssertEqual(recorder.commands.first, "/bin/launchctl print-disabled \(ShellCommandRunner.shellQuoted("gui/\(recorder.runtime.userID)"))")
        recorder.clearFileChecks()
        _ = await service.bootstrapUserLaunchAgents(for: preset)
        XCTAssertEqual(recorder.fileChecks, ["/Users/Shared/com.example.seam.plist"])

        recorder.clearFileChecks()
        _ = await service.ensureSystemLaunchDaemons(for: .globalProtect)
        XCTAssertEqual(recorder.fileChecks.first, WatchedAppPreset.globalProtectSessionAgent.plistPath)
        recorder.clearCommands()
        _ = await service.disableSystemLaunchDaemons(for: .globalProtect, allowAdministratorPrompt: false)
        XCTAssertTrue(recorder.commands.contains("/bin/launchctl print-disabled system"))
        recorder.clearCommands()
        recorder.clearFileChecks()
        _ = await service.enableSystemLaunchDaemons(for: .globalProtect)
        XCTAssertEqual(recorder.fileChecks.first, WatchedAppPreset.globalProtectSessionAgent.plistPath)
        XCTAssertTrue(recorder.commands.contains("/bin/launchctl print-disabled system"))

        recorder.clearCommands()
        let opened = await service.openAppBundle(at: preset.appPath)
        XCTAssertEqual(opened, .opened)
        XCTAssertEqual(recorder.commands, ["/usr/bin/open \(ShellCommandRunner.shellQuoted(preset.appPath))"])

        let disconnect = await service.disconnectGlobalProtectIfNeeded()
        XCTAssertEqual(disconnect, .disconnected)

        XCTAssertTrue(recorder.allCommands.allSatisfy { !$0.contains("osascript") }, "No administrator request")
        XCTAssertTrue(recorder.signals.isEmpty, "Nothing matched, so nothing was signalled")
    }

    /// Without an explicit disconnect, an injected runtime never reaches the
    /// live Accessibility disconnect that drives the real GlobalProtect app.
    func testInjectedRuntimeDisconnectFailsClosed() async {
        let recorder = SeamRecorder(appPath: "/Applications/SeamExample.app")
        let result = await SystemProcessLifecycleService(runtime: recorder.runtime).disconnectGlobalProtectIfNeeded()
        guard case .failed(let detail) = result else {
            return XCTFail("Expected a failed disconnect, got \(result)")
        }
        XCTAssertTrue(detail.contains("unavailable"))
        XCTAssertTrue(recorder.allCommands.isEmpty)
    }
}

/// A runtime whose every member records its use and acts on nothing real.
private final class SeamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let appPath: String
    private var recordedCommands: [String] = []
    private var everyCommand: [String] = []
    private var recordedFileChecks: [String] = []
    private var recordedBundleChecks: [String] = []
    private var recordedSleeps: [UInt64] = []
    private var recordedInventoryLoads = 0
    private var recordedSignals: [Int32] = []

    init(appPath: String) {
        self.appPath = appPath
    }

    var commands: [String] { lock.withLock { recordedCommands } }
    var allCommands: [String] { lock.withLock { everyCommand } }
    var fileChecks: [String] { lock.withLock { recordedFileChecks } }
    var bundleChecks: [String] { lock.withLock { recordedBundleChecks } }
    var sleeps: [UInt64] { lock.withLock { recordedSleeps } }
    var inventoryLoads: Int { lock.withLock { recordedInventoryLoads } }
    var signals: [Int32] { lock.withLock { recordedSignals } }
    func clearCommands() { lock.withLock { recordedCommands.removeAll() } }
    func clearFileChecks() { lock.withLock { recordedFileChecks.removeAll() } }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in
                lock.withLock {
                    recordedFileChecks.append(path)
                    return path == appPath
                }
            },
            launchAgentLabel: { _ in nil },
            runCommand: { [self] command, _ in
                lock.withLock {
                    recordedCommands.append(command)
                    everyCommand.append(command)
                }
                if command.hasPrefix("/bin/launchctl print-disabled") || command.hasPrefix("/usr/bin/open ")
                    || command.hasPrefix("/bin/launchctl disable") || command.hasPrefix("/bin/launchctl enable") {
                    return ShellCommandResult(command: command, stdout: "", stderr: "", exitCode: 0)
                }
                let label = command.split(separator: "/").last.map(String.init) ?? ""
                return ShellCommandResult(
                    command: command,
                    stdout: "",
                    stderr: "Could not find service \"\(label.trimmingCharacters(in: CharacterSet(charactersIn: "'")))\" in domain",
                    exitCode: 113
                )
            },
            loadProcessInventory: { [self] in
                lock.withLock { recordedInventoryLoads += 1 }
                return .success([])
            },
            executablePathForPID: { _ in nil },
            sendSignal: { [self] signal, _ in
                lock.withLock { recordedSignals.append(signal) }
                XCTFail("No signal may be sent")
                return false
            },
            isProcessAlive: { _ in false },
            sleep: { [self] nanoseconds in lock.withLock { recordedSleeps.append(nanoseconds) } },
            systemUptime: { 0 },
            isAppBundle: { [self] path in
                lock.withLock {
                    recordedBundleChecks.append(path)
                    return path == appPath
                }
            }
        )
    }
}
