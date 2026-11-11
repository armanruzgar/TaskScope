import XCTest
@testable import TaskScope

final class WatchedSnapshotBuilderTests: XCTestCase {
    func testMainAndHelperMatchesAreScopedToConfiguredBundle() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        let inventory = [
            process(pid: 10, name: "Example", path: "/Applications/Forged.app/Contents/MacOS/Example"),
            process(pid: 11, name: "Example Helper", path: "/Applications/Example.app/Contents/Helpers/Example Helper"),
            process(pid: 13, name: "Example Helper", path: "/Applications/Forged.app/Contents/Helpers/Example Helper"),
            process(pid: 12, name: "Example", path: "/Applications/Example.app/Contents/MacOS/Example")
        ]

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: inventory)

        XCTAssertEqual(snapshot.runningNames, ["Example", "Example Helper"])
        XCTAssertEqual(snapshot.mainProcessPIDs, [12])

        let forgedOnly = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: inventory.filter { [10, 13].contains($0.pid) })
        XCTAssertTrue(forgedOnly.runningNames.isEmpty)
        XCTAssertTrue(forgedOnly.mainProcessPIDs.isEmpty)
        XCTAssertFalse(forgedOnly.hasAny)
    }

    func testMainAndHelpersRequireCurrentUserOwnership() {
        let builder = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
        let mainPath = "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect"
        let helperPath = "/Applications/GlobalProtect.app/Contents/MacOS/PanGPA"
        for uid: uid_t? in [502, 0, nil] {
            let others = [
                process(pid: 10, name: "GlobalProtect", path: mainPath, uid: uid),
                process(pid: 11, name: "PanGPA", path: helperPath, uid: uid)
            ]
            let snapshot = builder.snapshot(for: .globalProtect, in: others)
            XCTAssertTrue(snapshot.runningNames.isEmpty)
            XCTAssertTrue(snapshot.mainProcessPIDs.isEmpty)
            XCTAssertFalse(snapshot.hasKeepOffTargets)

            let own = builder.snapshot(for: .globalProtect, in: others + [
                process(pid: 12, name: "GlobalProtect", path: mainPath),
                process(pid: 13, name: "PanGPA", path: helperPath)
            ])
            XCTAssertEqual(own.runningNames, ["GlobalProtect", "PanGPA"])
            XCTAssertEqual(own.mainProcessPIDs, [12])
            XCTAssertTrue(own.hasKeepOffTargets)
        }
    }

    func testKernelExecutableNamesRecoverTruncatedProcessNames() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: ["Example Helper"],
            protectedProcessNames: [],
            appPath: "/Applications/Example.app"
        )
        var main = process(
            pid: 10,
            name: "Example",
            path: "/Applications/Example.app/Contents/MacOS/Example"
        )
        main.command = "/Applications/Ex"
        var helper = process(
            pid: 11,
            name: "Example Helper",
            path: "/Applications/Example.app/Contents/Helpers/Example Helper"
        )
        helper.command = "/Applications/Ex"

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: [main, helper])

        XCTAssertEqual(snapshot.runningNames, ["Example", "Example Helper"])
    }

    func testProtectedNameMatchingRemainsOutsideBundleScope() {
        let preset = WatchedAppPreset(
            displayName: "Example",
            mainProcessName: "Example",
            helperProcessNames: [],
            protectedProcessNames: ["Example Service"],
            appPath: "/Applications/Example.app"
        )
        let service = process(pid: 20, name: "Example Service", path: "/Library/Example Service", uid: 0)

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: [service])

        XCTAssertEqual(snapshot.runningNames, ["Example Service"])
        XCTAssertEqual(snapshot.protectedRunning, ["Example Service"])
        XCTAssertTrue(snapshot.unprivilegedProtectedNames.isEmpty)
    }

    /// GlobalProtect's optional per-user `pangps` agent runs a binary that is
    /// also named PanGPS. Only a root process is the protected system daemon; a
    /// same-named user process is reported separately, and an unknown uid is
    /// never promoted to root.
    func testProtectedNameWithoutRootIsReportedAsAUserInstanceNotTheSystemDaemon() {
        let preset = WatchedAppPreset.globalProtect
        let userAgent = process(
            pid: 20,
            name: "PanGPS",
            path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS",
            uid: 501
        )
        let unknownUID = process(pid: 21, name: "PanGPS", path: "/tmp/PanGPS", uid: nil)
        let daemon = process(
            pid: 22,
            name: "PanGPS",
            path: "/Library/Application Support/PaloAltoNetworks/GlobalProtect/PanGPS",
            uid: 0
        )

        let userOnly = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: [userAgent, unknownUID])
        XCTAssertTrue(userOnly.runningNames.isEmpty)
        XCTAssertTrue(userOnly.protectedRunning.isEmpty)
        XCTAssertEqual(userOnly.unprivilegedProtectedNames, ["PanGPS"])
        XCTAssertEqual(userOnly.unprivilegedProtectedRunning, ["PanGPS"])
        XCTAssertTrue(userOnly.hasAny)
        XCTAssertEqual(userOnly.detail, "PanGPS (user)")
        XCTAssertEqual([userOnly].aggregateStatus, .protectedOnly)

        let both = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: [userAgent, daemon])
        XCTAssertEqual(both.runningNames, ["PanGPS"])
        XCTAssertEqual(both.protectedRunning, ["PanGPS"])
        XCTAssertEqual(both.unprivilegedProtectedNames, ["PanGPS"])
    }

    func testKeepOffRecognizesOnlySupportedCurrentUserAgentExecutables() {
        let builder = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
        let path = "/Applications/GlobalProtect.app/Contents/Resources/PanGPS"
        let agent = process(pid: 20, name: "PanGPS", path: path, uid: 501)
        XCTAssertTrue(builder.snapshot(for: .globalProtect, in: [agent]).hasKeepOffTargets)
        for other in [
            process(pid: 20, name: "PanGPS", path: path, uid: 0),
            process(pid: 20, name: "PanGPS", path: path, uid: 502),
            process(pid: 20, name: "PanGPS", path: path, uid: nil),
            process(pid: 99, name: "PanGPS", path: path, uid: 501),
            process(pid: 20, name: "PanGPS", path: "/tmp/PanGPS", uid: 501),
            process(pid: 20, name: "PanGPS", path: "/Applications/GlobalProtect.app/Contents-fake/PanGPS", uid: 501)
        ] {
            XCTAssertFalse(builder.snapshot(for: .globalProtect, in: [other]).hasKeepOffTargets)
        }
        var custom = WatchedAppPreset.globalProtect
        custom.id = UUID()
        XCTAssertFalse(builder.snapshot(for: custom, in: [agent]).hasKeepOffTargets)
    }

    func testSnapshotRecordsMainProcessPIDsForLifecycleDecisions() {
        let preset = WatchedAppPreset.globalProtect
        let main = process(
            pid: 30,
            name: "GlobalProtect",
            path: "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect",
            uid: 501
        )
        let helper = process(
            pid: 31,
            name: "PanGPA",
            path: "/Applications/GlobalProtect.app/Contents/MacOS/PanGPA",
            uid: 501
        )

        let snapshot = WatchedSnapshotBuilder(excludedPID: 99, currentUID: 501)
            .snapshot(for: preset, in: [main, helper])

        XCTAssertEqual(snapshot.mainProcessPIDs, [30])
        XCTAssertEqual(snapshot.runningNames, ["GlobalProtect", "PanGPA"])
    }

    func testExcludedProcessNeverAppearsInSnapshot() {
        let preset = WatchedAppPreset(
            displayName: "TaskScope",
            mainProcessName: "TaskScope",
            helperProcessNames: [],
            protectedProcessNames: ["TaskScope"],
            appPath: "/Applications/TaskScope.app"
        )
        for uid: uid_t in [501, 0] {
            let current = process(
                pid: 42,
                name: "TaskScope",
                path: "/Applications/TaskScope.app/Contents/MacOS/TaskScope",
                uid: uid
            )
            let snapshot = WatchedSnapshotBuilder(excludedPID: 42, currentUID: 501)
                .snapshot(for: preset, in: [current])

            XCTAssertTrue(snapshot.runningNames.isEmpty)
            XCTAssertTrue(snapshot.mainProcessPIDs.isEmpty)
            XCTAssertTrue(snapshot.unprivilegedProtectedNames.isEmpty)
            XCTAssertFalse(snapshot.hasAny)
        }
    }

    private func process(pid: Int32, name: String, path: String, uid: uid_t? = 501) -> AppProcess {
        AppProcess(
            pid: pid,
            parentPID: 1,
            uid: uid,
            cpu: 0,
            memoryMB: 0,
            command: path,
            executablePath: path,
            elapsedTime: "00:01",
            startTime: "Sat Jul 26 11:20:17 2026",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}
