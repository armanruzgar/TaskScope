import XCTest
@testable import TaskScope

final class ProcessListQueryTests: XCTestCase {
    func testSearchMatchesNameCommandAndPIDCaseInsensitively() {
        let process = makeProcess(name: "ExampleAgent", command: "/Applications/Example.app/ExampleAgent", pid: 42)

        XCTAssertTrue(query(search: "agent").matches(process))
        XCTAssertTrue(query(search: "applications/example").matches(process))
        XCTAssertTrue(query(search: "42").matches(process))
        XCTAssertFalse(query(search: "missing").matches(process))
    }

    func testWatchedAndHighlightedFiltersUseTheirConfiguredBoundaries() {
        let process = makeProcess(name: "Example", cpu: 30, memory: 500)

        XCTAssertTrue(query(mode: .watched, watched: [preset(main: "Example", appPath: "/tmp/Example.app")])
            .matches(makeProcess(name: "Example", command: "/tmp/Example.app/Contents/MacOS/Example", cpu: 30, memory: 500)))
        XCTAssertFalse(query(mode: .watched, watched: [preset(main: "Other", appPath: "/tmp/Other.app")]).matches(process))
        XCTAssertTrue(query(mode: .highlighted, cpu: 30, memory: 1_000).matches(process))
        XCTAssertTrue(query(mode: .highlighted, cpu: 100, memory: 500).matches(process))
        XCTAssertFalse(query(mode: .highlighted, cpu: 31, memory: 501).matches(process))
    }

    /// The Watched filter must agree with preset status: a same-named process
    /// outside the preset's bundle is not watched, and a main process whose
    /// executable file name differs from its command name still is.
    func testWatchedFilterUsesThePresetBundleBoundary() {
        let watched = [preset(main: "python3", helpers: ["Worker"], protected: ["Daemon"], appPath: "/Applications/Tool.app")]
        let inBundle = makeProcess(name: "python3", command: "/Applications/Tool.app/Contents/MacOS/python3")
        let elsewhere = makeProcess(name: "python3", command: "/usr/bin/python3")
        let renamedMain = makeProcess(
            name: "tool-main",
            command: "tool-main",
            executablePath: "/Applications/Tool.app/Contents/MacOS/python3"
        )
        let helper = makeProcess(name: "Worker", command: "/Applications/Tool.app/Contents/Helpers/Worker")
        let protected = makeProcess(name: "Daemon", command: "/Library/Daemon")

        let filter = query(mode: .watched, watched: watched)
        XCTAssertTrue(filter.matches(inBundle))
        XCTAssertFalse(filter.matches(elsewhere))
        XCTAssertTrue(filter.matches(renamedMain))
        XCTAssertTrue(filter.matches(helper))
        XCTAssertTrue(filter.matches(protected))
    }

    private func preset(
        main: String,
        helpers: [String] = [],
        protected: [String] = [],
        appPath: String
    ) -> WatchedAppPreset {
        WatchedAppPreset(
            displayName: main,
            mainProcessName: main,
            helperProcessNames: helpers,
            protectedProcessNames: protected,
            appPath: appPath
        )
    }

    private func query(
        search: String = "",
        mode: ProcessFilterMode = .all,
        watched: [WatchedAppPreset] = [],
        cpu: Double = 30,
        memory: Double = 500
    ) -> ProcessListQuery {
        ProcessListQuery(
            searchText: search,
            filterMode: mode,
            watchedScopes: watched.map(WatchedProcessScope.init(preset:)),
            cpuHighlightThreshold: cpu,
            memoryHighlightThresholdMB: memory
        )
    }

    private func makeProcess(
        name: String,
        command: String? = nil,
        executablePath: String? = nil,
        pid: Int32 = 1,
        cpu: Double = 0,
        memory: Double = 0
    ) -> AppProcess {
        AppProcess.fixture(
            pid: pid,
            parentPID: 0,
            uid: getuid(),
            cpu: cpu,
            memoryMB: memory,
            command: command ?? "/tmp/\(name)",
            executablePath: executablePath ?? command ?? "/tmp/\(name)",
            elapsedTime: "00:01",
            startTime: "start",
            netInKB: nil,
            netOutKB: nil,
            diskReadBytes: nil,
            diskWriteBytes: nil
        )
    }
}
