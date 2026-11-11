@testable import TaskScope

func launchctlPrintOutput(pid: Int32, target: String = "gui/501/example.agent") -> String {
    "\(target) = {\n\tpid = \(pid)\n}"
}

/// launchctl's answer for a target it does not have; the target is the
/// command's last argument.
func launchctlNotFoundMessage(command: ExternalCommand) -> String {
    let label = command.arguments.last?.split(separator: "/").last.map(String.init) ?? ""
    return "Could not find service \"\(label)\" in domain"
}
