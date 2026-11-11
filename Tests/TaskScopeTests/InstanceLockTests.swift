import AppKit
import Darwin
import XCTest
@testable import TaskScope

// A01-8: a launch that meets a TaskScope in the middle of quitting must not hand
// off to it and exit. The running copy holds a per-user single-instance lock.
// Real locks live in a fresh temporary directory per test; where the holder has
// to be another process, a /bin/sleep child holds an inherited locked
// descriptor. AppKit effects go through the batch 2 recording delegate runtime.

private let lockTestBundleID = "example.TaskScope.InstanceLock"

@MainActor
private func lockTestInstance(_ processID: pid_t, start: TimeInterval) -> TaskScopeLaunchSession.Instance {
    .init(processID: processID, userID: 501, bundleIdentifier: lockTestBundleID, startTime: start)
}

/// A launch with PID 10 that started at 100 unless told otherwise. By default
/// any handoff or wait fails the test.
@MainActor
private func lockTestSession(
    _ context: TaskScopeLaunchContext = .interactive,
    processID: pid_t = 10,
    startTime: TimeInterval = 100,
    instances: @escaping @MainActor () -> [TaskScopeLaunchSession.Instance] = { [] },
    lock: TaskScopeInstanceLock?,
    events: @escaping (String) -> Void = { XCTFail("Unexpected handoff: \($0)") },
    pause: @escaping @MainActor (TimeInterval) -> Void = { _ in XCTFail("Unexpected wait") }
) -> TaskScopeLaunchSession {
    TaskScopeLaunchSession(
        context: context,
        runtime: .init(
            bundleIdentifier: lockTestBundleID,
            processID: processID,
            userID: 501,
            runningInstances: instances,
            reopen: { events("reopen \($0)") },
            terminate: { events("terminate") },
            startTime: startTime,
            instanceLock: lock,
            pause: pause
        ),
        standardDefaults: { batch02Defaults() }
    )
}

/// A lock whose attempts follow a script (the last one repeats) and that
/// records every call.
@MainActor
private final class ScriptedInstanceLock {
    private var attempts: [TaskScopeInstanceLockAttempt]
    private(set) var acquisitions: [TaskScopeInstanceRecord] = []
    private(set) var updates: [TaskScopeInstanceRecord] = []
    private(set) var releases = 0
    var onEvent: (String) -> Void = { _ in }

    init(_ attempts: [TaskScopeInstanceLockAttempt]) {
        self.attempts = attempts
    }

    var lock: TaskScopeInstanceLock {
        TaskScopeInstanceLock(
            acquire: { [self] record in
                acquisitions.append(record)
                return attempts.count > 1 ? attempts.removeFirst() : attempts[0]
            },
            update: { [self] record in
                updates.append(record)
                onEvent("update \(record.state.rawValue)")
            },
            release: { [self] in
                releases += 1
                onEvent("release")
            }
        )
    }
}

/// A `/bin/sleep` child of the test process. It is signalled only while it is
/// still this process's unreaped child, whose PID no other process can have.
private final class SleepingChild {
    let processID: pid_t
    private var reaped = false

    /// `inheriting` nil: the child gets every descriptor that is not
    /// close-on-exec, as a plain spawn does; otherwise that descriptor alone.
    init(inheriting descriptor: Int32?) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        if let descriptor {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        }
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
        defer { arguments.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var spawned: pid_t = 0
        let status = posix_spawn(&spawned, "/bin/sleep", &actions, &attributes, &arguments, &environment)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        processID = spawned
    }

    /// Ends the child the way a crash ends a process: SIGKILL, after which the
    /// kernel closes every descriptor it had.
    func kill() {
        var status: Int32 = 0
        guard !reaped, waitpid(processID, &status, WNOHANG) == 0 else {
            reaped = true
            return
        }
        Darwin.kill(processID, SIGKILL)
        while waitpid(processID, &status, 0) == -1, errno == EINTR {}
        reaped = true
    }
}

@MainActor
final class InstanceLockTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var children: [SleepingChild] = []
    private let notification = Notification(name: NSApplication.willFinishLaunchingNotification)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskScope.InstanceLock.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        children.forEach { $0.kill() }
        children = []
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private var lockURL: URL {
        directory.appendingPathComponent(lockTestBundleID, isDirectory: true)
            .appendingPathComponent(TaskScopeInstanceLock.fileName, isDirectory: false)
    }

    private func lockContents() throws -> String {
        try String(contentsOf: lockURL, encoding: .utf8)
    }

    /// A separate process that holds the lock the way a running TaskScope does:
    /// the test locks a descriptor and writes the record, `/bin/sleep` inherits
    /// that descriptor as its only one, and the test closes its own copy, so
    /// the child alone keeps the lock.
    private func startHolder(startTime: TimeInterval) throws -> SleepingChild {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        let child = try SleepingChild(inheriting: descriptor)
        children.append(child)
        let record = TaskScopeInstanceRecord(processID: child.processID, startTime: startTime, state: .running)
        let bytes = Array(record.encoded.utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }, bytes.count)
        return child
    }

    // MARK: - The record and the lock file

    func testTheRecordReadsBackExactlyWhatItWrites() {
        let quitting = TaskScopeInstanceRecord(processID: 4242, startTime: 1_762_791_234.567891, state: .quitting)
        XCTAssertEqual(quitting.encoded, "4242 1762791234.567891 quitting\n")
        XCTAssertEqual(TaskScopeInstanceRecord(decoding: quitting.encoded), quitting)
        let unreadableStart = TaskScopeInstanceRecord(processID: 7, startTime: .greatestFiniteMagnitude, state: .running)
        XCTAssertEqual(TaskScopeInstanceRecord(decoding: unreadableStart.encoded), unreadableStart)

        let rejected = [
            "", "\n", "4242 1.5 running", "4242 1.5 running\n\n", "4242 1.5 running\r\n", "4242 1.5 Running\n",
            "4242 1.5 stopped\n", "4242 1.5\n", "4242 1.5 running extra\n", "4242  1.5 running\n",
            "0 1.5 running\n", "-3 1.5 running\n", "+4242 1.5 running\n", "x 1.5 running\n",
            "99999999999 1.5 running\n", "4242 1.50 running\n", "4242 inf running\n", "4242 nan running\n"
        ]
        for text in rejected {
            XCTAssertNil(TaskScopeInstanceRecord(decoding: text), text.debugDescription)
        }
    }

    func testTheHolderNamesItselfAndNoOtherOpenTakesTheLockUntilItLetsGo() throws {
        let holder = TaskScopeInstanceLock.file(at: lockURL)
        let other = TaskScopeInstanceLock.file(at: lockURL)
        let running = TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .running)
        let quitting = TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .quitting)
        let next = TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .running)

        XCTAssertEqual(holder.acquire(running), .acquired)
        XCTAssertEqual(try lockContents(), running.encoded)
        XCTAssertEqual(other.acquire(next), .held(running))
        XCTAssertEqual(try lockContents(), running.encoded, "A launch that does not get the lock writes nothing")

        holder.update(quitting)
        XCTAssertEqual(other.acquire(next), .held(quitting))
        other.update(next)
        other.release()
        XCTAssertEqual(try lockContents(), quitting.encoded, "Only the holder rewrites the record or lets go")

        holder.release()
        XCTAssertEqual(try lockContents(), "", "The record goes with the lock")
        XCTAssertEqual(other.acquire(next), .acquired)
        XCTAssertEqual(try lockContents(), next.encoded)
        XCTAssertEqual(holder.acquire(running), .held(next))
        other.release()

        let file = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let folder = try FileManager.default.attributesOfItem(atPath: lockURL.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// Dropping the holder without releasing does what the kernel does when the
    /// process dies: the lock goes, and the record stays until the next holder
    /// replaces it.
    func testAHolderThatEndsWithoutReleasingLosesTheLockButLeavesItsRecord() throws {
        let stale = TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .running)
        var holder: TaskScopeInstanceLockFile? = TaskScopeInstanceLockFile(url: lockURL)
        XCTAssertEqual(holder?.acquire(as: stale), .acquired)
        holder = nil
        XCTAssertEqual(try lockContents(), stale.encoded)

        let next = TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .running)
        let lock = TaskScopeInstanceLockFile(url: lockURL)
        XCTAssertEqual(lock.acquire(as: next), .acquired)
        XCTAssertEqual(try lockContents(), next.encoded)
        lock.release()
    }

    /// The holder's descriptor is close-on-exec: a command or app TaskScope
    /// starts, which can outlive it, never keeps the lock.
    func testProcessesTheHolderStartsDoNotKeepTheLock() throws {
        var holder: TaskScopeInstanceLockFile? = TaskScopeInstanceLockFile(url: lockURL)
        XCTAssertEqual(holder?.acquire(as: .init(processID: 41, startTime: 50, state: .running)), .acquired)
        children.append(try SleepingChild(inheriting: nil))
        holder = nil

        let next = TaskScopeInstanceLockFile(url: lockURL)
        XCTAssertEqual(next.acquire(as: .init(processID: 10, startTime: 100, state: .running)), .acquired,
                       "The child that is still running must not hold the lock")
        next.release()
    }

    func testALockFileThatCannotBeUsedIsUnavailable() throws {
        let record = TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .running)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // A symbolic link at the path is refused, and its target is untouched.
        let target = directory.appendingPathComponent("target")
        try Data("keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        XCTAssertEqual(TaskScopeInstanceLock.file(at: lockURL).acquire(record), .unavailable)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
        try FileManager.default.removeItem(at: lockURL)

        // A FIFO at the path is refused without blocking the launch.
        XCTAssertEqual(mkfifo(lockURL.path, 0o600), 0)
        XCTAssertEqual(TaskScopeInstanceLock.file(at: lockURL).acquire(record), .unavailable)
        try FileManager.default.removeItem(at: lockURL)

        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        XCTAssertEqual(TaskScopeInstanceLock.file(at: lockURL).acquire(record), .unavailable)

        // The folder cannot be created: a file has its name.
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let underFile = blocked.appendingPathComponent(TaskScopeInstanceLock.fileName)
        XCTAssertEqual(TaskScopeInstanceLock.file(at: underFile).acquire(record), .unavailable)
    }

    /// One lock per user and bundle identifier: the packaging tests' staged
    /// copy, with its own identifier, never meets the installed app's lock.
    func testEachBundleIdentifierHasItsOwnLockInApplicationSupport() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)
        let installed = TaskScopeInstanceLock.fileURL(bundleIdentifier: "com.local.TaskScope", applicationSupport: support)
        let staged = TaskScopeInstanceLock.fileURL(
            bundleIdentifier: "com.example.TaskScopeTests.Run0F1E2D3C4B5A69788796A5B4C3D2E1F0", applicationSupport: support
        )
        XCTAssertEqual(installed?.path, "/Users/example/Library/Application Support/com.local.TaskScope/Instance.lock")
        XCTAssertEqual(
            staged?.path,
            "/Users/example/Library/Application Support/com.example.TaskScopeTests.Run0F1E2D3C4B5A69788796A5B4C3D2E1F0/Instance.lock"
        )
        let invalid: [String?] = [
            nil, "", ".", "..", ".TaskScope", "com/local/TaskScope", "com.local.TaskScope ", "com.local.TaskScope\n",
            "com.lokal.TäskScope"
        ]
        for identifier in invalid {
            XCTAssertNil(
                TaskScopeInstanceLock.fileURL(bundleIdentifier: identifier, applicationSupport: support),
                String(describing: identifier)
            )
        }
        XCTAssertNil(TaskScopeInstanceLock.fileURL(bundleIdentifier: "com.local.TaskScope", applicationSupport: nil))
    }

    // MARK: - A crashed holder

    /// The kernel drops a crashed holder's lock. The next launch takes it and
    /// becomes the instance even though the dead process is still listed, as
    /// NSRunningApplication can list it for a moment.
    func testACrashedHolderLeavesTheLockToTheNextLaunchWhileItIsStillListed() throws {
        let holder = try startHolder(startTime: 50)
        let listing = lockTestInstance(holder.processID, start: 50)

        var events: [String] = []
        let duplicate = lockTestSession(instances: { [listing] }, lock: .file(at: lockURL), events: { events.append($0) })
        defer { duplicate.cleanUp() }
        XCTAssertFalse(duplicate.continueLaunching(), "A live holder keeps a launch from becoming a second instance")
        XCTAssertFalse(duplicate.allowsRuntime)
        XCTAssertEqual(events, ["reopen \(holder.processID)", "terminate"])

        holder.kill()
        let next = lockTestSession(processID: 11, startTime: 150, instances: { [listing] }, lock: .file(at: lockURL))
        defer { next.cleanUp() }
        XCTAssertTrue(next.continueLaunching(), "No handoff to a process that died")
        XCTAssertTrue(next.allowsRuntime)
        XCTAssertTrue(next.holdsInstanceLock)
        XCTAssertEqual(try lockContents(), TaskScopeInstanceRecord(processID: 11, startTime: 150, state: .running).encoded)
    }

    // MARK: - A holder that is quitting

    /// A copy quitting with an action in flight keeps the lock and says it is
    /// quitting. A launch waits for it instead of handing off to it, then
    /// becomes the instance once it lets go.
    func testALaunchWaitsForAQuittingHolderAndThenBecomesTheInstance() throws {
        let holder = lockTestSession(processID: 41, startTime: 50, lock: .file(at: lockURL))
        defer { holder.cleanUp() }
        XCTAssertTrue(holder.holdsInstanceLock)
        holder.markQuitting()
        XCTAssertEqual(try lockContents(), TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .quitting).encoded)

        var pauses: [TimeInterval] = []
        var standardReads = 0
        let launch = TaskScopeLaunchSession(
            context: .interactive,
            runtime: .init(
                bundleIdentifier: lockTestBundleID, processID: 10, userID: 501,
                runningInstances: { [lockTestInstance(41, start: 50)] },
                reopen: { _ in XCTFail("No handoff to a copy that is quitting") },
                terminate: { XCTFail("A launch that meets a quitting copy must not quit") },
                startTime: 100,
                instanceLock: .file(at: lockURL),
                pause: { interval in
                    pauses.append(interval)
                    XCTAssertEqual(standardReads, 0, "Preferences are read only after the quitting copy saved them")
                    // The quitting copy's action ends during the third wait.
                    if pauses.count == 3 { holder.releaseInstanceLock() }
                }
            ),
            standardDefaults: {
                standardReads += 1
                return batch02Defaults()
            }
        )
        defer { launch.cleanUp() }

        XCTAssertEqual(pauses, Array(repeating: TaskScopeLaunchSession.quittingHolderWait.interval, count: 3))
        XCTAssertTrue(launch.continueLaunching())
        XCTAssertTrue(launch.allowsRuntime)
        XCTAssertTrue(launch.holdsInstanceLock)
        XCTAssertEqual(standardReads, 1)
        XCTAssertEqual(try lockContents(), TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .running).encoded)
    }

    /// The quit path itself, through the delegate. After an immediate quit, or
    /// once the action a quit waited for is over, the copy has let the lock go;
    /// a launch then becomes the instance although the copy is still listed.
    func testALaunchAfterTheQuittingCopyLetGoBecomesTheInstanceWhileThatCopyIsStillListed() async throws {
        for actionInFlight in [false, true] {
            let recorder = Batch02DelegateRecorder()
            recorder.mutationActive = actionInFlight
            let gate = Batch02Gate()
            let holder = lockTestSession(.loginItem, processID: 41, startTime: 50, lock: .file(at: lockURL))
            defer { holder.cleanUp() }
            let delegate = makeBatch02Delegate(holder, recorder, launchedAsLoginItem: true,
                                               waitForTerminationTick: { await gate.wait() })
            delegate.applicationWillFinishLaunching(notification)
            delegate.applicationDidFinishLaunching(notification)

            let probe = TaskScopeInstanceLock.file(at: lockURL)
            let probeRecord = TaskScopeInstanceRecord(processID: 99, startTime: 1, state: .running)
            if actionInFlight {
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                XCTAssertEqual(probe.acquire(probeRecord),
                               .held(.init(processID: 41, startTime: 50, state: .quitting)),
                               "While the action runs the copy keeps the lock and says it is quitting")
                recorder.mutationActive = false
                await gate.open()
                for _ in 0..<200 where recorder.replies.isEmpty { await Task.yield() }
                XCTAssertEqual(recorder.replies, [true])
            } else {
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
                XCTAssertEqual(probe.acquire(probeRecord),
                               .held(.init(processID: 41, startTime: 50, state: .running)),
                               "Will-terminate follows at once and lets go")
            }
            delegate.applicationWillTerminate(notification)
            XCTAssertFalse(holder.holdsInstanceLock)

            // Under the earlier-start rule alone this launch handed off to PID 41 and quit.
            let next = lockTestSession(instances: { [lockTestInstance(41, start: 50)] }, lock: .file(at: lockURL))
            XCTAssertTrue(next.continueLaunching(), "actionInFlight=\(actionInFlight)")
            XCTAssertTrue(next.allowsRuntime)
            XCTAssertTrue(next.holdsInstanceLock)
            next.cleanUp()
        }
    }

    /// The order on the quit path: an immediate quit lets go right after the
    /// runtime stopped and saved settings, before anything else; a quit that
    /// waits for an action marks the copy quitting at once and lets go only
    /// after the action is over and its commands are stopped, before replying.
    func testTheQuitPathLetsTheLockGoOnlyOnceNothingCanCollideWithANewInstance() async {
        let relevant: Set = ["stop runtime", "stop running commands", "update quitting", "release"]

        let immediate = Batch02DelegateRecorder()
        let immediateLock = ScriptedInstanceLock([.acquired])
        immediateLock.onEvent = { immediate.events.append($0) }
        let immediateSession = lockTestSession(.loginItem, lock: immediateLock.lock)
        let immediateDelegate = makeBatch02Delegate(immediateSession, immediate, launchedAsLoginItem: true)
        immediateDelegate.applicationWillFinishLaunching(notification)
        immediateDelegate.applicationDidFinishLaunching(notification)
        XCTAssertEqual(immediateDelegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(immediate.events.filter(relevant.contains), [], "Will-terminate follows at once")
        immediateDelegate.applicationWillTerminate(notification)
        immediateSession.cleanUp()
        XCTAssertEqual(immediate.events.filter(relevant.contains), ["stop runtime", "release", "stop running commands"])
        XCTAssertEqual(immediateLock.releases, 1)

        let waiting = Batch02DelegateRecorder()
        waiting.mutationActive = true
        let gate = Batch02Gate()
        let waitingLock = ScriptedInstanceLock([.acquired])
        var releasedBeforeReply: Bool?
        waitingLock.onEvent = { event in
            waiting.events.append(event)
            if event == "release" { releasedBeforeReply = waiting.replies.isEmpty }
        }
        let waitingSession = lockTestSession(.loginItem, lock: waitingLock.lock)
        let waitingDelegate = makeBatch02Delegate(waitingSession, waiting, launchedAsLoginItem: true,
                                                  waitForTerminationTick: { await gate.wait() })
        waitingDelegate.applicationWillFinishLaunching(notification)
        waitingDelegate.applicationDidFinishLaunching(notification)
        XCTAssertEqual(waitingDelegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(waitingDelegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(waiting.events.filter(relevant.contains), ["update quitting", "stop runtime"],
                       "Marked once; the lock is kept while the action runs")
        XCTAssertTrue(waitingSession.holdsInstanceLock)

        waiting.mutationActive = false
        await gate.open()
        for _ in 0..<200 where waiting.replies.isEmpty { await Task.yield() }
        XCTAssertEqual(waiting.replies, [true])
        XCTAssertEqual(releasedBeforeReply, true)
        waitingDelegate.applicationWillTerminate(notification)
        waitingSession.cleanUp()
        XCTAssertEqual(waiting.events.filter(relevant.contains),
                       ["update quitting", "stop runtime", "stop running commands", "release", "stop runtime",
                        "stop running commands"])
        XCTAssertEqual(waitingLock.updates, [TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .quitting)])
        XCTAssertEqual(waitingLock.releases, 1)
    }

    /// A copy that stays "quitting" far longer than a quit can keep the lock
    /// (about six seconds: five for the action, one to stop its commands) is
    /// not quitting normally; after the wait the earlier-start rule decides.
    func testAQuittingHolderThatNeverLetsGoIsDecidedByTheEarlierStartRuleAfterTheWait() {
        let wait = TaskScopeLaunchSession.quittingHolderWait
        XCTAssertGreaterThan(Double(wait.attempts) * wait.interval, 6)
        let quitting = TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .quitting)
        var pauses: [TimeInterval] = []
        var events: [String] = []
        let session = lockTestSession(
            instances: { [lockTestInstance(41, start: 50)] }, lock: ScriptedInstanceLock([.held(quitting)]).lock,
            events: { events.append($0) }, pause: { pauses.append($0) }
        )
        defer { session.cleanUp() }
        XCTAssertEqual(pauses, Array(repeating: wait.interval, count: wait.attempts))
        XCTAssertFalse(session.continueLaunching())
        XCTAssertEqual(events, ["reopen 41", "terminate"])
        XCTAssertFalse(session.holdsInstanceLock)
    }

    // MARK: - Two launches racing

    /// Two copies started together: the one that takes the lock is the instance,
    /// even if it started later, and the other hands off to it. They can never
    /// both hand off or both run.
    func testTwoLaunchesRacingLeaveExactlyOneInstance() {
        var firstEvents: [String] = []
        var secondEvents: [String] = []
        let first = lockTestSession(processID: 10, startTime: 200, instances: { [lockTestInstance(11, start: 100)] },
                                    lock: .file(at: lockURL), events: { firstEvents.append($0) })
        defer { first.cleanUp() }
        let second = lockTestSession(processID: 11, startTime: 100, instances: { [lockTestInstance(10, start: 200)] },
                                     lock: .file(at: lockURL), events: { secondEvents.append($0) })
        defer { second.cleanUp() }

        XCTAssertTrue(first.continueLaunching())
        XCTAssertTrue(first.allowsRuntime)
        XCTAssertTrue(first.holdsInstanceLock)
        XCTAssertFalse(second.continueLaunching(), "The copy that started earlier still yields to the holder")
        XCTAssertFalse(second.allowsRuntime)
        XCTAssertFalse(second.holdsInstanceLock)
        XCTAssertEqual(firstEvents, [])
        XCTAssertEqual(secondEvents, ["reopen 10", "terminate"])
    }

    /// The holder writes its record right after locking. A launch that looks in
    /// between, or before the holder is listed, tries again briefly and then
    /// hands off to it.
    func testALaunchWaitsBrieflyForTheHolderToNameItselfAndBeListed() {
        let holder = TaskScopeInstanceRecord(processID: 41, startTime: 50, state: .running)
        let script = ScriptedInstanceLock([.held(nil), .held(nil), .held(holder)])
        var listings = 0
        var pauses: [TimeInterval] = []
        var events: [String] = []
        let session = lockTestSession(
            instances: {
                listings += 1
                return listings == 1 ? [] : [lockTestInstance(41, start: 50)]
            },
            lock: script.lock, events: { events.append($0) }, pause: { pauses.append($0) }
        )
        defer { session.cleanUp() }

        XCTAssertEqual(pauses, Array(repeating: TaskScopeLaunchSession.holderRecordWait.interval, count: 3))
        XCTAssertFalse(session.continueLaunching())
        XCTAssertEqual(events, ["reopen 41", "terminate"])
        XCTAssertEqual(script.acquisitions,
                       Array(repeating: TaskScopeInstanceRecord(processID: 10, startTime: 100, state: .running), count: 4))
    }

    /// A lock whose holder never shows up as a listed TaskScope (no record, a
    /// record from a process that has since been replaced, or this launch's own
    /// recycled PID) is decided by the earlier-start rule after a bounded wait.
    func testAnUnidentifiableHolderFallsBackToTheEarlierStartRule() {
        let wait = TaskScopeLaunchSession.holderRecordWait
        let cases: [(attempt: TaskScopeInstanceLockAttempt, listed: TaskScopeLaunchSession.Instance?, handsOff: Bool)] = [
            (.held(nil), lockTestInstance(41, start: 50), true),
            (.held(.init(processID: 41, startTime: 49, state: .running)), lockTestInstance(41, start: 50), true),
            (.held(nil), lockTestInstance(41, start: 150), false),
            (.held(.init(processID: 10, startTime: 100, state: .running)), nil, false)
        ]
        for (attempt, listed, handsOff) in cases {
            var pauses: [TimeInterval] = []
            var events: [String] = []
            let session = lockTestSession(
                instances: { listed.map { [$0] } ?? [] }, lock: ScriptedInstanceLock([attempt]).lock,
                events: { events.append($0) }, pause: { pauses.append($0) }
            )
            defer { session.cleanUp() }
            XCTAssertEqual(pauses, Array(repeating: wait.interval, count: wait.attempts), "\(attempt)")
            XCTAssertEqual(session.continueLaunching(), !handsOff, "\(attempt)")
            XCTAssertEqual(events, handsOff ? ["reopen 41", "terminate"] : [], "\(attempt)")
            XCTAssertFalse(session.holdsInstanceLock)
        }
    }

    func testWithoutAUsableLockTheEarlierStartRuleDecidesAtOnce() {
        for (listed, handsOff) in [(lockTestInstance(41, start: 50), true), (lockTestInstance(41, start: 150), false)] {
            var events: [String] = []
            let session = lockTestSession(instances: { [listed] }, lock: ScriptedInstanceLock([.unavailable]).lock,
                                          events: { events.append($0) })
            defer { session.cleanUp() }
            XCTAssertEqual(session.continueLaunching(), !handsOff)
            XCTAssertEqual(events, handsOff ? ["reopen 41", "terminate"] : [])
            XCTAssertFalse(session.holdsInstanceLock)
        }
    }

    // MARK: - Startup verification

    /// `--verify-startup` never takes, waits for, rewrites or lets go the lock,
    /// even with a TaskScope running and on its own quit path, and creates
    /// nothing in Application Support.
    func testStartupVerificationNeverTouchesTheLock() async throws {
        let untouchable = TaskScopeInstanceLock(
            acquire: { _ in XCTFail("Verification must not take the lock"); return .unavailable },
            update: { _ in XCTFail("Verification must not write a record") },
            release: { XCTFail("Verification must not let a lock go") }
        )
        let verification = lockTestSession(.startupVerification, instances: { [lockTestInstance(41, start: 50)] },
                                           lock: untouchable)
        XCTAssertTrue(verification.continueLaunching(), "Verification never hands off to the running app")
        XCTAssertFalse(verification.allowsRuntime)
        XCTAssertFalse(verification.holdsInstanceLock)

        let recorder = Batch02DelegateRecorder()
        recorder.mutationActive = true
        let delegate = makeBatch02Delegate(verification, recorder, arguments: ["TaskScope", "--verify-startup"])
        delegate.applicationWillFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        for _ in 0..<200 where recorder.replies.isEmpty { await Task.yield() }
        delegate.applicationWillTerminate(notification)
        verification.cleanUp()

        let real = lockTestSession(.startupVerification, lock: .file(at: lockURL))
        defer { real.cleanUp() }
        XCTAssertTrue(real.continueLaunching())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Nothing was created for the lock")

        let holder = lockTestSession(processID: 41, startTime: 50, lock: .file(at: lockURL))
        defer { holder.cleanUp() }
        let running = try lockContents()
        let beside = lockTestSession(.startupVerification, instances: { [lockTestInstance(41, start: 50)] },
                                     lock: .file(at: lockURL))
        XCTAssertTrue(beside.continueLaunching())
        beside.cleanUp()
        XCTAssertTrue(holder.holdsInstanceLock)
        XCTAssertEqual(try lockContents(), running, "The running copy's record is untouched")
    }
}
