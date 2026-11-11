import Foundation

/// A Process Detail value that may be missing, with the reason.
enum ProcessDetailValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(String)

    var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }

    func map<Other: Equatable & Sendable>(_ transform: (Value) -> Other) -> ProcessDetailValue<Other> {
        switch self {
        case .available(let value): .available(transform(value))
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

enum ProcessCodeSignature: Equatable, Sendable {
    case signed(identifier: String, teamID: String?, isPlatformBinary: Bool, isAdHoc: Bool)
    case unsigned
    case unavailable(String)

    /// What the sheet shows: the identifier and who signed it.
    var description: ProcessDetailValue<String> {
        switch self {
        case let .signed(identifier, teamID, isPlatformBinary, isAdHoc):
            if let teamID { return .available("\(identifier), Team ID \(teamID)") }
            if isPlatformBinary { return .available("\(identifier), Apple") }
            if isAdHoc { return .available("\(identifier), ad hoc (no Team ID)") }
            return .available("\(identifier), no Team ID")
        case .unsigned:
            return .available("Unsigned")
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }
}

struct ListeningPort: Hashable, Comparable, Sendable {
    enum Transport: String, CaseIterable, Sendable, Comparable {
        case tcp = "TCP"
        case udp = "UDP"
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    var transport: Transport
    var port: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.transport == rhs.transport ? lhs.port < rhs.port : lhs.transport < rhs.transport
    }
}

/// The descriptor count and the listening ports, from one descriptor list.
struct ProcessOpenFiles: Equatable, Sendable {
    var descriptorCount: Int
    var listeningPorts: [ListeningPort]
}


/// The parent shown in Process Detail.
enum ProcessParent: Equatable, Sendable {
    /// The parent PID still belongs to the process that started this one.
    case running(name: String)
    /// The parent PID is free, or belongs to a process that started after
    /// this one, so the original parent has exited.
    case exited
    case unavailable(String)
}

extension ProcessDetail {
    /// "launchd (1)", or why the parent's name is missing.
    var parentDescription: ProcessDetailValue<String> {
        switch parent {
        case .running(let name): .available("\(name) (\(parentPID))")
        case .exited: .available("PID \(parentPID), no longer running")
        case .unavailable(let reason): .unavailable("PID \(parentPID). \(reason)")
        }
    }

    /// Time since the start, as days, hours, minutes and seconds.
    func elapsedDescription(now: Date) -> ProcessDetailValue<String> {
        guard let started = Self.parsedStartTime(startTime) else { return .unavailable("The start time could not be read.") }
        return .available(Self.elapsedText(seconds: max(0, Int(now.timeIntervalSince(started)))))
    }

    static func elapsedText(seconds: Int) -> String {
        let days = seconds / 86_400
        let clock = String(format: "%02d:%02d:%02d", seconds % 86_400 / 3_600, seconds % 3_600 / 60, seconds % 60)
        switch days {
        case 0: return clock
        case 1: return "1 day, \(clock)"
        default: return "\(days) days, \(clock)"
        }
    }

    static func portsDescription(_ ports: [ListeningPort]) -> String {
        guard !ports.isEmpty else { return "None" }
        return ListeningPort.Transport.allCases.compactMap { transport in
            let numbers = ports.filter { $0.transport == transport }.map { String($0.port) }
            return numbers.isEmpty ? nil : "\(transport.rawValue) \(numbers.joined(separator: ", "))"
        }
        .joined(separator: "; ")
    }
}
