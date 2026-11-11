import Darwin
import Foundation

/// Builds watched-preset status from an immutable process inventory. It has no
/// polling, notification, persistence, or presentation responsibilities.
struct WatchedSnapshotBuilder: Sendable {
    let excludedPID: Int32
    var currentUID: uid_t = getuid()

    func snapshots(
        for presets: [WatchedAppPreset],
        in inventory: [AppProcess]
    ) -> [WatchedAppSnapshot] {
        presets.map { snapshot(for: $0, in: inventory) }
    }

    func snapshot(
        for preset: WatchedAppPreset,
        in inventory: [AppProcess]
    ) -> WatchedAppSnapshot {
        var runningNames = Set<String>()
        let mainExecutableDirectory = preset.mainExecutableDirectory
        let bundleContentsDirectory = preset.bundleContentsDirectory

        let mainProcessPIDs = Set(
            inventory.lazy
                .filter { process in
                    guard process.pid != excludedPID,
                          process.uid == currentUID,
                          let executablePath = process.executablePath,
                          executablePath.hasPrefix(mainExecutableDirectory) else {
                        return false
                    }
                    return process.name == preset.mainProcessName
                        || URL(fileURLWithPath: executablePath).lastPathComponent
                            == preset.mainProcessName
                }
                .map(\.pid)
        )
        if !mainProcessPIDs.isEmpty {
            runningNames.insert(preset.mainProcessName)
        }

        let helperNames = Set(preset.helperProcessNames)
        runningNames.formUnion(
            inventory.lazy
                .filter {
                    $0.pid != excludedPID
                        && $0.uid == currentUID
                        && $0.executablePath?.hasPrefix(bundleContentsDirectory) == true
                }
                .compactMap { process -> String? in
                    if helperNames.contains(process.name) {
                        return process.name
                    }
                    guard let executablePath = process.executablePath else {
                        return nil
                    }
                    let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
                    return helperNames.contains(executableName) ? executableName : nil
                }
        )

        // Root ownership identifies a privileged process, not its launchd
        // domain: the session pangps agent also runs PanGPS as root via setuid.
        // Lifecycle readiness separately binds it to the correct launchd PID.
        // Neither instance is ever directly signalled as an ordinary helper.
        let protectedNames = Set(preset.protectedProcessNames)
        var unprivilegedProtectedNames = Set<String>()
        for process in inventory
        where process.pid != excludedPID && protectedNames.contains(process.name) {
            if process.uid == 0 {
                runningNames.insert(process.name)
            } else {
                unprivilegedProtectedNames.insert(process.name)
            }
        }

        return WatchedAppSnapshot(
            preset: preset,
            runningNames: runningNames,
            mainProcessPIDs: mainProcessPIDs,
            unprivilegedProtectedNames: unprivilegedProtectedNames,
            hasCurrentUserLaunchAgent: preset.isBuiltInGlobalProtect
                && currentUID != 0
                && inventory.contains {
                    $0.pid != excludedPID
                        && $0.uid == currentUID
                        && $0.executablePath?.hasPrefix(bundleContentsDirectory) == true
                        && $0.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } == "PanGPS"
                }
        )
    }
}
