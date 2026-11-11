import Combine
import Foundation

enum TaskScopePresentationStyle {
    case menuBarCompact
    case expandedWindow
}

@MainActor
final class ProcessConfirmationState: ObservableObject {
    enum TerminationMode: Equatable {
        case normal
        case force

        var title: String {
            switch self {
            case .normal: "Stop Process?"
            case .force: "Force Stop Process?"
            }
        }
    }

    struct PendingTermination: Equatable {
        let process: AppProcess
        let mode: TerminationMode

        var confirmTitle: String {
            mode == .force ? "Force Stop \(process.name)" : "Stop \(process.name)"
        }

        /// A normal stop is SIGTERM, which an ordinary AppKit app does not handle:
        /// it exits without running its quit handling or asking to save changes.
        var message: String {
            mode == .force
                ? "Immediately send a kill signal to PID \(process.pid). The process cannot clean up before it exits."
                : "Send SIGTERM to PID \(process.pid). Apps may close without asking to save changes."
        }
    }

    struct PendingBatchTermination: Equatable, Identifiable {
        /// Each request is distinct, so an answer to an earlier request can never
        /// be taken for a later one that captured the same targets.
        let id = UUID()
        let targets: [ProcessIdentity]
        let mode: TerminationMode
        /// Targets that are selected but not on screen when the request was made.
        var hiddenCount: Int = 0
        /// Stop With Children: the process whose children were collected. The
        /// first target is that process; the rest are its descendants.
        var familyParentName: String? = nil

        struct Row: Equatable, Identifiable {
            var id: Int { index }
            let index: Int
            let name: String
            let pid: Int32
            let path: String
        }

        var title: String {
            if let familyParentName {
                return "Stop \(familyParentName) and Its Child Processes?"
            }
            return mode == .force ? "Force Stop Selected Processes?" : "Stop Selected Processes?"
        }

        var confirmTitle: String {
            if familyParentName != nil {
                return "Stop \(targets.count) Processes"
            }
            return mode == .force ? "Force Stop Selected" : "Stop Selected"
        }

        /// One row per captured target, in capture order, named by the same rule
        /// as the process list rows.
        var rows: [Row] {
            targets.enumerated().map { index, identity in
                Row(
                    index: index,
                    name: Self.displayName(for: identity),
                    pid: identity.pid,
                    path: identity.executablePath ?? identity.command
                )
            }
        }

        var summary: String {
            let action = mode == .force ? "Force stop" : "Stop"
            let noun = targets.count == 1 ? "process" : "processes"
            var text = "\(action) \(targets.count) selected \(noun)."
            if let familyParentName {
                let children = targets.count - 1
                text = "\(action) \(familyParentName) and its \(children) child \(children == 1 ? "process" : "processes"), one at a time. Each is checked again before it is signalled; no process group is signalled."
            }
            if hiddenCount > 0 {
                text += hiddenCount == 1
                    ? " 1 of these is not currently shown."
                    : " \(hiddenCount) of these are not currently shown."
            }
            return text
        }

        var signalNote: String {
            mode == .force
                ? "Sends SIGKILL immediately; the processes cannot clean up."
                : "Sends SIGTERM. Apps may close without asking to save changes."
        }

        /// One line per captured target: name, PID and executable path.
        var targetList: String {
            rows.map { "\($0.name) (PID \(String($0.pid))) — \($0.path)" }.joined(separator: "\n")
        }

        /// Names exactly the captured targets, so the review cannot drift from
        /// what will be signalled if the live state changes meanwhile.
        var message: String {
            [summary, targetList, signalNote].joined(separator: "\n")
        }

        /// The menu-bar alert lists every target in a scrolling list below the
        /// summary, however long the selection is.
        var menuBarRequest: MenuBarConfirmationRequest {
            MenuBarConfirmationRequest(
                title: title,
                message: "\(summary) \(signalNote)",
                confirmTitle: confirmTitle,
                details: targetList
            )
        }

        static func displayName(for identity: ProcessIdentity) -> String {
            let name = identity.command.isEmpty ? "" : AppProcess.name(from: identity.command)
            return name.isEmpty ? "PID \(String(identity.pid))" : name
        }
    }

    enum PresetAction: String, Equatable {
        case quitApp = "Quit App"
        case quitHelpers = "Quit Helpers"
        case quitAll = "Quit App and Helpers"
        case keepOff = "Keep GlobalProtect Off"
        case stopServices = "Stop Services Anyway"
        case restart = "Restart"
    }

    struct PendingPresetAction: Equatable {
        var preset: WatchedAppPreset
        var action: PresetAction
        var disconnectFailureID: UUID?

        /// The verb, as on the card's button or switch.
        var confirmTitle: String {
            switch action {
            case .quitAll where preset.isBuiltInGlobalProtect: "Quit All"
            case .keepOff where !preset.isBuiltInGlobalProtect: "Keep \(preset.displayName) Off"
            default: action.rawValue
            }
        }

        /// A question that names the preset the card shows.
        var title: String {
            let name = preset.displayName
            switch action {
            case .quitApp: return "Quit \(name)?"
            case .quitHelpers: return "Quit \(name) Helpers?"
            case .quitAll:
                // GlobalProtect's button is the stronger Quit All; a custom
                // preset's is Quit App and Helpers, so its question says that.
                return preset.isBuiltInGlobalProtect
                    ? "Quit All \(name) Processes?"
                    : "Quit \(name) and Its Helpers?"
            case .keepOff: return "Keep \(name) Off?"
            case .stopServices: return "Stop \(name) Services Anyway?"
            case .restart: return "Restart \(name)?"
            }
        }
    }

    /// Work started by the view's buttons and confirmations. Kept so a test can
    /// wait for exactly that work instead of guessing with yields or sleeps.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func run(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    func waitForActions() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }

    // Sheet items the process list opens. Held here rather than in view
    // @State so a test can observe what a button or key requested.
    @Published var pendingRecallSelection: SavedSelectionsStore.SavedSelection?
    @Published var pendingRecallResult: SavedSelectionsStore.RecallResult?
    @Published var quickPresetDraft: QuickWatchedPresetDraft?
    @Published var quickAutoStopProcess: AppProcess?
    @Published var detailProcess: AppProcess?
    /// A saved selection waiting for Delete to be confirmed (it has no undo).
    @Published var pendingSelectionDeletion: SavedSelectionsStore.SavedSelection?
    /// A reset of unreadable saved selections that no recovery slot holds,
    /// waiting for the discard to be confirmed.
    @Published var pendingSelectionsDiscard: SelectionsDiscardRequest?

    struct SelectionsDiscardRequest: Equatable {
        let id = UUID()
    }

    @Published private(set) var pendingTermination: PendingTermination?
    @Published private(set) var pendingBatchTermination: PendingBatchTermination?
    @Published var pendingPresetAction: PendingPresetAction?

    func requestTermination(_ process: AppProcess, mode: TerminationMode = .normal) {
        pendingTermination = PendingTermination(process: process, mode: mode)
    }

    func clearTermination() {
        pendingTermination = nil
    }

    func requestBatch(
        _ targets: [ProcessIdentity],
        mode: TerminationMode = .normal,
        hiddenCount: Int = 0,
        familyParentName: String? = nil
    ) {
        pendingBatchTermination = targets.isEmpty
            ? nil
            : PendingBatchTermination(
                targets: targets, mode: mode, hiddenCount: hiddenCount, familyParentName: familyParentName
            )
    }

    /// Pause or a Send Signal action, waiting for confirmation. Resume needs none.
    struct PendingSignal: Equatable, Identifiable {
        let id = UUID()
        let process: AppProcess
        let action: ProcessSignalAction

        var title: String { action.confirmationTitle }
        var confirmTitle: String { action.confirmTitle(for: process) }
        var message: String { action.confirmationMessage(for: process) }
    }

    @Published private(set) var pendingSignal: PendingSignal?

    func requestSignal(_ action: ProcessSignalAction, for process: AppProcess) {
        pendingSignal = PendingSignal(process: process, action: action)
    }

    func clearSignal() {
        pendingSignal = nil
    }

    func clearBatch() {
        pendingBatchTermination = nil
    }

    func requestPresetAction(_ action: PresetAction, preset: WatchedAppPreset, disconnectFailureID: UUID? = nil) {
        pendingPresetAction = PendingPresetAction(preset: preset, action: action, disconnectFailureID: disconnectFailureID)
    }

    func clearPresetAction() {
        pendingPresetAction = nil
    }

    var batchMessage: String {
        pendingBatchTermination?.message ?? ""
    }
}
