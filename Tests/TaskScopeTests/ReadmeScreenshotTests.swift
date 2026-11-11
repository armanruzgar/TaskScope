import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TaskScope

/// Renders the README screenshots in `docs/images` from synthetic data.
///
/// The real views are hosted in off-screen windows and drawn with
/// `cacheDisplay(in:to:)`, which also draws the AppKit controls SwiftUI uses
/// (`ImageRenderer` leaves those blank). Every process, sample and time comes
/// from `ReadmeScreenshotData` through the existing fakes: no app is launched,
/// no window is shown and the screen is never captured, so the images cannot
/// contain this Mac's processes. Run `script/render_screenshots.sh`; the
/// rendering test is skipped unless `TASKSCOPE_RENDER_SCREENSHOTS=1`.
@MainActor
final class ReadmeScreenshotTests: XCTestCase {
    func testRenderReadmeScreenshots() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TASKSCOPE_RENDER_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Set TASKSCOPE_RENDER_SCREENSHOTS=1 (script/render_screenshots.sh) to render the README screenshots.")
        }
        let directory = try environment["TASKSCOPE_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ReadmeScreenshotRenderer.defaultDirectory()
        _ = NSApplication.shared
        for appearance in ReadmeScreenshotAppearance.allCases {
            let main = try await ReadmeScreenshotRenderer.mainWindow(appearance)
            try ReadmeScreenshotRenderer.writePNG(main, to: directory.appendingPathComponent("main-window-\(appearance.rawValue).png"))
            let presets = try await ReadmeScreenshotRenderer.menuBarPresets(appearance)
            try ReadmeScreenshotRenderer.writePNG(
                presets, to: directory.appendingPathComponent("menu-bar-presets-\(appearance.rawValue).png")
            )
            let detail = try await ReadmeScreenshotRenderer.processDetail(appearance)
            try ReadmeScreenshotRenderer.writePNG(
                detail, to: directory.appendingPathComponent("process-detail-\(appearance.rawValue).png")
            )
        }
    }

    /// The frames keep the README images' sizes: a 960 x 690 pt window and a
    /// 480 x 600 pt menu-bar panel at 2x (Process Detail uses the panel frame
    /// too), with rounded corners and room for a shadow that falls below.
    func testFramesKeepTheReadmeImageSizes() throws {
        for appearance in ReadmeScreenshotAppearance.allCases {
            let window = ReadmeScreenshotCompositor.Frame.window(appearance)
            XCTAssertEqual(window.canvasSize(windowWidth: 1_920, windowHeight: 1_380, scale: 2), [2_144, 1_604], "\(appearance)")
            let panel = ReadmeScreenshotCompositor.Frame.panel(appearance)
            XCTAssertEqual(panel.canvasSize(windowWidth: 960, windowHeight: 1_200, scale: 2), [1_052, 1_292], "\(appearance)")
        }
        let composed = try ReadmeScreenshotCompositor.compose(
            try Self.solidImage(width: 1_920, height: 1_380), scale: 2, frame: .window(.light)
        )
        XCTAssertEqual([composed.width, composed.height], [2_144, 1_604])
        let pixels = try Self.alphaChannel(of: composed)
        XCTAssertEqual(pixels.alpha(x: 0, y: 0), 0, "the canvas corner is transparent")
        XCTAssertLessThan(pixels.alpha(x: 113, y: 77), 64, "the window's corner is rounded off; only shadow is left there")
        XCTAssertEqual(pixels.alpha(x: 160, y: 120), 255, "the window itself is opaque")
        let above = pixels.alpha(x: 1_072, y: 60)
        let below = pixels.alpha(x: 1_072, y: 1_472)
        XCTAssertGreaterThan(above, 0, "the shadow shows above the window")
        XCTAssertGreaterThan(below, above, "the shadow falls below the window")
    }

    /// The renderer must never need real data: nothing in its fixtures comes
    /// from this Mac's home folder or user, the renderer's own PID is not a
    /// row, and the rows the main window selects exist.
    func testSyntheticDataHasNothingFromThisMac() {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let processes = ReadmeScreenshotData.mainWindowProcesses + ReadmeScreenshotData.presetProcesses
        let detail = ReadmeScreenshotData.detail
        let detailText = [detail.user, detail.command, detail.commandLine.commandLine ?? "", detail.executablePath.value ?? ""]
        for text in detailText {
            XCTAssertFalse(text.contains(home) || text.contains("/Users/") || text.contains(user), text)
        }
        for process in processes {
            XCTAssertNotEqual(process.ownerName, user, "rows carry made-up account names")
            for path in [process.command, process.executablePath ?? ""] {
                XCTAssertFalse(path.hasPrefix(home) || path.hasPrefix("/Users/") || path.hasPrefix("/private/"), path)
                XCTAssertFalse(path.split(separator: "/").contains { $0 == user }, path)
            }
            XCTAssertNotEqual(process.pid, ReadmeScreenshotData.rendererPID)
        }
        let mainPIDs = ReadmeScreenshotData.mainWindowProcesses.map(\.pid)
        XCTAssertEqual(Set(mainPIDs).count, mainPIDs.count, "PIDs are unique")
        XCTAssertTrue(Set(ReadmeScreenshotData.selectedPIDs).isSubset(of: mainPIDs))
        XCTAssertEqual(ReadmeScreenshotData.selectedPIDs.count, 2)
    }

    func testWritingIntoAMissingFolderFails() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskScope.ReadmeScreenshotTests.\(UUID().uuidString)", isDirectory: true)
        let target = missing.appendingPathComponent("image.png")
        XCTAssertThrowsError(try ReadmeScreenshotRenderer.writePNG(Self.solidImage(width: 4, height: 4), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private static func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private struct AlphaChannel {
        var width: Int
        var bytes: [UInt8]

        /// `y` counts from the top, as in the PNG.
        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    }

    private static func alphaChannel(of image: CGImage) throws -> AlphaChannel {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return AlphaChannel(width: image.width, bytes: bytes)
    }
}

enum ReadmeScreenshotAppearance: String, CaseIterable {
    case light
    case dark

    var name: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
}

/// The fixed process list, history, detail and clock the screenshots show.
@MainActor
enum ReadmeScreenshotData {
    /// The renderer's own PID as the fixtures report it; no row uses it, so
    /// no row is drawn as TaskScope itself.
    static let rendererPID: Int32 = 90_210

    /// 9:41 on a fixed day, so a later render draws the same images: the
    /// list's "Updated" time, the end of the history, and the moment Process
    /// Detail measures Elapsed to.
    static var updatedAt: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 41))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// A start time as `ps lstart` prints it, in UTC.
    static func lstart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    /// The list is read twice, this many seconds apart; the per-second
    /// network and disk rates come from the difference.
    static let rateInterval: TimeInterval = 10

    /// Who runs a row: this Mac's user, under a made-up name, or a system
    /// account. Names come with the list read, so no real name can appear.
    enum Account {
        case user, root, windowServer, coreAudio

        var uid: uid_t {
            switch self {
            case .user: getuid()
            case .root: 0
            case .windowServer: 88
            case .coreAudio: 202
            }
        }

        var name: String {
            switch self {
            case .user: "alex"
            case .root: "root"
            case .windowServer: "_windowserver"
            case .coreAudio: "_coreaudiod"
            }
        }
    }

    struct Row {
        var pid: Int32
        var parent: Int32 = 1
        var path: String
        var account: Account = .user
        var cpu: Double
        var memoryMB: Double
        /// Totals since the process started, at `updatedAt`, in KB and MB.
        /// macOS reports them only for the current user's processes.
        var net: (in: Double, out: Double)?
        var disk: (readMB: Double, writtenMB: Double)?
        /// The per-second rates the list shows, in KB/s and MB/s.
        var netRate: (in: Double, out: Double) = (0, 0)
        var diskRate: (readMB: Double, writtenMB: Double) = (0, 0)
        var startTime = "Wed Nov 11 13:28:20 2026"

        /// The row as a list read `secondsEarlier` before `updatedAt` reports
        /// it: the totals are lower by the rate times that time.
        func process(secondsEarlier: TimeInterval = 0) -> AppProcess {
            let net = net.map { ($0.in - netRate.in * secondsEarlier, $0.out - netRate.out * secondsEarlier) }
            let disk = disk.map {
                (($0.readMB - diskRate.readMB * secondsEarlier) * 1_048_576,
                 ($0.writtenMB - diskRate.writtenMB * secondsEarlier) * 1_048_576)
            }
            return AppProcess.fixture(
                pid: pid, parentPID: parent, uid: account.uid, ownerName: account.name, cpu: cpu, memoryMB: memoryMB,
                command: path, executablePath: path, elapsedTime: "01:12:40", startTime: startTime,
                netInKB: net?.0, netOutKB: net?.1, diskReadBytes: disk?.0, diskWriteBytes: disk?.1
            )
        }
    }

    private static let xcode = "/Applications/Xcode.app/Contents"
    private static let toolchain = xcode + "/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    private static let nodePath = "/opt/homebrew/Cellar/node/24.11.1/bin/node"

    /// A developer's Mac in the middle of a build, sorted here by CPU as the
    /// window shows it.
    static let mainWindowRows: [Row] = [
        Row(pid: 48_216, parent: 47_904, path: toolchain + "/swift-frontend", cpu: 97.2, memoryMB: 1_284,
            net: (0, 0), disk: (151.4, 62.8), diskRate: (12.4, 5.1)),
        Row(pid: 48_219, parent: 47_904, path: toolchain + "/swift-frontend", cpu: 86.5, memoryMB: 1_052,
            net: (0, 0), disk: (133.0, 51.2), diskRate: (10.8, 4.6)),
        Row(pid: 1_288, path: xcode + "/MacOS/Xcode", cpu: 34.6, memoryMB: 2_214,
            net: (1_284.6, 342.1), disk: (812.4, 96.3), netRate: (2.4, 0.6), diskRate: (1.2, 0.6)),
        Row(pid: 47_904, parent: 1_288,
            path: xcode + "/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService",
            cpu: 12.3, memoryMB: 412, net: (0, 0), disk: (96.2, 310.5), diskRate: (0.8, 18.2)),
        Row(pid: 1_506, path: "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 9.7, memoryMB: 684,
            net: (48_210.4, 3_906.8), disk: (402.7, 188.4), netRate: (186.5, 9.8), diskRate: (0.3, 0.2)),
        Row(pid: 1_534,
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            cpu: 7.3, memoryMB: 512, net: (0, 0), disk: (96.1, 12.4), diskRate: (0.1, 0)),
        Row(pid: 412, path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            account: .windowServer, cpu: 6.2, memoryMB: 438),
        Row(pid: 1_612, path: "/System/Applications/Music.app/Contents/MacOS/Music", cpu: 3.4, memoryMB: 372,
            net: (12_448.0, 211.6), disk: (330.5, 22.8), netRate: (40.2, 0.6), diskRate: (0.6, 0)),
        Row(pid: 1_342, parent: 1_288,
            path: xcode + "/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService",
            cpu: 2.9, memoryMB: 948, net: (0, 0), disk: (214.0, 3.1), diskRate: (2.6, 0)),
        Row(pid: 1_730, path: xcode + "/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", cpu: 2.6, memoryMB: 304,
            net: (0.4, 0.2), disk: (220.3, 18.6), diskRate: (0.1, 0)),
        Row(pid: 611, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 1.1, memoryMB: 196,
            net: (2.1, 0.8), disk: (88.6, 4.2)),
        Row(pid: 1_190, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", cpu: 0.9, memoryMB: 142,
            net: (0, 0), disk: (21.7, 1.3)),
        Row(pid: 389,
            path: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores",
            account: .root, cpu: 0.8, memoryMB: 96),
        Row(pid: 598, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", cpu: 0.6, memoryMB: 118,
            net: (0, 0), disk: (12.5, 0.9)),
        Row(pid: 5_310, parent: 1_214, path: nodePath, cpu: 0.4, memoryMB: 58,
            net: (3_412.9, 15_806.2), disk: (41.2, 0.4), netRate: (1.2, 24.6),
            startTime: lstart(updatedAt.addingTimeInterval(-(1 * 3_600 + 48 * 60 + 52)))),
        Row(pid: 1_455, path: "/System/Applications/Notes.app/Contents/MacOS/Notes", cpu: 0.4, memoryMB: 164,
            net: (36.2, 12.9), disk: (45.3, 6.8)),
        Row(pid: 640, path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", cpu: 0.3, memoryMB: 88,
            net: (0, 0), disk: (9.4, 0.3)),
        Row(pid: 702, path: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", cpu: 0.2, memoryMB: 54,
            net: (512.7, 96.4), disk: (31.8, 14.2), netRate: (0.8, 0.3)),
        Row(pid: 297, path: "/usr/sbin/coreaudiod", account: .coreAudio, cpu: 0.2, memoryMB: 24),
        Row(pid: 401, path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow", cpu: 0.1, memoryMB: 72,
            net: (0, 0), disk: (6.1, 0.4)),
        Row(pid: 1, parent: 0, path: "/sbin/launchd", account: .root, cpu: 0.1, memoryMB: 18)
    ]

    static var mainWindowProcesses: [AppProcess] { mainWindowRows.map { $0.process() } }

    /// Safari and Music, ready for a batch stop; both rows are in view.
    static let selectedPIDs: [Int32] = [1_506, 1_612]

    /// GlobalProtect is running, so its preset is active; Simulator is not.
    static let presetRows: [Row] = mainWindowRows.filter { $0.pid != 1_730 } + [
        Row(pid: 1_046, path: "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect", cpu: 0.6, memoryMB: 96,
            net: (88.4, 41.2), disk: (14.6, 2.2), netRate: (0.4, 0.2)),
        Row(pid: 1_052, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPA", cpu: 0.3, memoryMB: 38,
            net: (0, 0), disk: (3.4, 0.6)),
        Row(pid: 388, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS", account: .root, cpu: 0.4, memoryMB: 44)
    ]

    static var presetProcesses: [AppProcess] { presetRows.map { $0.process() } }

    static let simulatorPreset = WatchedAppPreset(
        id: UUID(uuidString: "5C1A7E2D-41F0-4D8B-9E36-7B0C2A9F6D11")!,
        displayName: "Simulator",
        mainProcessName: "Simulator",
        helperProcessNames: [],
        protectedProcessNames: [],
        appPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
    )

    /// The row Process Detail shows: a local web server started from a
    /// Terminal shell, with arguments, a listening port and an ad hoc
    /// signature, as Homebrew installs it.
    static var detailRow: Row { mainWindowRows.first { $0.pid == 5_310 }! }

    static var detail: ProcessDetail {
        let row = detailRow
        return ProcessDetail(
            pid: row.pid, parentPID: row.parent, user: row.account.name, startTime: row.startTime, command: "node",
            commandLine: .loaded("node /opt/homebrew/bin/http-server ./public -p 8080"),
            executablePath: .available(row.path),
            parent: .running(name: "zsh"),
            threadCount: .available(11),
            openFiles: .available(ProcessOpenFiles(descriptorCount: 27, listingPortsFor: [8080])),
            codeSignature: .signed(identifier: "node", teamID: nil, isPlatformBinary: false, isAdHoc: true)
        )
    }

    /// Ten minutes of history at 10-second samples: light use, then the build
    /// that is running now. The last sample matches the list's totals.
    static var history: [(cpu: Double, memoryMB: Double)] {
        let count = 60
        let buildStart = 34
        let lastCPU = mainWindowRows.reduce(0) { $0 + $1.cpu }
        let lastMemory = mainWindowRows.reduce(0) { $0 + $1.memoryMB }
        return (0..<count).map { index in
            let wobble = sin(Double(index) * 1.7) * 0.5 + sin(Double(index) * 0.53) * 0.5
            guard index >= buildStart else {
                return (cpu: 31 + 9 * wobble, memoryMB: 7_420 + 60 * wobble)
            }
            let progress = Double(index - buildStart) / Double(count - 1 - buildStart)
            let cpu = index == count - 1 ? lastCPU : 170 + 95 * min(1, progress * 2.5) + 22 * wobble
            let memory = index == count - 1 ? lastMemory : 7_420 + (lastMemory - 7_420) * progress + 40 * wobble
            return (cpu: cpu, memoryMB: memory)
        }
    }
}

private extension ProcessOpenFiles {
    init(descriptorCount: Int, listingPortsFor tcpPorts: [Int]) {
        self.init(descriptorCount: descriptorCount, listeningPorts: tcpPorts.map { ListeningPort(transport: .tcp, port: $0) })
    }
}

/// A screenshot's views and stores, built from `ReadmeScreenshotData` and the
/// existing fakes. Settings live in an in-memory suite.
@MainActor
struct ReadmeScreenshotFixture {
    var manager: ProcessManager
    var settings: SettingsStore
    var watchedApps: WatchedAppsStore
    var savedSelections: SavedSelectionsStore
    var autoStopRules: AutoStopRulesStore
    var history: ProcessHistory

    /// Reads `rows` twice, `rateInterval` apart, so the list has per-second
    /// rates; every later read repeats the second.
    init(rows: [ReadmeScreenshotData.Row]) async {
        let earlier = rows.map { $0.process(secondsEarlier: ReadmeScreenshotData.rateInterval) }
        let current = rows.map { $0.process() }
        let inventory = ScriptedInventory([.success(earlier), .success(current)], repeatsLast: true)
        let defaults = InMemoryUserDefaults(suiteName: "TaskScope.ReadmeScreenshotTests.\(UUID().uuidString)")!
        settings = SettingsStore(userDefaults: defaults, key: "settings")
        watchedApps = WatchedAppsStore(userDefaults: defaults, key: "presets")
        savedSelections = SavedSelectionsStore(userDefaults: defaults, key: "selections")
        autoStopRules = AutoStopRulesStore(
            userDefaults: defaults, key: "rules", eventsKey: "events", inventory: ScriptedInventory(processes: current)
        )
        let series = ReadmeScreenshotData.history
        let historyClock = ReadmeScreenshotClock(
            start: ReadmeScreenshotData.updatedAt.addingTimeInterval(-10 * Double(series.count - 1)), step: 10
        )
        // The history's own read supplies the first sample; `recordHistory`
        // adds the rest once the view is sampling. Its sleep never waits, so
        // no timer adds samples while the image settles.
        history = ProcessHistory(
            inventory: ScriptedInventory(processes: [Self.historySample(series[0])]),
            maxSamples: series.count,
            now: { historyClock.next() },
            sleep: { _ in false }
        )
        let listClock = ReadmeScreenshotClock(
            start: ReadmeScreenshotData.updatedAt.addingTimeInterval(-ReadmeScreenshotData.rateInterval), step: 0
        )
        manager = ProcessManager(
            processInventory: inventory, verificationInventory: inventory,
            processSignaler: FakeSignaler(), lifecycle: FakeLifecycle.forViewTests(), settleAfterProcessChange: {},
            currentPID: ReadmeScreenshotData.rendererPID,
            now: { listClock.next() },
            dependencies: .inert
        )
        manager.enableNotifications = false
        let watchedApps = watchedApps
        manager.dependencies.watchedPresets = { watchedApps.presets }
        settings.sortKeyRaw = ProcessSortKey.cpu.rawValue
        manager.sortKey = .cpu
        await manager.loadProcessList(showMessage: false)
        listClock.move(to: ReadmeScreenshotData.updatedAt)
        await manager.loadProcessList(showMessage: false)
    }

    /// Adds the rest of the history once the view has started sampling and
    /// taken its first sample.
    func recordHistory() {
        for sample in ReadmeScreenshotData.history.dropFirst() {
            history.record(processes: [Self.historySample(sample)])
        }
    }

    func popover(_ style: TaskScopePresentationStyle) -> some View {
        TaskScopePopoverView(
            processManager: manager,
            loginItemManager: LoginItemManager(service: UILoginItemService()),
            settings: settings,
            watchedApps: watchedApps,
            savedSelections: savedSelections,
            autoStopRules: autoStopRules,
            history: history,
            presentationStyle: style,
            openFullWindow: style == .menuBarCompact ? {} : nil,
            mainWindowVisible: { false },
            activityMonitor: UIActivityMonitor(),
            menuBarConfirmation: style == .menuBarCompact ? UIMenuBarConfirmation(answer: false) : nil,
            commandBus: AppCommandBus(),
            quitAction: {}
        )
        .environmentObject(settings)
        .environmentObject(watchedApps)
    }

    private static func historySample(_ sample: (cpu: Double, memoryMB: Double)) -> AppProcess {
        AppProcess.fixture(
            pid: 2, parentPID: 1, cpu: sample.cpu, memoryMB: sample.memoryMB, command: "/usr/libexec/sample",
            elapsedTime: "00:00", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
    }
}

/// Hands out evenly spaced times (or one fixed time, with a zero step).
@MainActor
final class ReadmeScreenshotClock {
    private var current: Date
    private let step: TimeInterval

    init(start: Date, step: TimeInterval) {
        current = start
        self.step = step
    }

    func next() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }

    func move(to date: Date) {
        current = date
    }
}

enum ReadmeScreenshotError: Error, CustomStringConvertible {
    case noBitmap
    case notRetina(scale: CGFloat)
    case didNotSettle(String)
    case composeFailed
    case encodeFailed(URL)
    case packageRootNotFound

    var description: String {
        switch self {
        case .noBitmap: "AppKit returned no bitmap for the view."
        case .notRetina(let scale):
            "The views drew at \(scale)x. Render on a Mac whose main display is a Retina display, so the images are 2x."
        case .didNotSettle(let name): "\(name) was still changing after 10 seconds, so its image would not be repeatable."
        case .composeFailed: "Core Graphics could not compose the image."
        case .encodeFailed(let url): "Could not encode \(url.lastPathComponent) as PNG."
        case .packageRootNotFound: "Could not find Package.swift above this test file."
        }
    }
}

@MainActor
enum ReadmeScreenshotRenderer {
    static let scale: CGFloat = 2

    /// `docs/images`, found from this file's location.
    static func defaultDirectory(from file: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory.appendingPathComponent("docs/images", isDirectory: true)
            }
            directory.deleteLastPathComponent()
        }
        throw ReadmeScreenshotError.packageRootNotFound
    }

    /// The window sorted by CPU, mid-build, with two rows selected.
    static func mainWindow(_ appearance: ReadmeScreenshotAppearance) async throws -> CGImage {
        let fixture = await ReadmeScreenshotFixture(rows: ReadmeScreenshotData.mainWindowRows)
        for pid in ReadmeScreenshotData.selectedPIDs {
            fixture.manager.toggleSelection(pid)
        }
        let frameSize = CGSize(width: 960, height: 690)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let contentSize = NSWindow.contentRect(forFrameRect: CGRect(origin: .zero, size: frameSize), styleMask: styleMask).size
        let hosting = NSHostingView(rootView: fixture.popover(.expandedWindow)
            .frame(width: contentSize.width, height: contentSize.height))
        let window = offscreenWindow(contentSize: contentSize, styleMask: styleMask, appearance: appearance)
        window.title = TaskScopeScene.main.title
        window.contentView = hosting
        defer { window.close() }
        // The theme frame draws the title bar around the content.
        let frameView = hosting.superview ?? hosting
        _ = try await settledCapture(of: frameView, name: "The main window")
        fixture.recordHistory()
        let image = try await settledCapture(of: frameView, name: "The main window")
        return try ReadmeScreenshotCompositor.compose(image, scale: scale, frame: .window(appearance))
    }

    /// The menu-bar popover on the Presets tab, with GlobalProtect running.
    static func menuBarPresets(_ appearance: ReadmeScreenshotAppearance) async throws -> CGImage {
        let fixture = await ReadmeScreenshotFixture(rows: ReadmeScreenshotData.presetRows)
        XCTAssertTrue(fixture.watchedApps.add(ReadmeScreenshotData.simulatorPreset), "the Simulator preset is valid")
        await fixture.manager.loadProcessList(showMessage: false)
        fixture.settings.selectedSectionRaw = TaskScopeSection.presets.rawValue
        let size = CGSize(width: 480, height: 600)
        let hosting = NSHostingView(rootView: fixture.popover(.menuBarCompact).frame(width: size.width, height: size.height))
        let window = offscreenWindow(contentSize: size, styleMask: [.borderless], appearance: appearance)
        window.contentView = hosting
        defer { window.close() }
        let image = try await settledCapture(of: hosting, name: "The menu-bar popover")
        return try ReadmeScreenshotCompositor.compose(image, scale: scale, frame: .panel(appearance))
    }

    /// Process Detail for a local web server, drawn on the window background
    /// a sheet has.
    static func processDetail(_ appearance: ReadmeScreenshotAppearance) async throws -> CGImage {
        let sheet = ProcessDetailSheet(
            process: ReadmeScreenshotData.detailRow.process(),
            detail: ReadmeScreenshotData.detail,
            failed: false,
            metricsAreLive: true,
            now: ReadmeScreenshotData.updatedAt,
            onClose: {}
        )
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: sheet)
        let window = offscreenWindow(contentSize: hosting.fittingSize, styleMask: [.borderless], appearance: appearance)
        window.contentView = hosting
        defer { window.close() }
        // The sheet's height follows its content in the window's appearance.
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
        let image = try await settledCapture(of: hosting, name: "The Process Detail sheet")
        return try ReadmeScreenshotCompositor.compose(image, scale: scale, frame: .panel(appearance))
    }

    /// A window that is never ordered in: `cacheDisplay` draws its views
    /// without the window server, so nothing appears on screen.
    private static func offscreenWindow(
        contentSize: CGSize,
        styleMask: NSWindow.StyleMask,
        appearance: ReadmeScreenshotAppearance
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: contentSize),
            styleMask: styleMask, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.name)
        return window
    }

    /// Draws `view` until three draws in a row are identical, so SwiftUI has
    /// applied every pending update before the image is taken.
    private static func settledCapture(of view: NSView, name: String) async throws -> CGImage {
        var previous: Data?
        var identical = 0
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReadmeScreenshotError.noBitmap }
            view.cacheDisplay(in: view.bounds, to: rep)
            let drawnScale = CGFloat(rep.pixelsWide) / view.bounds.width
            guard drawnScale == scale else { throw ReadmeScreenshotError.notRetina(scale: drawnScale) }
            guard let pixels = rep.bitmapData, let image = rep.cgImage else { throw ReadmeScreenshotError.noBitmap }
            let data = Data(bytes: pixels, count: rep.bytesPerRow * rep.pixelsHigh)
            identical = data == previous ? identical + 1 : 0
            previous = data
            if identical == 2 { return image }
        }
        throw ReadmeScreenshotError.didNotSettle(name)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ReadmeScreenshotError.encodeFailed(url)
        }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ReadmeScreenshotError.encodeFailed(url) }
        try (data as Data).write(to: url, options: .atomic)
    }
}

/// Puts a captured window on a transparent canvas the way a macOS window
/// screenshot looks: rounded corners, a hairline border and a soft shadow.
/// The window server draws those for real windows, so an off-screen capture
/// lacks them. The values were measured from macOS 27 window screenshots.
enum ReadmeScreenshotCompositor {
    struct Frame {
        /// Transparent room around the window for the shadow, in points.
        var top: CGFloat
        var side: CGFloat
        var bottom: CGFloat
        var cornerRadius: CGFloat
        var shadowOpacity: CGFloat
        /// The Gaussian blur's standard deviation and the shadow's downward
        /// offset, in points.
        var shadowSigma: CGFloat
        var shadowOffset: CGFloat
        var borderOpacity: CGFloat
        var highlightOpacity: CGFloat

        /// The composed image's width and height in pixels.
        func canvasSize(windowWidth: Int, windowHeight: Int, scale: CGFloat) -> [Int] {
            [
                Int((CGFloat(windowWidth) + 2 * side * scale).rounded()),
                Int((CGFloat(windowHeight) + (top + bottom) * scale).rounded())
            ]
        }

        static func window(_ appearance: ReadmeScreenshotAppearance) -> Frame {
            Frame(
                top: 38, side: 56, bottom: 74, cornerRadius: 17,
                shadowOpacity: appearance == .light ? 0.40 : 0.70, shadowSigma: 20, shadowOffset: 18,
                borderOpacity: appearance == .light ? 0.20 : 0.90, highlightOpacity: appearance == .light ? 0 : 0.10
            )
        }

        static func panel(_ appearance: ReadmeScreenshotAppearance) -> Frame {
            Frame(
                top: 19, side: 23, bottom: 27, cornerRadius: 17,
                shadowOpacity: appearance == .light ? 0.25 : 0.30, shadowSigma: 8, shadowOffset: 4,
                borderOpacity: appearance == .light ? 0.25 : 0.85, highlightOpacity: appearance == .light ? 0 : 0.10
            )
        }
    }

    static func compose(_ window: CGImage, scale: CGFloat, frame: Frame) throws -> CGImage {
        let size = frame.canvasSize(windowWidth: window.width, windowHeight: window.height, scale: scale)
        let width = size[0]
        let height = size[1]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ReadmeScreenshotError.composeFailed }
        // Core Graphics counts y from the bottom.
        let rect = CGRect(
            x: frame.side * scale, y: frame.bottom * scale, width: CGFloat(window.width), height: CGFloat(window.height)
        )
        let outline = RoundedRectangle(cornerRadius: frame.cornerRadius * scale, style: .continuous).path(in: rect).cgPath

        context.saveGState()
        // A Core Graphics blur radius is about twice the Gaussian's deviation.
        context.setShadow(
            offset: CGSize(width: 0, height: -frame.shadowOffset * scale),
            blur: 2 * frame.shadowSigma * scale,
            color: CGColor(gray: 0, alpha: frame.shadowOpacity)
        )
        context.addPath(outline)
        context.setFillColor(gray: 0, alpha: 1)
        context.fillPath()
        context.restoreGState()

        // Half of the border's stroke falls outside the window.
        context.addPath(outline)
        context.setStrokeColor(gray: 0, alpha: frame.borderOpacity)
        context.setLineWidth(2)
        context.strokePath()

        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.draw(window, in: rect)
        if frame.highlightOpacity > 0 {
            context.addPath(outline)
            context.setStrokeColor(gray: 1, alpha: frame.highlightOpacity)
            context.setLineWidth(2 * scale)
            context.strokePath()
        }
        context.restoreGState()

        guard let image = context.makeImage() else { throw ReadmeScreenshotError.composeFailed }
        return image
    }
}
