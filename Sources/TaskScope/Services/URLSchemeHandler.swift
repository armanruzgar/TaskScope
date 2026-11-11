import AppKit
import Foundation
import os

enum TaskScopeURLParser {
    /// The one URL TaskScope accepts. README.md, THREAT_MODEL.md and
    /// docs/AUTOMATION.md state it.
    static let refreshURL = "taskscope://refresh"

    enum ParseError: Error, Equatable, LocalizedError {
        case invalidScheme
        case unsupportedAction(String)
        case invalidRefreshURL

        var errorDescription: String? {
            switch self {
            case .invalidScheme:
                "The URL must use the taskscope scheme."
            case .unsupportedAction(let action):
                "Unsupported TaskScope URL action: \(action.isEmpty ? "(empty)" : action)."
            case .invalidRefreshURL:
                "The refresh URL must be exactly \(TaskScopeURLParser.refreshURL)."
            }
        }
    }

    static func command(from url: URL) -> Result<TaskScopeCommand, ParseError> {
        guard url.scheme?.lowercased() == "taskscope" else {
            return .failure(.invalidScheme)
        }
        let action = url.host ?? ""

        switch action {
        case "refresh":
            guard url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.query == nil,
                  url.fragment == nil,
                  url.path.isEmpty,
                  url.absoluteString == refreshURL else {
                return .failure(.invalidRefreshURL)
            }
            return .success(.refresh)
        default:
            return .failure(.unsupportedAction(action))
        }
    }
}

@MainActor
final class URLSchemeHandler {
    static let shared = URLSchemeHandler()
    private let logger = Logger(
        subsystem: TaskScopeLogging.subsystem(),
        category: "URLScheme"
    )
    private let submitCommand: @MainActor (TaskScopeCommand) async -> TaskScopeCommandResult
    private var willHandleCommand: (@MainActor (TaskScopeCommand) -> Void)?

    init(
        submitCommand: @escaping @MainActor (TaskScopeCommand) async -> TaskScopeCommandResult = {
            await AppCommandBus.shared.submit($0)
        },
        willHandleCommand: @escaping @MainActor (TaskScopeCommand) -> Void = { _ in }
    ) {
        self.submitCommand = submitCommand
        self.willHandleCommand = willHandleCommand
    }

    func register(
        willHandleCommand: @escaping @MainActor (TaskScopeCommand) -> Void = { _ in }
    ) {
        self.willHandleCommand = willHandleCommand
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              value == TaskScopeURLParser.refreshURL,
              let url = URL(string: value) else {
            logger.error("Rejected malformed TaskScope URL.")
            return
        }

        Task {
            await handle(url)
        }
    }

    @discardableResult
    func handle(_ url: URL) async -> TaskScopeCommandResult? {
        switch TaskScopeURLParser.command(from: url) {
        case .success(let command):
            willHandleCommand?(command)
            let result = await submitCommand(command)
            if !result.succeeded {
                logger.error("\(result.message, privacy: .private)")
            }
            return result
        case .failure(let error):
            logger.error("\(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}

enum TaskScopeLogging {
    static func subsystem(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        bundleIdentifier ?? "TaskScope"
    }
}
