func launchctlPrintOutput(pid: Int32, target: String = "gui/501/example.agent") -> String {
    "\(target) = {\n\tpid = \(pid)\n}"
}

func launchctlNotFoundMessage(command: String) -> String {
    let target = command.split(separator: " ").last.map(String.init)?.trimmingCharacters(in: .init(charactersIn: "'")) ?? ""
    let label = target.split(separator: "/").last.map(String.init) ?? ""
    return "Could not find service \"\(label)\" in domain"
}
