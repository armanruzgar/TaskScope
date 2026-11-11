import Darwin
import Foundation

enum ProcessFilterMode: String, CaseIterable, Identifiable {
    case all
    case watched
    case highlighted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .watched: "Watched"
        case .highlighted: "Hot"
        }
    }
}

/// One watched preset's process boundary, mirroring `WatchedSnapshotBuilder`:
/// current-user main processes count inside Contents/MacOS and helpers inside
/// Contents, matched by command or executable name; protected names match by
/// name across users.
struct WatchedProcessScope: Hashable {
    var bundleContentsDirectory: String
    var mainExecutableDirectory: String
    var mainProcessName: String
    var helperNames: Set<String>
    var protectedNames: Set<String>
    var currentUID: uid_t

    init(preset: WatchedAppPreset) {
        self.init(preset: preset, currentUID: getuid())
    }

    init(preset: WatchedAppPreset, currentUID: uid_t) {
        bundleContentsDirectory = preset.bundleContentsDirectory
        mainExecutableDirectory = preset.mainExecutableDirectory
        mainProcessName = preset.mainProcessName
        helperNames = Set(preset.helperProcessNames)
        protectedNames = Set(preset.protectedProcessNames)
        self.currentUID = currentUID
    }

    func contains(_ process: AppProcess) -> Bool {
        if protectedNames.contains(process.name) { return true }
        guard process.uid == currentUID,
              let executablePath = process.executablePath,
              executablePath.hasPrefix(bundleContentsDirectory) else {
            return false
        }
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
        if helperNames.contains(process.name) || helperNames.contains(executableName) { return true }
        return executablePath.hasPrefix(mainExecutableDirectory)
            && (process.name == mainProcessName || executableName == mainProcessName)
    }
}

struct ProcessListQuery: Hashable {
    var searchText: String
    var filterMode: ProcessFilterMode
    var watchedScopes: [WatchedProcessScope]
    var cpuHighlightThreshold: Double
    var memoryHighlightThresholdMB: Double

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(_ process: AppProcess) -> Bool {
        matchesSearch(process) && matchesFilter(process)
    }

    /// The search on the row's own fields. The list also matches the current
    /// user's command lines; see `CommandLineSearchIndex`.
    func matchesSearch(_ process: AppProcess) -> Bool {
        let search = trimmedSearchText
        // The row shows the executable path (with `~` for the home folder)
        // under the name, which can differ from the `ps` command name. Text
        // with a slash, or starting with `~`, is a path, so it also matches
        // that path, as shown and in full. A plain word still matches only the
        // name, command and PID: it must not pull every process in a folder
        // of that name into the list, Select All and batch stops.
        let isPathSearch = search.contains("/") || search.hasPrefix("~")
        let matchesSearch = search.isEmpty
            || process.name.localizedCaseInsensitiveContains(search)
            || process.command.localizedCaseInsensitiveContains(search)
            || (isPathSearch && (process.displayCommand.localizedCaseInsensitiveContains(search)
                || (process.executablePath?.localizedCaseInsensitiveContains(search) ?? false)))
            || String(process.pid).contains(search)
        return matchesSearch
    }

    func matchesFilter(_ process: AppProcess) -> Bool {
        switch filterMode {
        case .all:
            return true
        case .watched:
            return watchedScopes.contains { $0.contains(process) }
        case .highlighted:
            return process.cpu >= cpuHighlightThreshold
                || process.memoryMB >= memoryHighlightThresholdMB
        }
    }
}
