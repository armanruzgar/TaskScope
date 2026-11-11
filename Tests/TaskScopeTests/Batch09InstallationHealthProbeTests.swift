import Security
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

final class Batch09InstallationHealthProbeTests: XCTestCase {
    // T05-11 (b): identityState refuses an unexpected executable, package type
    // or bundle identifier even when every other piece of evidence agrees.
    func testIdentityRequiresTheTaskScopeExecutableAppPackageAndAValidIdentifier() {
        func state(_ info: [String: Any]) -> InstallationHealthReport.State {
            InstallationHealthProbe.identityState(
                info: info, runningIdentifier: "org.example.TaskScope",
                signingIdentifier: "org.example.TaskScope", dynamicStatus: errSecSuccess
            )
        }
        let valid: [String: Any] = ["CFBundleIdentifier": "org.example.TaskScope",
                                    "CFBundleExecutable": "TaskScope", "CFBundlePackageType": "APPL"]
        XCTAssertEqual(state(valid), .healthy)
        XCTAssertEqual(state(valid.merging(["CFBundleExecutable": "Other"]) { $1 }), .unverified)
        XCTAssertEqual(state(valid.merging(["CFBundlePackageType": "BNDL"]) { $1 }), .unverified)
        XCTAssertEqual(state(valid.merging(["CFBundleIdentifier": "org.example/TaskScope"]) { $1 }), .unverified)
        XCTAssertEqual(state(valid.merging(["CFBundleExecutable": 7]) { $1 }), .unverified)
    }

    // T05-11 (c): inspectPaths refuses inputs it cannot safely verify.
    func testPathProbeRefusesRelativeNonAppAndUnsafeBundleInputs() throws {
        let fixture = try Batch09AppFixture()
        defer { fixture.remove() }
        let valid = try fixture.makeApp(named: "Valid.app")
        let noExtension = try fixture.makeApp(named: "NoExtension")
        let traversal = try fixture.makeApp(named: "Traversal.app", executable: "../TaskScope")
        let bundleType = try fixture.makeApp(named: "Bundle.app", packageType: "BNDL")
        let plist = fixture.root.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture.label"], format: .binary, options: 0)
            .write(to: plist)

        func preset(appPath: String, plistPath: String? = nil) -> WatchedAppPreset {
            WatchedAppPreset(
                displayName: "Fixture", mainProcessName: "TaskScope", helperProcessNames: [],
                protectedProcessNames: [], appPath: appPath,
                userLaunchAgentJobs: plistPath.map { [.init(label: "fixture.label", plistPath: $0)] } ?? []
            )
        }

        XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset(appPath: valid.path, plistPath: plist.path)])
            .map(\.state), [.healthy, .healthy], "precondition: the fixtures are otherwise valid")
        for appPath in ["Valid.app", noExtension.path, traversal.path, bundleType.path] {
            XCTAssertEqual(InstallationHealthProbe.inspectPaths([preset(appPath: appPath)]).map(\.state),
                           [.unverified], appPath)
        }
        XCTAssertEqual(
            InstallationHealthProbe.inspectPaths([preset(appPath: valid.path, plistPath: "agent.plist")]).map(\.state),
            [.healthy, .unverified]
        )
    }

    // A02-11 (1): the production bundle probe runs against fixture bundles.
    func testBundleProbeReportsUnsignedAndMissingMetadata() throws {
        let fixture = try Batch09AppFixture()
        defer { fixture.remove() }
        let app = try fixture.makeApp()

        let evidence = InstallationHealthProbe.inspectBundle(at: app)

        XCTAssertEqual(evidence.signature, .unsigned)
        XCTAssertEqual(evidence.metadata, .unavailable)
        XCTAssertNotEqual(evidence.identity, .healthy, "a fixture is never the running TaskScope")
    }

    func testBundleProbeDistinguishesAdHocFromTamperedSignatures() throws {
        let fixture = try Batch09AppFixture()
        defer { fixture.remove() }
        let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        let app = try fixture.makeApp(executableContents: binary, metadata: true)
        try fixture.signAdHoc(app)

        let signed = InstallationHealthProbe.inspectBundle(at: app)
        XCTAssertEqual(signed.signature, .adHoc)
        XCTAssertEqual(signed.metadata, .healthy)

        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertEqual(InstallationHealthProbe.inspectBundle(at: app).signature, .invalid)
    }

    // Batch 13 follow-up: Health reads the hardened runtime flag from the same
    // signature check, and claims nothing for an unsigned bundle.
    func testBundleProbeReadsTheHardenedRuntimeFlag() throws {
        let fixture = try Batch09AppFixture()
        defer { fixture.remove() }
        let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        let app = try fixture.makeApp(executableContents: binary, metadata: true)
        XCTAssertNil(InstallationHealthProbe.inspectBundle(at: app).hardenedRuntime, "an unsigned bundle has no flag to read")

        try fixture.signAdHoc(app)
        XCTAssertEqual(InstallationHealthProbe.inspectBundle(at: app).hardenedRuntime, false)

        try fixture.signAdHoc(app, hardenedRuntime: true)
        let hardened = InstallationHealthProbe.inspectBundle(at: app)
        XCTAssertEqual(hardened.signature, .adHoc)
        XCTAssertEqual(hardened.hardenedRuntime, true)
    }

    func testBundleProbeTreatsAMissingInfoPlistAsAMovedOrReplacedApp() throws {
        let fixture = try Batch09AppFixture()
        defer { fixture.remove() }
        let app = try fixture.makeApp()
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Info.plist"))

        let evidence = InstallationHealthProbe.inspectBundle(at: app)

        XCTAssertEqual(evidence.identity, .stale)
        XCTAssertEqual(evidence.signature, .unverified)
        XCTAssertEqual(evidence.metadata, .unverified)
    }

    // A02-10: a probe blocked on an unresponsive volume no longer holds the
    // collection: it returns at the deadline with the unfinished rows marked,
    // keeps the evidence that did finish, and does not queue more blocked work.
    func testBlockedPathProbeEndsAtTheDeadlineAndIsNotRunTwice() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let counter = Batch09ProbeCounter()
        defer { blocker.signal() }
        let preset = WatchedAppPreset(
            displayName: "Network", mainProcessName: "Network", helperProcessNames: [],
            protectedProcessNames: [], appPath: "/Volumes/Unresponsive/Network.app"
        )
        let input = InstallationHealthInput(presets: [preset], presetsReadable: true, notificationsEnabled: false)
        let runtime = InstallationHealthRuntime(
            permissions: {
                .init(notificationsAvailable: true, notifications: .authorized, accessibilityTrusted: true, loginItem: .enabled)
            },
            bundle: {
                counter.increment()
                return .init(identity: .healthy, identityDetail: "Bundle evidence", signature: .signed, metadata: .healthy)
            },
            paths: { presets in
                if counter.blocks { _ = blocker.wait(timeout: .now() + 30) }
                return presets.map { _ in HealthPathFinding(state: .healthy, detail: "Preset 1: found.") }
            },
            recoveries: { [.reviewPresets] },
            probeTimeout: 0.2
        )

        let started = Date()
        let stalled = await runtime.collect(input)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(stalled[batch09: .presetPaths].state, .unavailable)
        XCTAssertTrue(stalled[batch09: .presetPaths].detail.contains("did not finish in time"))
        XCTAssertEqual(stalled[batch09: .presetPaths].recovery, .reviewPresets, "reviewing the preset still helps")
        XCTAssertEqual(stalled[batch09: .signing].state, .healthy, "finished evidence is kept")
        XCTAssertEqual(stalled[batch09: .notifications].state, .healthy)

        let pending = await runtime.collect(input)
        XCTAssertEqual(counter.count, 1, "no second probe while the first is blocked")
        for category in [InstallationHealthReport.Category.signing, .appIntents, .bundleIdentity, .presetPaths] {
            XCTAssertEqual(pending[batch09: category].state, .unavailable, category.rawValue)
            XCTAssertTrue(pending[batch09: category].detail.contains("still waiting"), category.rawValue)
        }

        counter.blocks = false
        blocker.signal()
        var recovered = await runtime.collect(input)
        for _ in 0..<100 where recovered[batch09: .presetPaths].state != .healthy {
            try await Task.sleep(nanoseconds: 20_000_000)
            recovered = await runtime.collect(input)
        }
        XCTAssertEqual(recovered[batch09: .presetPaths].state, .healthy)
        XCTAssertEqual(recovered[batch09: .bundleIdentity].state, .healthy)
    }

    func testCancelledCollectionStopsWaitingForABlockedProbe() async {
        let blocker = DispatchSemaphore(value: 0)
        defer { blocker.signal() }
        let runtime = InstallationHealthRuntime(
            permissions: {
                .init(notificationsAvailable: false, notifications: .unknown, accessibilityTrusted: false, loginItem: .notFound)
            },
            bundle: {
                _ = blocker.wait(timeout: .now() + 30)
                return .init(identity: .healthy, identityDetail: "", signature: .signed, metadata: .healthy)
            },
            paths: { _ in [] },
            recoveries: { [] },
            probeTimeout: 30
        )
        let collection = Task { await runtime.collect(batch09HealthInput) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        collection.cancel()
        let report = await collection.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(report[batch09: .signing].state, .unavailable)
    }

    // A02-11 (2): the live runtime and recovery wiring, which only read state
    // in an unbundled test process.
    func testLiveRuntimeReportsAnUnbundledProcessWithoutClaimingReadiness() async {
        let report = await InstallationHealthRuntime.live.collect(batch09HealthInput)
        XCTAssertEqual(report[batch09: .notifications].state, .unavailable)
        XCTAssertEqual(report[batch09: .loginItem].state, .unavailable)
        XCTAssertEqual(report[batch09: .bundleIdentity].state, .unavailable)
        XCTAssertEqual(report[batch09: .presetPaths].detail, "No presets are configured.")
        XCTAssertEqual(report[batch09: .presetPaths].recovery, .reviewPresets)
        XCTAssertNil(report[batch09: .signing].recovery, "an unbundled process has no app to reveal")
    }
}

/// Fixture app bundles in a temporary directory.
private struct Batch09AppFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Batch09Health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func makeApp(
        named name: String = "TaskScope.app",
        executable: String = "TaskScope",
        packageType: String = "APPL",
        executableContents: Data = Data("#!/bin/sh\nexit 0\n".utf8),
        metadata: Bool = false
    ) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.example.Batch09Fixture",
            "CFBundleExecutable": executable,
            "CFBundlePackageType": packageType
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let binary = macOS.appendingPathComponent("TaskScope")
        try executableContents.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("sealed".utf8).write(to: resources.appendingPathComponent("data.txt"))
        if metadata {
            let directory = resources.appendingPathComponent("Metadata.appintents", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (version, actions) = try XCTUnwrap(ExpectedAppIntents.current).extractedMetadata()
            try JSONSerialization.data(withJSONObject: version).write(to: directory.appendingPathComponent("version.json"))
            try JSONSerialization.data(withJSONObject: actions).write(to: directory.appendingPathComponent("extract.actionsdata"))
        }
        return app
    }

    /// Signs `app` ad hoc with the system codesign tool. Only the fixture in
    /// the temporary directory changes; no identity or keychain is used.
    func signAdHoc(_ app: URL, hardenedRuntime: Bool = false) throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else {
            throw XCTSkip("codesign is not available")
        }
        let process = Process()
        process.executableURL = codesign
        process.arguments = ["--force", "--sign", "-", "--timestamp=none"]
            + (hardenedRuntime ? ["--options", "runtime"] : []) + [app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("codesign could not sign the fixture (status \(process.terminationStatus))")
        }
    }
}

private final class Batch09ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var blocking = true
    var count: Int { lock.withLock { calls } }
    var blocks: Bool {
        get { lock.withLock { blocking } }
        set { lock.withLock { blocking = newValue } }
    }
    func increment() { lock.withLock { calls += 1 } }
}
