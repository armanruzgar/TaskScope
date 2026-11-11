import Foundation
import XCTest
@testable import TaskScope

final class AdminBootstrapShellSyntaxTests: XCTestCase {
    func testAdminBootstrapScriptIsValidShell() async throws {
        let harness = AdminBootstrapRuntimeHarness(
            existingPaths: ["/Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist"],
            commandResults: [
                result(stderr: "Could not find service", exitCode: 113),
                result(stderr: "Administrator approval cancelled", exitCode: 1)
            ]
        )

        let batch = await ProcessLifecycleController.ensureSystemLaunchDaemons(
            for: presetWithDaemon(),
            runtime: harness.runtime
        )

        XCTAssertEqual(batch.jobs.count, 1)
        let osascriptCommand = try XCTUnwrap(
            harness.commands.first { $0.contains("/usr/bin/osascript") },
            "ensureSystemLaunchDaemons never requested the admin bootstrap."
        )

        let appleScript = try XCTUnwrap(
            Self.unshellQuotedArgument(after: "/usr/bin/osascript -e ", in: osascriptCommand),
            "Could not recover the AppleScript argument from \(osascriptCommand)"
        )
        let rootScript = try XCTUnwrap(
            Self.unAppleScriptString(
                between: "do shell script ",
                and: " with administrator privileges",
                in: String(appleScript.components(separatedBy: " with prompt ")[0])
            ),
            "Could not recover the shell script from \(appleScript)"
        )
        XCTAssertTrue(
            rootScript.contains("/bin/launchctl"),
            "Extraction sanity check failed; recovered: \(rootScript)"
        )

        let enable = try XCTUnwrap(rootScript.range(of: "/bin/launchctl enable "))
        let bootstrap = try XCTUnwrap(rootScript.range(of: "/bin/launchctl bootstrap "))
        XCTAssertLessThan(enable.lowerBound, bootstrap.lowerBound, "Enable must precede bootstrap")
        XCTAssertTrue(rootScript.split(separator: "\n").contains {
            $0.hasPrefix("/bin/launchctl enable ") && $0.hasSuffix(" || exit $?")
        }, "Enable failure must stop the privileged script")

        // `do shell script` executes its argument with /bin/sh, so the recovered
        // text must parse as a valid /bin/sh program.
        let check = try Self.shellSyntaxCheck(rootScript)
        XCTAssertEqual(
            check.exitCode,
            0,
            """
            Admin bootstrap script is not valid /bin/sh (exit \(check.exitCode)).
            stderr: \(check.stderr)
            script: \(rootScript)
            """
        )
    }

    private func presetWithDaemon() -> WatchedAppPreset {
        .globalProtect
    }

    private func result(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32
    ) -> ShellCommandResult {
        ShellCommandResult(
            command: "fake",
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode
        )
    }

    /// Inverse of `ShellCommandRunner.shellQuoted` for the argument that follows `prefix`.
    private static func unshellQuotedArgument(after prefix: String, in command: String) -> String? {
        guard command.hasPrefix(prefix) else { return nil }
        let quoted = String(command.dropFirst(prefix.count))
        guard quoted.hasPrefix("'"), quoted.hasSuffix("'"), quoted.count >= 2 else { return nil }
        return String(quoted.dropFirst().dropLast())
            .replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Inverse of `ShellCommandRunner.appleScriptString` for the literal between the markers.
    private static func unAppleScriptString(
        between prefix: String,
        and suffix: String,
        in appleScript: String
    ) -> String? {
        guard appleScript.hasPrefix(prefix), appleScript.hasSuffix(suffix) else { return nil }
        let literal = String(appleScript.dropFirst(prefix.count).dropLast(suffix.count))
        guard literal.hasPrefix("\""), literal.hasSuffix("\""), literal.count >= 2 else { return nil }

        var unescaped = ""
        var iterator = Array(literal.dropFirst().dropLast()).makeIterator()
        while let character = iterator.next() {
            if character == "\\", let escaped = iterator.next() {
                // Mirror AppleScript's own string-literal escapes: \n and \t are
                // control characters, not the letters n and t.
                switch escaped {
                case "n": unescaped.append("\n")
                case "t": unescaped.append("\t")
                case "r": unescaped.append("\r")
                default: unescaped.append(escaped)
                }
            } else {
                unescaped.append(character)
            }
        }
        return unescaped
    }

    private static func shellSyntaxCheck(_ script: String) throws -> (exitCode: Int32, stderr: String) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskscope-admin-bootstrap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", scriptURL.path]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

private final class AdminBootstrapRuntimeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let existingPaths: Set<String>
    private var commandResults: [ShellCommandResult]
    private let inventory: [AppProcess]
    private var recordedCommands: [String] = []

    init(
        existingPaths: Set<String>,
        commandResults: [ShellCommandResult],
        inventory: [AppProcess] = []
    ) {
        self.existingPaths = existingPaths
        self.commandResults = commandResults
        self.inventory = inventory
    }

    var runtime: ProcessLifecycleRuntime {
        ProcessLifecycleRuntime(
            userID: 501,
            fileExists: { [self] path in
                existingPaths.contains(path)
            },
            launchAgentLabel: { _ in "com.paloaltonetworks.gp.pangpsd" },
            runCommand: { [self] command, _ in
                lock.withLock {
                    recordedCommands.append(command)
                    guard !commandResults.isEmpty else {
                        return ShellCommandResult(
                            command: command,
                            stdout: "",
                            stderr: "No fake command result configured.",
                            exitCode: -1
                        )
                    }
                    var response = commandResults.removeFirst()
                    if response.stderr == "Could not find service" {
                        response.stderr = launchctlNotFoundMessage(command: command)
                    }
                    response.command = command
                    return response
                }
            },
            loadProcessInventory: { [self] in
                .success(inventory)
            },
            executablePathForPID: { _ in nil },
            sendSignal: { _, _ in false },
            isProcessAlive: { _ in false },
            sleep: { _ in },
            systemUptime: { 0 },
            isAppBundle: { _ in false }
        )
    }

    var commands: [String] {
        lock.withLock { recordedCommands }
    }
}
