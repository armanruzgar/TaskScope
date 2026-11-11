import Darwin
import Foundation

enum ShellCommandRunner {
    /// Exit code reported when the calling task was cancelled.
    static let cancelledExitCode: Int32 = -2
    /// Exit code reported when the command outlived its timeout.
    static let timedOutExitCode: Int32 = -3

    /// Every command in flight. Quitting stops them through it: a command
    /// nothing supervises any more keeps running, re-parented to launchd, with
    /// its timeout gone.
    static let liveExecutions = ExecutionRegistry()

    /// Stand-ins for the system calls a command makes. Production uses the
    /// defaults; tests use them to reach failure paths and race windows.
    struct Hooks: Sendable {
        /// Creates one pipe, as `pipe(2)` does.
        var makePipe: @Sendable (UnsafeMutablePointer<Int32>) -> Int32 = { Darwin.pipe($0) }
        /// Signals every process in a group, as `kill(-group, signal)` does.
        var signalGroup: @Sendable (_ group: pid_t, _ signal: Int32) -> Int32 = { Darwin.kill(-$0, $1) }
        /// Runs after the child was reaped and before its exit is processed.
        var afterReap: @Sendable () -> Void = {}
        /// Tracks the command while it runs.
        var registry: ExecutionRegistry = ShellCommandRunner.liveExecutions
        /// The environment the app inherited, which `childEnvironment(from:)`
        /// scrubs into the child's.
        var inheritedEnvironment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }

        init() {}
    }

    /// Runs `executable` with `arguments` and no shell: `posix_spawn` receives
    /// them as the argument vector exactly as given, so no argument is split,
    /// expanded or read as shell syntax. `executable` must be an absolute path,
    /// and no argument may contain a NUL character; such a command fails
    /// without starting. Timeout, cancellation, process-group containment and
    /// the scrubbed environment are the same as for the string form.
    static func run(
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval = 15,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        },
        hooks: Hooks = Hooks()
    ) async -> ShellCommandResult {
        let command = ExternalCommand(executable, arguments)
        return await execute(
            argumentVector: command.argumentVector,
            displayCommand: command.description,
            timeout: timeout,
            waitForChild: waitForChild,
            hooks: hooks
        )
    }

    /// Runs `command` as `run(executable:arguments:)` does.
    static func run(
        _ command: ExternalCommand,
        timeout: TimeInterval = 15,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        },
        hooks: Hooks = Hooks()
    ) async -> ShellCommandResult {
        await run(
            executable: command.executable,
            arguments: command.arguments,
            timeout: timeout,
            waitForChild: waitForChild,
            hooks: hooks
        )
    }

    /// Runs one command string through `/bin/zsh -f -c`. Prefer
    /// `run(executable:arguments:)`: here every interpolated value must be
    /// quoted with `shellQuoted` to stay one argument.
    static func run(
        _ command: String,
        timeout: TimeInterval = 15,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = {
            Darwin.waitpid($0, $1, $2)
        },
        hooks: Hooks = Hooks()
    ) async -> ShellCommandResult {
        await execute(
            argumentVector: shellArguments + [command],
            displayCommand: command,
            timeout: timeout,
            waitForChild: waitForChild,
            hooks: hooks
        )
    }

    /// Both forms end here: `argumentVector[0]` is spawned with the whole
    /// vector, and `displayCommand` is what the result reports as its command.
    private static func execute(
        argumentVector: [String],
        displayCommand: String,
        timeout: TimeInterval,
        waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t,
        hooks: Hooks
    ) async -> ShellCommandResult {
        if let problem = ExternalCommand.startProblem(argumentVector: argumentVector) {
            return ShellCommandResult(
                command: displayCommand,
                stdout: "",
                stderr: "Could not start the command: \(problem).",
                exitCode: -1
            )
        }
        let execution = CommandExecution(
            argumentVector: argumentVector,
            displayCommand: displayCommand,
            timeout: timeout,
            waitForChild: waitForChild,
            hooks: hooks
        )
        if !hooks.registry.register(execution) {
            // TaskScope is quitting: never start a command nothing would stop.
            execution.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            // An AppleScript literal cannot span source lines, but collapsing
            // newlines to spaces destroys shell syntax: `else` and `fi` are only
            // keywords after a command terminator. Emit the `\n` escape so the
            // string AppleScript hands to /bin/sh keeps its real line breaks.
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Variables that change what a shell runs rather than what a command
    /// reads. `do shell script` hands osascript's environment to `/bin/sh`
    /// (bash), and with administrator privileges that shell runs as root, so
    /// a value set for the login session (`launchctl setenv`) could otherwise
    /// define an `echo` function or a traced `PS4` inside the elevated script.
    static let shellControlVariables: Set<String> = [
        "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4", "CDPATH", "GLOBIGNORE", "IFS"
    ]

    /// Keep dates and decimals in the C locale while preserving UTF-8 names.
    /// Remove inherited locale overrides and pin UTC so `ps lstart` identities
    /// do not change when the system time zone changes. Drop the variables
    /// that change how a shell or the dynamic loader runs a command, and
    /// exported bash functions.
    static func childEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var sanitized = environment.filter { key, _ in
            key != "LANG" && !key.hasPrefix("LC_")
                && !shellControlVariables.contains(key)
                && !key.hasPrefix("BASH_FUNC_") && !key.hasPrefix("DYLD_")
        }
        sanitized["LC_CTYPE"] = "UTF-8"
        sanitized["LC_TIME"] = "C"
        sanitized["LC_NUMERIC"] = "C"
        sanitized["TZ"] = "UTC0"
        return sanitized
    }

    /// The string form's shell, started with `-f` (NO_RCS) so a user's
    /// `.zshenv` cannot alias or redefine the tools TaskScope parses, print
    /// into their output, or change the locale.
    static let shellArguments = ["/bin/zsh", "-f", "-c"]

    /// The commands in flight, so that quitting can stop them.
    final class ExecutionRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private let inFlight = DispatchGroup()
        private var executions: [ObjectIdentifier: CommandExecution] = [:]
        private var isShutDown = false

        init() {}

        fileprivate func register(_ execution: CommandExecution) -> Bool {
            lock.withLock {
                guard !isShutDown else { return false }
                executions[ObjectIdentifier(execution)] = execution
                inFlight.enter()
                return true
            }
        }

        fileprivate func deregister(_ execution: CommandExecution) {
            lock.withLock {
                if executions.removeValue(forKey: ObjectIdentifier(execution)) != nil {
                    inFlight.leave()
                }
            }
        }

        /// Refuses new commands, stops every command in flight the way a
        /// timeout does (TERM to its process group, then KILL to whatever is
        /// left), and waits until they have finished. The wait is bounded so a
        /// child that cannot be stopped does not hold up quitting. Returns
        /// whether every command finished in time.
        @discardableResult
        func shutDown(waitingAtMost timeout: TimeInterval = 1) -> Bool {
            let running = lock.withLock {
                isShutDown = true
                return Array(executions.values)
            }
            running.forEach { $0.cancel() }
            return inFlight.wait(timeout: .now() + timeout) == .success
        }
    }

    /// The two ends of one pipe, each closed when its handle is released.
    private struct CommandPipe {
        let fileHandleForReading: FileHandle
        let fileHandleForWriting: FileHandle

        func close() {
            try? fileHandleForReading.close()
            try? fileHandleForWriting.close()
        }
    }

    fileprivate final class CommandExecution: @unchecked Sendable {
        private enum SpawnResult {
            case success(pid_t)
            case failure(Int32)
        }

        static let lostExitStatusMessage = "The command's exit status could not be collected."

        /// `argumentVector[0]` is the program spawned; the result reports
        /// `displayCommand`.
        private let argumentVector: [String]
        private let displayCommand: String
        private let timeout: TimeInterval
        private let waitForChild: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
        private let hooks: Hooks
        /// Created by `start` only once the command is about to be spawned.
        private var standardOutput: CommandPipe?
        private var standardError: CommandPipe?
        private let outputCapture = PipeCapture()
        private let errorCapture = PipeCapture()
        private let stateLock = NSLock()
        private let ioQueue = DispatchQueue(label: "TaskScope.ShellCommandRunner.IO")

        private var continuation: CheckedContinuation<ShellCommandResult, Never>?
        private var pendingResult: ShellCommandResult?
        private var completed = false
        private var completionScheduled = false
        private var processStarted = false
        private var processIdentifier: pid_t?
        private var childExitCode: Int32?
        private var childTerminationSignal: Int32?
        private var childReaped = false
        /// waitpid failed with ECHILD: the exit status is gone, and the PID and
        /// its group ID may already name other processes, so nothing is
        /// signalled any more.
        private var childStatusLost = false
        private var groupCleanupStarted = false
        private var stopEscalationFinished = false
        private var terminalOverride: (message: String, exitCode: Int32)?
        private var timeoutTask: Task<Void, Never>?
        private var killFallbackTask: Task<Void, Never>?
        private var outputSource: DispatchSourceRead?
        private var errorSource: DispatchSourceRead?
        private var exitSource: DispatchSourceProcess?

        init(
            argumentVector: [String],
            displayCommand: String,
            timeout: TimeInterval,
            waitForChild: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t,
            hooks: Hooks
        ) {
            self.argumentVector = argumentVector
            self.displayCommand = displayCommand
            self.timeout = max(0.1, timeout)
            self.waitForChild = waitForChild
            self.hooks = hooks
        }

        func start(continuation: CheckedContinuation<ShellCommandResult, Never>) {
            stateLock.lock()
            self.continuation = continuation
            let alreadyCompleted = completed
            let pendingResult = self.pendingResult
            if alreadyCompleted, let pendingResult {
                stateLock.unlock()
                continuation.resume(returning: pendingResult)
                return
            }
            // A stop request that arrived first (the task was cancelled before
            // this body ran, or cancellation raced this call) has claimed the
            // completion under this same lock. Never spawn behind it: the child
            // would run unkilled while the caller was told it was cancelled.
            guard !completionScheduled, terminalOverride == nil else {
                stateLock.unlock()
                return
            }

            if let errorCode = createPipes() {
                stateLock.unlock()
                scheduleImmediateFinish(
                    ShellCommandResult(
                        command: displayCommand,
                        stdout: "",
                        stderr: "Could not start the command: \(String(cString: strerror(errorCode))).",
                        exitCode: -1
                    )
                )
                return
            }
            let spawnResult = spawnContainedProcess()
            switch spawnResult {
            case let .success(pid):
                // Read sources only once there is a child to read from. A failed
                // spawn then has none, so all of its pipes are closed before its
                // result is reported, not by cancel handlers that run after it.
                configureReadSources()
                processIdentifier = pid
                processStarted = true
                let source = makeExitSource(for: pid)
                exitSource = source
                stateLock.unlock()

                source.resume()
                // Catch an already-exited child promptly. Registration is
                // asynchronous, so its handler must repeat this check.
                reapIfExited(pid)

                let newTimeoutTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.timeOut()
                }
                stateLock.lock()
                if completed {
                    stateLock.unlock()
                    newTimeoutTask.cancel()
                } else {
                    timeoutTask = newTimeoutTask
                    stateLock.unlock()
                }
            case let .failure(errorCode):
                stateLock.unlock()
                scheduleImmediateFinish(
                    ShellCommandResult(
                        command: displayCommand,
                        stdout: "",
                        stderr: "Could not start the command: \(String(cString: strerror(errorCode))).",
                        exitCode: -1
                    )
                )
            }
        }

        func cancel() {
            requestStop(message: "Command cancelled.", exitCode: ShellCommandRunner.cancelledExitCode)
        }

        private func timeOut() {
            requestStop(
                message: "Command timed out after \(timeout) seconds.",
                exitCode: ShellCommandRunner.timedOutExitCode
            )
        }

        /// Replaces a blocking `waitpid` on a worker thread: the exit source
        /// fires on the I/O queue and the child is reaped with WNOHANG.
        private func makeExitSource(for pid: pid_t) -> DispatchSourceProcess {
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: ioQueue
            )
            source.setEventHandler { [weak self] in
                self?.reapIfExited(pid, retryUntilReaped: true)
            }
            // resume() returns before kevent registration. A short-lived child
            // can exit after the first WNOHANG check but before registration,
            // leaving no transition for the event handler to observe.
            source.setRegistrationHandler { [weak self] in
                self?.reapIfExited(pid)
            }
            return source
        }

        private func reapIfExited(_ pid: pid_t, retryUntilReaped: Bool = false) {
            // Serialize the probes and stop probing once reaped: a delayed
            // registration callback must never wait on a reused PID.
            stateLock.lock()
            guard !childReaped else {
                stateLock.unlock()
                return
            }
            var status: Int32 = 0
            var waitedPID: pid_t
            var waitError: Int32
            repeat {
                waitedPID = waitForChild(pid, &status, WNOHANG)
                waitError = waitedPID == -1 ? errno : 0
            } while waitedPID == -1 && waitError == EINTR
            if waitedPID == -1, waitError == ECHILD {
                // Something else collected the exit status (a SIGCHLD ignored
                // in this process makes the kernel reap every child itself).
                // The child is gone and no exit event will follow, so finish
                // now with what is known. A stop already requested keeps its
                // own report.
                childReaped = true
                childStatusLost = true
                childExitCode = -1
                stopEscalationFinished = true
                if terminalOverride == nil {
                    terminalOverride = (Self.lostExitStatusMessage, -1)
                }
                let source = exitSource
                exitSource = nil
                stateLock.unlock()
                source?.cancel()
                finishAfterTermination(exitCode: -1)
                return
            }
            guard waitedPID == pid else {
                stateLock.unlock()
                if waitedPID == 0, retryUntilReaped {
                    // NOTE_EXIT (including a synthesized registration event)
                    // can precede the child becoming waitable. It fires only
                    // once, so keep probing without blocking the I/O queue.
                    ioQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                        reapIfExited(pid, retryUntilReaped: true)
                    }
                }
                return
            }
            childReaped = true
            let source = exitSource
            exitSource = nil
            stateLock.unlock()
            source?.cancel()

            hooks.afterReap()
            let (exitCode, signal) = Self.exitStatus(fromWaitStatus: status)
            childDidExit(exitCode: exitCode, terminationSignal: signal)
        }

        private func requestStop(message: String, exitCode: Int32) {
            // Continue probing after a stop even if no further exit event
            // arrives: the timeout task is no longer available as a backstop.
            if let pid = currentProcessIdentifier() {
                reapIfExited(pid, retryUntilReaped: true)
            }
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            // The child has already exited; its real exit is what gets reported,
            // not a cancellation or timeout that lost the race by a moment, and
            // its group, whose ID may already be reused, is never signalled.
            guard !childReaped, childExitCode == nil else {
                stateLock.unlock()
                return
            }
            if terminalOverride == nil {
                terminalOverride = (message, exitCode)
            }
            guard processStarted else {
                // Claim completion under the same lock hold that observed "not
                // started", so a concurrent `start()` bails instead of spawning.
                completionScheduled = true
                stateLock.unlock()
                finishOnIOQueue(
                    ShellCommandResult(
                        command: displayCommand,
                        stdout: outputCapture.string,
                        stderr: message,
                        exitCode: exitCode
                    )
                )
                return
            }
            let processIdentifier = self.processIdentifier
            if let processIdentifier {
                // The child is atomically created as the leader of a new process
                // group. Signalling the group contains children and grandchildren
                // that inherit it. The signal is sent under the lock that reaping
                // takes, so the leader cannot be reaped, and its ID reused,
                // between the check above and the signal.
                _ = hooks.signalGroup(processIdentifier, SIGTERM)
            }
            stateLock.unlock()

            guard processIdentifier != nil else {
                finishStoppedCommand()
                return
            }

            let fallback = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                // The leader itself ignores TERM.
                self?.beginGroupCleanup()
            }
            stateLock.lock()
            if completed {
                stateLock.unlock()
                fallback.cancel()
            } else {
                killFallbackTask?.cancel()
                killFallbackTask = fallback
                stateLock.unlock()
            }
        }

        private func currentProcessIdentifier() -> pid_t? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return processIdentifier
        }

        private func childDidExit(exitCode: Int32, terminationSignal: Int32?) {
            stateLock.lock()
            childExitCode = exitCode
            childTerminationSignal = terminationSignal
            let stopping = terminalOverride != nil
            stateLock.unlock()

            guard stopping else {
                finishAfterTermination(exitCode: exitCode)
                return
            }

            // The group leader is reaped, so anything still in the group ignored
            // TERM. The stop is reported once the group is empty; if the
            // fallback already emptied it, that is now.
            beginGroupCleanup()
            finishStoppedCommand()
        }

        /// Kills what is left of the command's process group until the group is
        /// empty. One SIGKILL is not enough: a member that ignored TERM and is
        /// inside fork() when SIGKILL walks the group dies, but the child it is
        /// creating is not signalled. Starts once, and probes on the I/O queue
        /// so no caller is blocked.
        private func beginGroupCleanup() {
            let shouldStart = stateLock.withLock {
                guard !groupCleanupStarted, !completed, !childStatusLost else { return false }
                groupCleanupStarted = true
                return true
            }
            guard shouldStart else { return }
            let deadline = DispatchTime.now() + .milliseconds(750)
            ioQueue.async { [self] in
                killRemainingGroupMembers(until: deadline)
            }
        }

        private func killRemainingGroupMembers(until deadline: DispatchTime) {
            stateLock.lock()
            guard !completed, !childStatusLost, let processIdentifier else {
                stateLock.unlock()
                return
            }
            // While a member can still be signalled, the group ID is still this
            // command's: the kernel does not reuse an ID that names a live
            // group. ESRCH, or EPERM for a group whose only members have exited
            // and wait to be reaped, means nothing is left to kill, and the
            // group is never signalled again.
            let membersRemain = hooks.signalGroup(processIdentifier, 0) == 0
            if membersRemain {
                _ = hooks.signalGroup(processIdentifier, SIGKILL)
            }
            stateLock.unlock()

            guard membersRemain else {
                markStopEscalationFinished()
                return
            }
            guard DispatchTime.now() < deadline else {
                stateLock.withLock {
                    if let override = terminalOverride {
                        terminalOverride = (
                            "\(override.message) Some of its processes could not be confirmed stopped.",
                            override.exitCode
                        )
                    }
                }
                markStopEscalationFinished()
                return
            }
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                killRemainingGroupMembers(until: deadline)
            }
        }

        private func markStopEscalationFinished() {
            stateLock.lock()
            stopEscalationFinished = true
            let childExitCode = self.childExitCode
            stateLock.unlock()

            if childExitCode != nil {
                finishStoppedCommand()
            }
        }

        private func finishStoppedCommand() {
            stateLock.lock()
            let childExitCode = self.childExitCode
            let stopEscalationFinished = self.stopEscalationFinished
            stateLock.unlock()

            guard let childExitCode, stopEscalationFinished else { return }
            finishAfterTermination(exitCode: childExitCode)
        }

        private func finishAfterTermination(exitCode: Int32) {
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            completionScheduled = true
            let terminalOverride = self.terminalOverride
            let terminationSignal = childTerminationSignal
            stateLock.unlock()

            ioQueue.async { [self] in
                drainAvailableData(from: standardOutput, into: outputCapture)
                drainAvailableData(from: standardError, into: errorCapture)
                cancelReadSources()

                let capturedError = errorCapture.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let reportedError: String
                if let terminalOverride {
                    reportedError = capturedError.isEmpty
                        ? terminalOverride.message
                        : "\(capturedError)\n\(terminalOverride.message)"
                } else {
                    reportedError = capturedError
                }

                finishState(
                    ShellCommandResult(
                        command: displayCommand,
                        stdout: outputCapture.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        stderr: reportedError,
                        exitCode: terminalOverride?.exitCode ?? exitCode,
                        // A signal TaskScope itself sent to stop the command is
                        // not the child's own termination story.
                        terminatedBySignal: terminalOverride == nil ? terminationSignal : nil
                    )
                )
            }
        }

        private func scheduleImmediateFinish(_ result: ShellCommandResult) {
            stateLock.lock()
            guard !completed, !completionScheduled else {
                stateLock.unlock()
                return
            }
            completionScheduled = true
            stateLock.unlock()
            finishOnIOQueue(result)
        }

        /// Closes the pipes on the I/O queue, then completes with a result that
        /// is already built. The caller must already hold the completion claim
        /// (`completionScheduled`). No child ran, so nothing is drained: a read
        /// from a pipe whose reader was never made nonblocking could wait for
        /// as long as some other process holds a copy of its write end.
        private func finishOnIOQueue(_ result: ShellCommandResult) {
            ioQueue.async { [self] in
                closePipeWriters()
                cancelReadSources()
                finishState(result)
            }
        }

        private func finishState(_ result: ShellCommandResult) {
            stateLock.lock()
            guard !completed else {
                stateLock.unlock()
                return
            }
            completed = true
            pendingResult = result
            let continuation = self.continuation
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            let killFallbackTask = self.killFallbackTask
            self.killFallbackTask = nil
            stateLock.unlock()

            timeoutTask?.cancel()
            killFallbackTask?.cancel()
            // The exit source and any reap retries remain active until the
            // child is reaped, including after the timeout task has fired.
            closePipeWriters()
            hooks.registry.deregister(self)
            continuation?.resume(returning: result)
        }

        /// Creates both pipes close-on-exec, so no other command's child can
        /// inherit them. On failure nothing is left open and the error from
        /// pipe(2) is returned: Foundation's `Pipe()` cannot fail, and with no
        /// free descriptor it handed out descriptor 0, the app's standard input.
        private func createPipes() -> Int32? {
            var pipes: [CommandPipe] = []
            for _ in 0..<2 {
                var descriptors: [Int32] = [-1, -1]
                guard hooks.makePipe(&descriptors) == 0 else {
                    let error = errno
                    pipes.forEach { $0.close() }
                    return error
                }
                for descriptor in descriptors {
                    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                }
                pipes.append(
                    CommandPipe(
                        fileHandleForReading: FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
                        fileHandleForWriting: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
                    )
                )
            }
            standardOutput = pipes[0]
            standardError = pipes[1]
            return nil
        }

        private func configureReadSources() {
            guard let standardOutput, let standardError else { return }
            let outputHandle = standardOutput.fileHandleForReading
            let errorHandle = standardError.fileHandleForReading
            let outputDescriptor = outputHandle.fileDescriptor
            let errorDescriptor = errorHandle.fileDescriptor
            makeNonBlocking(outputDescriptor)
            makeNonBlocking(errorDescriptor)

            let outputSource = DispatchSource.makeReadSource(
                fileDescriptor: outputDescriptor,
                queue: ioQueue
            )
            outputSource.setEventHandler { [outputCapture, outputSource] in
                Self.drain(descriptor: outputDescriptor, into: outputCapture)
                if outputCapture.isAtEOF {
                    outputSource.cancel()
                }
            }
            outputSource.setCancelHandler {
                try? outputHandle.close()
            }

            let errorSource = DispatchSource.makeReadSource(
                fileDescriptor: errorDescriptor,
                queue: ioQueue
            )
            errorSource.setEventHandler { [errorCapture, errorSource] in
                Self.drain(descriptor: errorDescriptor, into: errorCapture)
                if errorCapture.isAtEOF {
                    errorSource.cancel()
                }
            }
            errorSource.setCancelHandler {
                try? errorHandle.close()
            }

            self.outputSource = outputSource
            self.errorSource = errorSource
            outputSource.resume()
            errorSource.resume()
        }

        private func spawnContainedProcess() -> SpawnResult {
            guard let standardOutput, let standardError else { return .failure(EBADF) }
            let outputRead = standardOutput.fileHandleForReading.fileDescriptor
            let outputWrite = standardOutput.fileHandleForWriting.fileDescriptor
            let errorRead = standardError.fileHandleForReading.fileDescriptor
            let errorWrite = standardError.fileHandleForWriting.fileDescriptor

            var fileActions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            var errorCode = posix_spawn_file_actions_init(&fileActions)
            guard errorCode == 0 else { return .failure(errorCode) }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            errorCode = posix_spawnattr_init(&attributes)
            guard errorCode == 0 else { return .failure(errorCode) }
            defer { posix_spawnattr_destroy(&attributes) }

            // POSIX_SPAWN_CLOEXEC_DEFAULT below closes every descriptor the
            // file actions do not name, including standard input: give the
            // child an explicit, empty one.
            errorCode = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            guard errorCode == 0 else { return .failure(errorCode) }
            for (source, destination) in [(outputWrite, STDOUT_FILENO), (errorWrite, STDERR_FILENO)] {
                errorCode = posix_spawn_file_actions_adddup2(&fileActions, source, destination)
                guard errorCode == 0 else { return .failure(errorCode) }
            }
            for descriptor in [outputRead, errorRead, outputWrite, errorWrite] {
                errorCode = posix_spawn_file_actions_addclose(&fileActions, descriptor)
                guard errorCode == 0 else { return .failure(errorCode) }
            }

            // The child starts with default signal dispositions and an empty
            // signal mask regardless of what the parent inherited (a host that
            // ignores SIGTERM would otherwise make the stop path's SIGTERM a
            // no-op and misreport a signalled child as a normal exit).
            var defaultSignals = sigset_t()
            sigfillset(&defaultSignals)
            errorCode = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
            guard errorCode == 0 else { return .failure(errorCode) }
            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            errorCode = posix_spawnattr_setsigmask(&attributes, &emptyMask)
            guard errorCode == 0 else { return .failure(errorCode) }

            // POSIX_SPAWN_CLOEXEC_DEFAULT: the child inherits only the three
            // standard streams, never another command's pipes or any other
            // descriptor the app holds without FD_CLOEXEC.
            errorCode = posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_CLOEXEC_DEFAULT
                )
            )
            guard errorCode == 0 else { return .failure(errorCode) }
            errorCode = posix_spawnattr_setpgroup(&attributes, 0)
            guard errorCode == 0 else { return .failure(errorCode) }

            // The program is spawned directly: argv[0] is its path, which is
            // never searched for in PATH.
            var argv = argumentVector.map { strdup($0) } + [nil]
            defer { argv.dropLast().forEach { free($0) } }

            var environment = ShellCommandRunner.childEnvironment(from: hooks.inheritedEnvironment())
                .map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { environment.dropLast().forEach { free($0) } }

            var pid: pid_t = 0
            errorCode = posix_spawn(
                &pid,
                argumentVector[0],
                &fileActions,
                &attributes,
                &argv,
                &environment
            )
            guard errorCode == 0 else { return .failure(errorCode) }

            closePipeWriters()
            return .success(pid)
        }

        private func makeNonBlocking(_ descriptor: Int32) {
            let currentFlags = fcntl(descriptor, F_GETFL)
            if currentFlags != -1 {
                _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
            }
        }

        private func drainAvailableData(from pipe: CommandPipe?, into capture: PipeCapture) {
            // Checked before `fileDescriptor` is touched, not just before the
            // read: reaching EOF cancels the stream's read source, whose cancel
            // handler closes this file handle, and `fileDescriptor` raises an
            // NSFileHandleOperationException on a closed handle. There is
            // nothing left to read anyway -- EOF means the capture already has
            // everything the writer sent.
            guard let pipe, !capture.isAtEOF else { return }
            Self.drain(descriptor: pipe.fileHandleForReading.fileDescriptor, into: capture)
        }

        /// Reads everything currently available and records whether the stream
        /// reached EOF. The distinction matters: a pipe stays *permanently*
        /// readable once its writer closes, so a read source whose handler just
        /// returns at EOF is re-armed immediately and spins the I/O queue at
        /// 100% CPU. The source owner cancels on `capture.isAtEOF`.
        ///
        /// Once EOF is recorded the descriptor is never read again. Its cancel
        /// handler closes the file handle, and the number could by then name an
        /// unrelated reopened file.
        private static func drain(descriptor: Int32, into capture: PipeCapture) {
            guard !capture.isAtEOF else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    capture.append(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 {
                    capture.markEndOfFile()
                    return
                }
                let readError = errno
                if readError == EINTR {
                    continue
                }
                // EAGAIN (EWOULDBLOCK on Darwin) only means nothing is ready on
                // this nonblocking descriptor yet; the writer may still send
                // more. Any other error is unrecoverable, so it ends the stream
                // rather than leaving a source armed on a descriptor that can
                // only fail again.
                if readError != EAGAIN {
                    capture.markEndOfFile()
                }
                return
            }
        }

        private func cancelReadSources() {
            if let outputSource {
                outputSource.cancel()
                self.outputSource = nil
            } else {
                try? standardOutput?.fileHandleForReading.close()
            }
            if let errorSource {
                errorSource.cancel()
                self.errorSource = nil
            } else {
                try? standardError?.fileHandleForReading.close()
            }
        }

        private func closePipeWriters() {
            try? standardOutput?.fileHandleForWriting.close()
            try? standardError?.fileHandleForWriting.close()
        }

        private static func exitStatus(fromWaitStatus status: Int32) -> (exitCode: Int32, signal: Int32?) {
            let signal = status & 0x7f
            if signal == 0 {
                return ((status >> 8) & 0xff, nil)
            }
            return (signal, signal)
        }
    }

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var reachedEndOfFile = false

        /// True once the writer closed and everything it wrote has been read.
        var isAtEOF: Bool {
            lock.lock()
            defer {
                lock.unlock()
            }

            return reachedEndOfFile
        }

        func markEndOfFile() {
            lock.lock()
            reachedEndOfFile = true
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer {
                lock.unlock()
            }

            // Lossy on purpose: a single invalid byte in a process name must not
            // erase the whole inventory.
            return String(decoding: data, as: UTF8.self)
        }

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            lock.unlock()
        }
    }
}
